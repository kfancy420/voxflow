using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VoxFlow;

/// <summary>
/// Small dark pill showing recording / transcribing state.
///
/// Three things matter and all three were wrong before:
///
/// 1. DPI. The form is hand-built with no AutoScaleDimensions, so WinForms
///    applies no scaling of its own. On a 4K display at 150% a hard-coded
///    220x54 window renders at two-thirds of its intended physical size. All
///    metrics are therefore scaled explicitly from the DPI of the monitor the
///    HUD is about to appear on.
///
/// 2. Monitor. It used to pin itself to Screen.PrimaryScreen, so on a
///    multi-monitor desk it could appear on a different screen from the app
///    being dictated into. It now follows the foreground window.
///
/// 3. Z-order. Relying on the TopMost property alone can lose to other
///    topmost windows; placement is forced through SetWindowPos with
///    HWND_TOPMOST | SWP_NOACTIVATE so the HUD never steals focus from the
///    app that is about to receive the text.
/// </summary>
public sealed class HudForm : Form
{
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TOPMOST = 0x00000008;

    private const int BaseWidth = 260;
    private const int BaseHeight = 64;
    private const int BaseMargin = 72;

    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int SW_SHOWNOACTIVATE = 4;

    private readonly Label _label;
    private readonly System.Windows.Forms.Timer _repaint;
    private float _level;
    private float _scale = 1f;

    public HudForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(24, 24, 27);
        AutoScaleMode = AutoScaleMode.None; // we scale by hand, deliberately
        Size = new Size(BaseWidth, BaseHeight);

        _label = new Label
        {
            ForeColor = Color.White,
            AutoSize = false,
            TextAlign = ContentAlignment.MiddleCenter,
            Dock = DockStyle.Fill,
            Text = "● Recording…"
        };
        Controls.Add(_label);

        _repaint = new System.Windows.Forms.Timer { Interval = 66 };
        _repaint.Tick += (_, _) => UpdateRecordingText();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
            return cp;
        }
    }

    /// <summary>
    /// Sizes and positions the HUD for whichever monitor currently holds the
    /// foreground window, at that monitor's DPI.
    /// </summary>
    private void PlaceOnActiveScreen()
    {
        Screen screen;
        try
        {
            IntPtr fg = GetForegroundWindow();
            screen = fg != IntPtr.Zero ? Screen.FromHandle(fg) : Screen.PrimaryScreen!;
        }
        catch
        {
            screen = Screen.PrimaryScreen!;
        }

        uint dpi = 96;
        try
        {
            IntPtr mon = MonitorFromPoint(new POINT { X = screen.Bounds.Left + 1, Y = screen.Bounds.Top + 1 }, 2 /*NEAREST*/);
            if (GetDpiForMonitor(mon, 0 /*EFFECTIVE*/, out uint x, out _) == 0 && x > 0) dpi = x;
        }
        catch { /* pre-8.1 shells: fall back to 96 */ }

        _scale = dpi / 96f;

        int w = (int)Math.Round(BaseWidth * _scale);
        int h = (int)Math.Round(BaseHeight * _scale);
        var area = screen.WorkingArea;

        Size = new Size(w, h);
        // Specified in pixels and scaled by hand: point sizes would be scaled
        // again by GDI+ from the device DPI, giving a double-scaled font.
        var oldFont = _label.Font;
        _label.Font = new Font("Segoe UI", 15f * _scale, FontStyle.Regular, GraphicsUnit.Pixel);
        oldFont?.Dispose();
        Location = new Point(
            area.Left + (area.Width - w) / 2,
            area.Bottom - h - (int)Math.Round(BaseMargin * _scale));

        ApplyRoundedCorners();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        ApplyRoundedCorners();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        ApplyRoundedCorners(); // region must track the current size, not the startup size
    }

    private void ApplyRoundedCorners()
    {
        if (ClientRectangle.Width <= 0 || ClientRectangle.Height <= 0) return;
        using var path = new GraphicsPath();
        var r = ClientRectangle;
        int radius = Math.Max(8, (int)Math.Round(18 * _scale));
        path.AddArc(r.X, r.Y, radius, radius, 180, 90);
        path.AddArc(r.Right - radius, r.Y, radius, radius, 270, 90);
        path.AddArc(r.Right - radius, r.Bottom - radius, radius, radius, 0, 90);
        path.AddArc(r.X, r.Bottom - radius, radius, radius, 90, 90);
        path.CloseFigure();
        Region?.Dispose();
        Region = new Region(path);
    }

    public void SetLevel(float level) => _level = level;

    private void UpdateRecordingText()
    {
        // 12-segment meter that always shows the label, so the HUD reads as
        // "recording" at a glance rather than as an anonymous row of bars.
        const int segments = 12;
        int lit = Math.Clamp((int)Math.Round(_level * segments), 1, segments);
        _label.Text = "● Recording   " + new string('▮', lit) + new string('▯', segments - lit);
    }

    public void ShowRecording()
    {
        PlaceOnActiveScreen();
        _label.ForeColor = Color.FromArgb(255, 96, 96);
        _label.Text = "● Recording";
        _repaint.Start();
        ShowNoActivate();
    }

    public void ShowWorking(string text)
    {
        _repaint.Stop();
        if (!Visible) PlaceOnActiveScreen();
        _label.ForeColor = Color.White;
        _label.Text = text;
        ShowNoActivate();
    }

    public void HideHud()
    {
        _repaint.Stop();
        Hide();
    }

    private void ShowNoActivate()
    {
        if (!IsHandleCreated) return;
        // Show and raise without ever taking activation — the focused app must
        // keep focus, because it is the one about to receive the dictated text.
        ShowWindow(Handle, SW_SHOWNOACTIVATE);
        SetWindowPos(Handle, HWND_TOPMOST, Left, Top, Width, Height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        if (!Visible) Visible = true;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
