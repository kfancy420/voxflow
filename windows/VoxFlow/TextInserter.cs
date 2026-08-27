using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace VoxFlow;

/// <summary>
/// Inserts text at the cursor of the focused app: saves the clipboard, sets
/// the text, synthesizes Ctrl+V with SendInput, restores the clipboard
/// ~0.6 s later. Must be used from the UI (STA) thread.
///
/// Every key event we synthesize carries <see cref="InjectionMarker"/> in
/// dwExtraInfo so KeyboardHook can recognise and ignore our own keystrokes
/// without having to ignore all injected input.
/// </summary>
public sealed class TextInserter
{
    /// <summary>"VOXF" — tags keystrokes VoxFlow synthesizes.</summary>
    public static readonly IntPtr InjectionMarker = new(0x564F5846);

    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_V = 0x56;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    private DataObject? _savedClipboard;
    private System.Windows.Forms.Timer? _restoreTimer;

    /// <summary>
    /// Copies every format on the clipboard into a private DataObject. The
    /// object Clipboard.GetDataObject() returns is a live view that goes
    /// stale the moment the clipboard changes, so the contents must be pulled
    /// out format by format before we overwrite it. Text, images, files, rich
    /// text — all of it comes back afterwards.
    /// </summary>
    private static DataObject? SnapshotClipboard()
    {
        var live = Clipboard.GetDataObject();
        if (live == null) return null;
        var copy = new DataObject();
        int kept = 0;
        foreach (string format in live.GetFormats(false))
        {
            try
            {
                object? data = live.GetData(format, false);
                if (data != null) { copy.SetData(format, false, data); kept++; }
            }
            catch { /* some formats refuse to be read out-of-process; keep the rest */ }
        }
        return kept > 0 ? copy : null;
    }

    public void Insert(string text, bool trailingSpace)
    {
        string finalText = trailingSpace ? text + " " : text;

        // Only snapshot when no restore is pending (back-to-back dictations
        // must not save our own pasted text as "the user's clipboard").
        if (_restoreTimer == null)
        {
            try
            {
                _savedClipboard = SnapshotClipboard();
            }
            catch (Exception ex)
            {
                Log.Warn("Could not snapshot clipboard: " + ex.Message);
                _savedClipboard = null;
            }
        }
        else
        {
            _restoreTimer.Stop();
            _restoreTimer.Dispose();
            _restoreTimer = null;
        }

        if (!TrySetClipboard(finalText))
        {
            Log.Warn("Clipboard busy — insertion skipped");
            return;
        }

        SendCtrlV();
        Log.Info($"Inserted {finalText.Length} chars via Ctrl+V");

        _restoreTimer = new System.Windows.Forms.Timer { Interval = 600 };
        _restoreTimer.Tick += (_, _) =>
        {
            _restoreTimer?.Stop();
            _restoreTimer?.Dispose();
            _restoreTimer = null;
            try
            {
                if (_savedClipboard != null)
                    Clipboard.SetDataObject(_savedClipboard, copy: true);
                else
                    Clipboard.Clear();
            }
            catch (Exception ex) { Log.Warn("Could not restore clipboard: " + ex.Message); }
            _savedClipboard = null;
        };
        _restoreTimer.Start();
    }

    /// <summary>
    /// The clipboard is a shared, frequently-contended resource; a single
    /// SetText can lose to whatever else just grabbed it. Retry briefly.
    /// </summary>
    private static bool TrySetClipboard(string text)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetText(text);
                return true;
            }
            catch (Exception ex)
            {
                if (attempt == 4) Log.Warn("Clipboard.SetText failed: " + ex.Message);
                Thread.Sleep(40);
            }
        }
        return false;
    }

    private static void SendCtrlV()
    {
        // Give the clipboard owner change a moment to settle before the target
        // app reads it, otherwise fast apps can paste the previous contents.
        Thread.Sleep(30);

        var inputs = new INPUT[4];
        inputs[0] = KeyInput(VK_CONTROL, false);
        inputs[1] = KeyInput(VK_V, false);
        inputs[2] = KeyInput(VK_V, true);
        inputs[3] = KeyInput(VK_CONTROL, true);
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
            Log.Warn($"SendInput sent {sent}/{inputs.Length} events, lastError={Marshal.GetLastWin32Error()}");
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
                dwExtraInfo = InjectionMarker
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
