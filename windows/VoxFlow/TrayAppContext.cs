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
    private readonly System.Windows.Forms.Timer _healthTimer;

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume) return;
        Log.Info("System resumed from sleep — scheduling engine check");
        var t = new System.Windows.Forms.Timer { Interval = 10_000 };
        t.Tick += (_, _) => { t.Stop(); t.Dispose(); EnsureEngineHealthy("resume", force: true); };
        t.Start();
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionUnlock)
            EnsureEngineHealthy("unlock", force: true);
    }

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

        var clearHistoryItem = new ToolStripMenuItem("Clear History Now");
        clearHistoryItem.Click += (_, _) =>
        {
            int count = HistoryStore.Count();
            var answer = MessageBox.Show(
                $"Delete all {count} stored dictation(s)?\n\n" +
                $"History expires automatically after {DescribeRetention()}.",
                "VoxFlow", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
            if (answer == DialogResult.OK) HistoryStore.Clear();
        };

        var logItem = new ToolStripMenuItem("Open Log…");
        logItem.Click += (_, _) => OpenInNotepad(Log.Path);

        var rehookItem = new ToolStripMenuItem("Reinstall Hotkey Hook");

        var reloadEngineItem = new ToolStripMenuItem("Restart Speech Engine");
        reloadEngineItem.Click += (_, _) =>
        {
            if (_busy) { RestartSelf("manual restart while transcribing"); return; }
            Log.Info("Manual speech engine reload");
            _ = _transcriber.ReloadAsync();
        };

        var recoverItem = new ToolStripMenuItem("Recover Last Take");
        recoverItem.Click += (_, _) =>
        {
            if (TakeVault.HasPending) RecoverPendingTake("manual");
            else _tray.ShowBalloonTip(3000, "VoxFlow", "Nothing to recover — the last take was delivered.", ToolTipIcon.Info);
        };

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
        menu.Items.Add(clearHistoryItem);
        menu.Items.Add(logItem);
        menu.Items.Add(rehookItem);
        menu.Items.Add(reloadEngineItem);
        menu.Items.Add(recoverItem);
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
                if (status.StartsWith("Ready", StringComparison.Ordinal))
                {
                    // Prove the fresh engine on real speech, and deliver
                    // anything a previous instance had to leave behind.
                    if (!_busy && TakeVault.HasPending) RecoverPendingTake("engine ready");
                    EnsureEngineHealthy("model-ready");
                }
            });
        };

        _healthTimer = new System.Windows.Forms.Timer { Interval = (int)ProbeInterval.TotalMilliseconds };
        _healthTimer.Tick += (_, _) =>
        {
            if (ShouldSkipIdleProbe(out string why)) { Log.Info($"Idle engine probe skipped: {why}"); return; }
            EnsureEngineHealthy("periodic");
        };
        _healthTimer.Start();

        // Sleep/resume and lock/unlock are exactly when a GPU context tends to
        // vanish; check right away rather than waiting for the timer.
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;

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
        ApplyHistoryRetention();
        UpdateModelChecks();
        _ = _transcriber.LoadAsync(CurrentModel());
    }

    /// <summary>
    /// Applies the retention setting and drops anything already expired.
    /// Pruning is event-driven from here on — on startup, on each new
    /// dictation, and when History is opened — so expired entries can outlive
    /// the window on a machine that is left running and unused, until the next
    /// of those happens.
    /// </summary>
    private void ApplyHistoryRetention()
    {
        HistoryStore.RetentionHours = _settings.HistoryRetentionHours;
        Log.Info($"History retention: {DescribeRetention()}");
        HistoryStore.Prune();
    }

    private string DescribeRetention() =>
        _settings.HistoryRetentionHours <= 0
            ? "no time limit (200-entry cap only)"
            : _settings.HistoryRetentionHours == 24
                ? "24 hours"
                : $"{_settings.HistoryRetentionHours} hours";

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

            // Verify the engine while the user is talking, so a dead one is
            // already rebuilt by the time they release the key.
            EnsureEngineHealthy("keypress");
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

        // To disk in parallel with transcription (a few ms of SSD write, off
        // the critical path): if the process has to restart, the take is
        // recovered on the next launch.
        var vaulted = Task.Run(() => TakeVault.Save(samples));

        Task.Run(async () =>
        {
            try
            {
                var sw = Stopwatch.StartNew();
                string raw = await TranscribeWithRetryAsync(samples);
                sw.Stop();
                string trimmed = raw.Trim();
                Log.Info($"Transcribed in {sw.ElapsedMilliseconds} ms: \"{trimmed}\"");

                RunOnUi(() =>
                {
                    _busy = false;
                    if (trimmed.Length == 0)
                    {
                        TakeVault.Clear();
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
                    TakeVault.Clear();
                    _statusItem.Text = $"Ready — last: {sw.ElapsedMilliseconds} ms";
                    _hud.HideHud();

                    // The number that actually matters: key release → text on screen.
                    Log.Info($"LATENCY release→text {KeyboardHook.MsSince(hookTs):F0} ms " +
                             $"(dispatch {dispatchMs:F0}, mic stop {stopMs:F0}, " +
                             $"transcribe {sw.ElapsedMilliseconds}, clean {cleanMs:F0}, insert {insertMs:F0})");
                });
            }
            catch (TranscriberFaultException fault)
            {
                // Only reached when the engine could not be brought back in
                // place; the take is still in the vault for the next launch.
                Log.Error("Speech engine fault — restarting", fault);
                RunOnUi(() =>
                {
                    _hud.HideHud();
                    _tray.ShowBalloonTip(6000, "VoxFlow", fault.Message, ToolTipIcon.Warning);
                });
                await vaulted;          // never restart before the take is on disk
                await Task.Delay(1500); // let the balloon show
                RestartSelf("speech engine hung");
            }
            catch (Exception ex)
            {
                Log.Error("Transcription failed", ex);
                RunOnUi(() =>
                {
                    _busy = false;
                    _hud.HideHud();
                    _tray.ShowBalloonTip(5000, "VoxFlow",
                        ex.Message + "  Your dictation was kept — use 'Recover Last Take' in the tray menu.",
                        ToolTipIcon.Warning);
                });
            }
        });
    }

    /// <summary>
    /// A lost GPU context surfaces as a non-hung fault: rebuild the engine and
    /// run the same audio again, so the user never has to repeat themselves.
    /// A hang propagates — nothing in-process can fix that.
    /// </summary>
    private async Task<string> TranscribeWithRetryAsync(float[] samples)
    {
        try
        {
            return await _transcriber.TranscribeAsync(samples);
        }
        catch (TranscriberFaultException fault) when (!fault.Hung)
        {
            Log.Info("Engine fault during dictation — reloading and retrying the same take");
            RunOnUi(() => _hud.ShowWorking("Restarting engine…"));
            await _transcriber.ReloadAsync();
            if (!_transcriber.IsReady)
                throw new TranscriberFaultException("The speech engine could not be reloaded.", hung: true);
            RunOnUi(() => _hud.ShowWorking("Transcribing…"));
            return await _transcriber.TranscribeAsync(samples);
        }
    }

    // MARK: engine health

    private DateTime _lastGoodProbe = DateTime.MinValue;
    private int _probing;
    private static readonly TimeSpan ProbeMaxAge = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan ProbeInterval = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan ProbeIdleCutoff = TimeSpan.FromMinutes(10);

    /// <summary>
    /// The idle probe is a convenience (keeps the engine warm), not the
    /// safety net — the key-press probe is. So it yields to anything that
    /// would notice a 200 ms GPU burst: a fullscreen game, or nobody at the
    /// desk to dictate anyway.
    /// </summary>
    private static bool ShouldSkipIdleProbe(out string why)
    {
        if (IdleTime() > ProbeIdleCutoff) { why = "user idle"; return true; }
        if (IsFullscreenAppForeground()) { why = "fullscreen app in foreground"; return true; }
        why = "";
        return false;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private static TimeSpan IdleTime()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) return TimeSpan.Zero;
        return TimeSpan.FromMilliseconds(unchecked((uint)Environment.TickCount - info.dwTime));
    }

    /// <summary>A foreground window that exactly covers its monitor — how games (and fullscreen video) present.</summary>
    private static bool IsFullscreenAppForeground()
    {
        try
        {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero || fg == GetShellWindow()) return false;
            if (!GetWindowRect(fg, out var r)) return false;
            var screen = Screen.FromHandle(fg).Bounds;
            return r.Left <= screen.Left && r.Top <= screen.Top &&
                   r.Right >= screen.Right && r.Bottom >= screen.Bottom;
        }
        catch { return false; }
    }

    /// <summary>
    /// Verifies the engine can still transcribe real speech and rebuilds it if
    /// not. Safe to call often: a probe already in flight, a busy engine, or a
    /// recent pass all short-circuit unless <paramref name="force"/>.
    /// </summary>
    private void EnsureEngineHealthy(string trigger, bool force = false)
    {
        if (!force && DateTime.Now - _lastGoodProbe < ProbeMaxAge) return;
        if (_busy && !force) return;
        if (System.Threading.Interlocked.Exchange(ref _probing, 1) == 1) return;

        Task.Run(async () =>
        {
            try
            {
                var health = await _transcriber.ProbeAsync(trigger);
                switch (health)
                {
                    case Transcriber.Health.Ok:
                        _lastGoodProbe = DateTime.Now;
                        break;
                    case Transcriber.Health.Dead:
                        Log.Info($"Engine dead ({trigger}) — rebuilding before it is needed");
                        RunOnUi(() => _statusItem.Text = "Restarting speech engine…");
                        await _transcriber.ReloadAsync();
                        if (_transcriber.IsReady && await _transcriber.ProbeAsync("post-reload") == Transcriber.Health.Ok)
                            _lastGoodProbe = DateTime.Now;
                        else
                            RestartSelf("engine still unhealthy after reload");
                        break;
                    case Transcriber.Health.Hung:
                        if (_recorder.IsRecording || _busy)
                        {
                            // Let the take finish and be vaulted; the release
                            // path will hit the hang and restart with it saved.
                            Log.Error("Engine hung during a take — deferring restart until the take is saved");
                            break;
                        }
                        RestartSelf("engine hung during health probe");
                        break;
                }
            }
            catch (Exception ex)
            {
                Log.Error($"Engine probe error ({trigger})", ex);
            }
            finally
            {
                System.Threading.Interlocked.Exchange(ref _probing, 0);
            }
        });
    }

    /// <summary>
    /// A take that survived a restart (or a failed insert) is transcribed as
    /// soon as the engine is ready and placed on the clipboard — pasting into
    /// whatever window happens to be focused later would be a nasty surprise.
    /// </summary>
    private void RecoverPendingTake(string reason)
    {
        var samples = TakeVault.Load();
        if (samples == null || samples.Length < 4800) { TakeVault.Clear(); return; }
        Log.Info($"Recovering pending take ({samples.Length / 16000.0:F1}s, {reason})");

        Task.Run(async () =>
        {
            try
            {
                string raw = (await _transcriber.TranscribeAsync(samples)).Trim();
                if (raw.Length == 0)
                {
                    Log.Info("Pending take transcribed to nothing — dropped");
                    TakeVault.Clear();
                    return;
                }
                string withDictionary = PersonalDictionary.Apply(raw);
                string cleaned = _settings.CleanupEnabled ? TextCleaner.Clean(withDictionary) : withDictionary;
                RunOnUi(() =>
                {
                    try { Clipboard.SetText(cleaned); }
                    catch (Exception ex) { Log.Warn($"Clipboard unavailable: {ex.Message}"); }
                    HistoryStore.Add(raw, cleaned, "recovered");
                    TakeVault.Clear();
                    Log.Info($"Recovered take ({cleaned.Length} chars) placed on clipboard");
                    _tray.ShowBalloonTip(10000, "VoxFlow — dictation recovered",
                        "Your last dictation was saved and is now on the clipboard — press Ctrl+V to paste it. " +
                        "It is also in History.", ToolTipIcon.Info);
                });
            }
            catch (Exception ex)
            {
                Log.Error("Could not recover pending take (kept on disk)", ex);
            }
        });
    }


    /// <summary>
    /// A native whisper call that never returns cannot be unwound from managed
    /// code, so the only clean recovery is a fresh process. Environment.Exit
    /// rather than ExitThread: the stuck thread would otherwise keep the old
    /// process alive next to the new one.
    /// </summary>
    private void RestartSelf(string reason)
    {
        Log.Info($"Restarting VoxFlow: {reason}");
        try
        {
            _tray.Visible = false;
            _hook.Dispose();
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Error("Could not relaunch VoxFlow", ex);
        }
        Environment.Exit(1);
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
        _healthTimer.Stop();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
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
