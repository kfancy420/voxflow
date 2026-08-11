using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace VoxFlow;

/// <summary>
/// Inserts text at the cursor of the focused app: saves the clipboard, sets
/// the text, synthesizes Ctrl+V with SendInput, restores the clipboard
/// ~0.6 s later. Must be used from the UI (STA) thread.
/// </summary>
public sealed class TextInserter
{
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_V = 0x56;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    private string? _savedClipboardText;
    private bool _savedClipboardHadText;
    private System.Windows.Forms.Timer? _restoreTimer;

    public void Insert(string text, bool trailingSpace)
    {
        string finalText = trailingSpace ? text + " " : text;

        // Only snapshot when no restore is pending (back-to-back dictations
        // must not save our own pasted text as "the user's clipboard").
        if (_restoreTimer == null)
        {
            try
            {
                _savedClipboardHadText = Clipboard.ContainsText();
                _savedClipboardText = _savedClipboardHadText ? Clipboard.GetText() : null;
            }
            catch
            {
                _savedClipboardHadText = false;
                _savedClipboardText = null;
            }
        }
        else
        {
            _restoreTimer.Stop();
            _restoreTimer.Dispose();
            _restoreTimer = null;
        }

        try
        {
            Clipboard.SetText(finalText);
        }
        catch
        {
            return; // clipboard busy; nothing sane to do
        }

        SendCtrlV();

        _restoreTimer = new System.Windows.Forms.Timer { Interval = 600 };
        _restoreTimer.Tick += (_, _) =>
        {
            _restoreTimer?.Stop();
            _restoreTimer?.Dispose();
            _restoreTimer = null;
            try
            {
                if (_savedClipboardHadText && _savedClipboardText != null)
                    Clipboard.SetText(_savedClipboardText);
                else
                    Clipboard.Clear();
            }
            catch { /* clipboard busy — leave as-is */ }
            _savedClipboardText = null;
            _savedClipboardHadText = false;
        };
        _restoreTimer.Start();
    }

    private static void SendCtrlV()
    {
        var inputs = new INPUT[4];
        inputs[0] = KeyInput(VK_CONTROL, false);
        inputs[1] = KeyInput(VK_V, false);
        inputs[2] = KeyInput(VK_V, true);
        inputs[3] = KeyInput(VK_CONTROL, true);
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT KeyInput(ushort vk, bool keyUp) => new()
    {
        type = 1, // INPUT_KEYBOARD
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = vk,
                wScan = 0,
                dwFlags = keyUp ? KEYEVENTF_KEYUP : 0,
                time = 0,
                dwExtraInfo = IntPtr.Zero
            }
        }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
