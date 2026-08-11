using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace VoxFlow;

/// <summary>
/// Small dark pill near the bottom of the screen showing recording /
/// transcribing state. Never steals focus (WS_EX_NOACTIVATE +
/// ShowWithoutActivation) — insertion targets the focused app.
/// </summary>
public sealed class HudForm : Form
{
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TOPMOST = 0x00000008;

    private readonly Label _label;
    private float _level;
    private readonly System.Windows.Forms.Timer _repaint;

    public HudForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(28, 28, 30);
        Size = new Size(220, 54);

        _label = new Label
        {
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 10.5f, FontStyle.Regular),
            AutoSize = false,
            TextAlign = ContentAlignment.MiddleCenter,
            Dock = DockStyle.Fill,
            Text = "● Recording…"
        };
        Controls.Add(_label);

        _repaint = new System.Windows.Forms.Timer { Interval = 100 };
        _repaint.Tick += (_, _) => UpdateRecordingText();

        Reposition();
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

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        ApplyRoundedCorners();
    }

    private void ApplyRoundedCorners()
    {
        using var path = new GraphicsPath();
        var r = ClientRectangle;
        const int radius = 16;
        path.AddArc(r.X, r.Y, radius, radius, 180, 90);
        path.AddArc(r.Right - radius, r.Y, radius, radius, 270, 90);
        path.AddArc(r.Right - radius, r.Bottom - radius, radius, radius, 0, 90);
        path.AddArc(r.X, r.Bottom - radius, radius, radius, 90, 90);
        path.CloseFigure();
        Region = new Region(path);
    }

    private void Reposition()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        Location = new Point(
            screen.Left + (screen.Width - Width) / 2,
            screen.Bottom - Height - 60);
    }

    public void SetLevel(float level) => _level = level;

    private void UpdateRecordingText()
    {
        int bars = (int)Math.Round(_level * 8);
        _label.Text = "● " + new string('|', Math.Max(1, bars)).PadRight(8, '·');
    }

    public void ShowRecording()
    {
        Reposition();
        _label.ForeColor = Color.FromArgb(255, 90, 90);
        _label.Text = "● Recording…";
        _repaint.Start();
        ShowNoActivate();
    }

    public void ShowWorking(string text)
    {
        _repaint.Stop();
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
        if (!Visible)
        {
            // Show() would activate; this respects ShowWithoutActivation.
            Visible = true;
        }
    }
}
