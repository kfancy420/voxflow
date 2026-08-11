using System;
using System.Diagnostics;
using System.Drawing;
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
    private readonly NotifyIcon _tray;
    private readonly KeyboardHook _hook = new();
    private readonly AudioRecorder _recorder = new();
    private readonly Transcriber _transcriber = new();
    private readonly TextInserter _inserter = new();
    private readonly HudForm _hud = new();
    private readonly Settings _settings = Settings.Load();

    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _cleanupItem;
    private readonly ToolStripMenuItem _modelBase;
    private readonly ToolStripMenuItem _modelSmall;
    private readonly ToolStripMenuItem _startupItem;

    private bool _busy;
    private DateTime _recordingStart;

    public TrayAppContext()
    {
        PersonalDictionary.EnsureExists();

        _statusItem = new ToolStripMenuItem("Starting…") { Enabled = false };
        _cleanupItem = new ToolStripMenuItem("Cleanup (fillers, punctuation)") { Checked = _settings.CleanupEnabled, CheckOnClick = true };
        _cleanupItem.CheckedChanged += (_, _) => { _settings.CleanupEnabled = _cleanupItem.Checked; _settings.Save(); };

        _modelBase = new ToolStripMenuItem("Base (fastest, ~140 MB)");
        _modelSmall = new ToolStripMenuItem("Small (better, ~470 MB)");
        _modelBase.Click += (_, _) => SwitchModel("base.en");
        _modelSmall.Click += (_, _) => SwitchModel("small.en");
        var modelMenu = new ToolStripMenuItem("Model");
        modelMenu.DropDownItems.Add(_modelBase);
        modelMenu.DropDownItems.Add(_modelSmall);

        var dictItem = new ToolStripMenuItem("Edit Dictionary…");
        dictItem.Click += (_, _) => Process.Start("notepad.exe", PersonalDictionary.PathForEditing());

        var historyItem = new ToolStripMenuItem("Open History…");
        historyItem.Click += (_, _) => Process.Start("notepad.exe", HistoryStore.PathForViewing());

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
        menu.Items.Add(_startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quitItem);

        _tray = new NotifyIcon
        {
            Icon = MakeIcon(recording: false),
            Text = "VoxFlow — hold Right Ctrl to dictate",
            Visible = true,
            ContextMenuStrip = menu
        };

        _transcriber.Status += status => RunOnUi(() =>
        {
            _statusItem.Text = status;
            UpdateModelChecks();
        });

        _recorder.Level += level => RunOnUi(() => _hud.SetLevel(level));

        _hook.Pressed += OnPressed;
        _hook.Released += OnReleased;
        if (!_hook.Start())
        {
            MessageBox.Show("Could not install the keyboard hook. Try running VoxFlow again.",
                "VoxFlow", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        // First-run: silently register to start with Windows so the user
        // never has to launch it manually again. Only done once, so if they
        // later turn it off from the menu we respect that.
        if (!_settings.AutoStartConfigured)
        {
            SetStartupEnabled(true);
            _settings.AutoStartConfigured = true;
            _settings.Save();
            _startupItem.Checked = true;
            _tray.ShowBalloonTip(4000, "VoxFlow",
                "Running in the tray and set to start with Windows. Hold Right Ctrl to dictate.",
                ToolTipIcon.Info);
        }

        UpdateModelChecks();
        _ = _transcriber.LoadAsync(CurrentModelChoice());
    }

    private Transcriber.ModelChoice CurrentModelChoice() =>
        _settings.Model == "base.en" ? Transcriber.ModelChoice.BaseEn : Transcriber.ModelChoice.SmallEn;

    private void SwitchModel(string model)
    {
        if (_settings.Model == model) return;
        _settings.Model = model;
        _settings.Save();
        UpdateModelChecks();
        _ = _transcriber.LoadAsync(CurrentModelChoice());
    }

    private void UpdateModelChecks()
    {
        _modelBase.Checked = _settings.Model == "base.en";
        _modelSmall.Checked = _settings.Model == "small.en";
    }

    // MARK: pipeline

    private void OnPressed()
    {
        if (_busy || _recorder.IsRecording) return;
        try
        {
            _recorder.Start();
            _recordingStart = DateTime.Now;
            _tray.Icon = MakeIcon(recording: true);
            _hud.ShowRecording();
        }
        catch (Exception ex)
        {
            _hud.HideHud();
            _tray.ShowBalloonTip(3000, "VoxFlow", "Microphone unavailable: " + ex.Message, ToolTipIcon.Warning);
        }
    }

    private void OnReleased()
    {
        if (!_recorder.IsRecording) return;
        var samples = _recorder.Stop();
        _tray.Icon = MakeIcon(recording: false);
        double heldSeconds = (DateTime.Now - _recordingStart).TotalSeconds;

        if (heldSeconds < 0.15 || samples.Length < 2400)
        {
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

                RunOnUi(() =>
                {
                    _busy = false;
                    if (trimmed.Length == 0)
                    {
                        _hud.HideHud();
                        return;
                    }
                    string withDictionary = PersonalDictionary.Apply(trimmed);
                    string cleaned = _settings.CleanupEnabled ? TextCleaner.Clean(withDictionary) : withDictionary;
                    _inserter.Insert(cleaned, _settings.TrailingSpace);
                    HistoryStore.Add(trimmed, cleaned, null);
                    _statusItem.Text = $"Ready — last: {sw.ElapsedMilliseconds} ms";
                    _hud.HideHud();
                });
            }
            catch (Exception ex)
            {
                RunOnUi(() =>
                {
                    _busy = false;
                    _hud.HideHud();
                    _tray.ShowBalloonTip(3000, "VoxFlow", ex.Message, ToolTipIcon.Warning);
                });
            }
        });
    }

    // MARK: helpers

    private void RunOnUi(Action action)
    {
        if (_hud.InvokeRequired) _hud.BeginInvoke(action);
        else action();
    }

    private static bool IsStartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("VoxFlow") != null;
    }

    private static void SetStartupEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
        if (key == null) return;
        if (enabled) key.SetValue("VoxFlow", $"\"{Application.ExecutablePath}\"");
        else key.DeleteValue("VoxFlow", throwOnMissingValue: false);
    }

    private static Icon MakeIcon(bool recording)
    {
        using var bmp = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);
        using var body = new SolidBrush(recording ? Color.FromArgb(235, 68, 68) : Color.White);
        g.FillEllipse(body, 10, 3, 12, 17);          // capsule
        using var pen = new Pen(body.Color, 3);
        g.DrawArc(pen, 7, 10, 18, 14, 0, 180);        // cradle
        g.DrawLine(pen, 16, 24, 16, 29);              // stem
        IntPtr hIcon = bmp.GetHicon();
        return Icon.FromHandle(hIcon);
    }

    protected override void ExitThreadCore()
    {
        _hook.Dispose();
        _recorder.Dispose();
        _transcriber.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        base.ExitThreadCore();
    }
}
