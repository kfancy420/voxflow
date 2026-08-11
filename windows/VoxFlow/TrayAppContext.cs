using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace VoxFlow;

/// <summary>
/// Owns everything: tray icon + menu, hotkey, and the dictation pipeline
/// (press → record → release → transcribe → dictionary → clean → insert).
/// </summary>
public sealed class TrayAppContext : ApplicationContext
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunKeyName = "VoxFlow";

    private readonly NotifyIcon _tray;
    private readonly KeyboardHook _hook = new();
    private readonly AudioRecorder _recorder = new();
    private readonly Transcriber _transcriber = new();
    private readonly TextInserter _inserter = new();
    private readonly HudForm _hud = new();
    private readonly Settings _settings = Settings.Load();

    // Created once. Rebuilding these per toggle leaked a GDI handle each time,
    // which eventually exhausts the 10k per-process quota in a process that is
    // meant to run for weeks.
    private readonly Icon _iconIdle = MakeIcon(recording: false);
    private readonly Icon _iconRecording = MakeIcon(recording: true);

    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _cleanupItem;
    private readonly ToolStripMenuItem _startupItem;
    private readonly Dictionary<string, ToolStripMenuItem> _modelItems = new();

    private bool _busy;
    private DateTime _recordingStart;

    public TrayAppContext()
    {
        PersonalDictionary.EnsureExists();

        // The HUD is our marshalling target for background→UI callbacks.
        // Control.InvokeRequired returns false while a handle does not exist,
        // which would silently run UI updates on worker threads, so force the
        // handle into existence before anything can call RunOnUi.
        _ = _hud.Handle;

        _statusItem = new ToolStripMenuItem("Starting…") { Enabled = false };
        _cleanupItem = new ToolStripMenuItem("Cleanup (fillers, punctuation)") { Checked = _settings.CleanupEnabled, CheckOnClick = true };
        _cleanupItem.CheckedChanged += (_, _) => { _settings.CleanupEnabled = _cleanupItem.Checked; _settings.Save(); };

        var modelMenu = new ToolStripMenuItem("Model");
        foreach (var model in Transcriber.Models)
        {
            var captured = model;
            var item = new ToolStripMenuItem(model.MenuLabel);
            item.Click += (_, _) => SwitchModel(captured);
            _modelItems[model.Id] = item;
            modelMenu.DropDownItems.Add(item);
        }

        var dictItem = new ToolStripMenuItem("Edit Dictionary…");
        dictItem.Click += (_, _) => OpenInNotepad(PersonalDictionary.PathForEditing());

        var historyItem = new ToolStripMenuItem("Open History…");
        historyItem.Click += (_, _) => OpenInNotepad(HistoryStore.PathForViewing());

        var logItem = new ToolStripMenuItem("Open Log…");
        logItem.Click += (_, _) => OpenInNotepad(Log.Path);

        var rehookItem = new ToolStripMenuItem("Reinstall Hotkey Hook");

        _startupItem = new ToolStripMenuItem("Start with Windows") { Checked = IsStartupEnabled(), CheckOnClick = true };
        _startupItem.CheckedChanged += (_, _) => SetStartupEnabled(_startupItem.Checked);

        var quitItem = new ToolStripMenuItem("Quit VoxFlow");
        quitItem.Click += (_, _) => ExitThread();

        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_cleanupItem);
        menu.Items.Add(modelMenu);
        menu.Items.Add(dictItem);
        menu.Items.Add(historyItem);
        menu.Items.Add(logItem);
        menu.Items.Add(rehookItem);
        menu.Items.Add(_startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quitItem);

        _tray = new NotifyIcon
        {
            Icon = _iconIdle,
            Text = "VoxFlow — hold Right Ctrl to dictate",
            Visible = true,
            ContextMenuStrip = menu
        };

        // Wired after _tray exists so the handler can safely reference it.
        rehookItem.Click += (_, _) =>
        {
            bool ok = _hook.Reinstall();
            _tray.ShowBalloonTip(3000, "VoxFlow",
                ok ? "Hotkey hook reinstalled." : "Could not reinstall the hotkey hook.",
                ok ? ToolTipIcon.Info : ToolTipIcon.Warning);
        };

        _transcriber.Status += status =>
        {
            Log.Info($"status: {status}");
            RunOnUi(() =>
            {
                _statusItem.Text = status;
                UpdateModelChecks();
                // A failed model load used to be visible only to someone who
                // opened the tray menu and read a disabled label.
                if (status.StartsWith("Model error", StringComparison.Ordinal))
                    _tray.ShowBalloonTip(8000, "VoxFlow — dictation unavailable",
                        status + "  (see Open Log… in the tray menu)", ToolTipIcon.Error);
            });
        };

        _recorder.Level += level => RunOnUi(() => _hud.SetLevel(level));

        _hook.Pressed += OnPressed;
        _hook.Released += OnReleased;
        if (!_hook.Start())
        {
            Log.Error("Keyboard hook failed to install");
            _tray.ShowBalloonTip(8000, "VoxFlow",
                "Could not install the keyboard hook — Right Ctrl will not work. " +
                "Security software can block this. Try 'Reinstall Hotkey Hook' in the tray menu.",
                ToolTipIcon.Error);
        }

        EnsureAutoStart();
        UpdateModelChecks();
        _ = _transcriber.LoadAsync(CurrentModel());
    }

    /// <summary>
    /// First run registers start-with-Windows. On later runs we only correct a
    /// stale path (e.g. the exe was reinstalled somewhere else) — if the user
    /// has deliberately turned auto-start off, we leave it off.
    /// </summary>
    private void EnsureAutoStart()
    {
        string target = $"\"{Environment.ProcessPath}\"";

        if (!_settings.AutoStartConfigured)
        {
            SetStartupEnabled(true);
            _settings.AutoStartConfigured = true;
            _settings.Save();
            _startupItem.Checked = true;
            _tray.ShowBalloonTip(5000, "VoxFlow",
                "Running in the tray and set to start with Windows. Hold Right Ctrl to dictate.",
                ToolTipIcon.Info);
            return;
        }

        string? current = CurrentStartupValue();
        if (current != null && !string.Equals(current, target, StringComparison.OrdinalIgnoreCase))
        {
            Log.Info($"Updating stale auto-start path: {current} -> {target}");
            SetStartupEnabled(true);
            _startupItem.Checked = true;
        }
    }

    private Transcriber.ModelInfo CurrentModel() => Transcriber.Resolve(_settings.Model);

    private void SwitchModel(Transcriber.ModelInfo model)
    {
        if (_settings.Model == model.Id) return;

        if (!Transcriber.IsDownloaded(model))
        {
            var answer = MessageBox.Show(
                $"{model.MenuLabel}\n\nThis model has not been downloaded yet. " +
                "Downloading happens in the background and dictation stays on the current " +
                "model until it finishes.\n\nDownload it now?",
                "VoxFlow", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
            if (answer != DialogResult.OK) return;
        }

        _settings.Model = model.Id;
        _settings.Save();
        UpdateModelChecks();
        Log.Info($"Switching model to {model.Id}");
        _ = _transcriber.LoadAsync(model);
    }

    private void UpdateModelChecks()
    {
        foreach (var (id, item) in _modelItems)
        {
            item.Checked = _settings.Model == id;
            // Make it obvious which models are already on disk.
            var model = Transcriber.Resolve(id);
            item.Text = Transcriber.IsDownloaded(model)
                ? model.MenuLabel
                : model.MenuLabel + " — not downloaded";
        }
    }

    private static void OpenInNotepad(string path)
    {
        try { Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = false }); }
        catch (Exception ex) { Log.Warn($"Could not open {path}: {ex.Message}"); }
    }

    // MARK: pipeline
    // Both handlers are posted from the hook callback, so they run on the UI
    // thread *after* the callback has returned — device work here can take as
    // long as it needs without risking the low-level hook timeout.

    private void OnPressed(long hookTs)
    {
        if (_busy || _recorder.IsRecording) return;
        try
        {
            double dispatchMs = KeyboardHook.MsSince(hookTs);
            var sw = Stopwatch.StartNew();
            _recorder.Start();
            double micMs = sw.Elapsed.TotalMilliseconds;
            _recordingStart = DateTime.Now;
            _tray.Icon = _iconRecording;
            _hud.ShowRecording();
            Log.Info($"Recording started (hook→handler {dispatchMs:F1} ms, mic open {micMs:F1} ms, " +
                     $"hud {sw.Elapsed.TotalMilliseconds - micMs:F1} ms)");
        }
        catch (Exception ex)
        {
            Log.Error("Microphone start failed", ex);
            _hud.HideHud();
            _tray.ShowBalloonTip(5000, "VoxFlow", "Microphone unavailable: " + ex.Message, ToolTipIcon.Warning);
        }
    }

    private void OnReleased(long hookTs)
    {
        if (!_recorder.IsRecording) return;
        double dispatchMs = KeyboardHook.MsSince(hookTs);
        var stopSw = Stopwatch.StartNew();
        var samples = _recorder.Stop();
        double stopMs = stopSw.Elapsed.TotalMilliseconds;
        _tray.Icon = _iconIdle;
        double heldSeconds = (DateTime.Now - _recordingStart).TotalSeconds;
        Log.Info($"Recording stopped: {heldSeconds:F2}s, {samples.Length} samples " +
                 $"({samples.Length / 16000.0:F2}s captured, hook→handler {dispatchMs:F1} ms, mic stop {stopMs:F1} ms)");

        if (heldSeconds < 0.15 || samples.Length < 4800)
        {
            Log.Info("Take too short — discarded");
            _hud.HideHud();
            return;
        }

        _hud.ShowWorking("Transcribing…");
        _busy = true;

        Task.Run(async () =>
        {
            try
            {
                var sw = Stopwatch.StartNew();
                string raw = await _transcriber.TranscribeAsync(samples);
                sw.Stop();
                string trimmed = raw.Trim();
                Log.Info($"Transcribed in {sw.ElapsedMilliseconds} ms: \"{trimmed}\"");

                RunOnUi(() =>
                {
                    _busy = false;
                    if (trimmed.Length == 0)
                    {
                        _hud.HideHud();
                        _statusItem.Text = "Ready — nothing heard";
                        return;
                    }
                    var postSw = Stopwatch.StartNew();
                    string withDictionary = PersonalDictionary.Apply(trimmed);
                    string cleaned = _settings.CleanupEnabled ? TextCleaner.Clean(withDictionary) : withDictionary;
                    double cleanMs = postSw.Elapsed.TotalMilliseconds;

                    _inserter.Insert(cleaned, _settings.TrailingSpace);
                    double insertMs = postSw.Elapsed.TotalMilliseconds - cleanMs;

                    HistoryStore.Add(trimmed, cleaned, null);
                    _statusItem.Text = $"Ready — last: {sw.ElapsedMilliseconds} ms";
                    _hud.HideHud();

                    // The number that actually matters: key release → text on screen.
                    Log.Info($"LATENCY release→text {KeyboardHook.MsSince(hookTs):F0} ms " +
                             $"(dispatch {dispatchMs:F0}, mic stop {stopMs:F0}, " +
                             $"transcribe {sw.ElapsedMilliseconds}, clean {cleanMs:F0}, insert {insertMs:F0})");
                });
            }
            catch (Exception ex)
            {
                Log.Error("Transcription failed", ex);
                RunOnUi(() =>
                {
                    _busy = false;
                    _hud.HideHud();
                    _tray.ShowBalloonTip(5000, "VoxFlow", ex.Message, ToolTipIcon.Warning);
                });
            }
        });
    }

    // MARK: helpers

    private void RunOnUi(Action action)
    {
        try
        {
            if (_hud.IsHandleCreated && _hud.InvokeRequired) _hud.BeginInvoke(action);
            else action();
        }
        catch (Exception ex)
        {
            Log.Error("RunOnUi failed", ex);
        }
    }

    private static string? CurrentStartupValue()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return key?.GetValue(RunKeyName) as string;
    }

    private static bool IsStartupEnabled() => CurrentStartupValue() != null;

    private static void SetStartupEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
                            ?? Registry.CurrentUser.CreateSubKey(RunKeyPath);
            if (key == null) { Log.Warn("Could not open HKCU Run key"); return; }
            if (enabled)
            {
                // Environment.ProcessPath is the real exe even for single-file
                // published apps, where the entry assembly has no location.
                string value = $"\"{Environment.ProcessPath}\"";
                key.SetValue(RunKeyName, value);
                Log.Info($"Auto-start registered: {value}");
            }
            else
            {
                key.DeleteValue(RunKeyName, throwOnMissingValue: false);
                Log.Info("Auto-start removed");
            }
        }
        catch (Exception ex)
        {
            Log.Error("SetStartupEnabled failed", ex);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    private static Icon MakeIcon(bool recording)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var body = new SolidBrush(recording ? Color.FromArgb(235, 68, 68) : Color.White);
            g.FillEllipse(body, 10, 3, 12, 17);          // capsule
            using var pen = new Pen(body.Color, 3);
            g.DrawArc(pen, 7, 10, 18, 14, 0, 180);        // cradle
            g.DrawLine(pen, 16, 24, 16, 29);              // stem
        }

        IntPtr hIcon = bmp.GetHicon();
        try
        {
            using var temp = Icon.FromHandle(hIcon);
            return (Icon)temp.Clone(); // owns its own copy; native handle can go
        }
        finally
        {
            DestroyIcon(hIcon);
        }
    }

    protected override void ExitThreadCore()
    {
        Log.Info("Shutting down");
        _hook.Dispose();
        _recorder.Dispose();
        _transcriber.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        _iconIdle.Dispose();
        _iconRecording.Dispose();
        base.ExitThreadCore();
    }
}
