using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace VoxFlow;

/// <summary>
/// Low-level keyboard hook: hold RIGHT CTRL to dictate.
///
/// Two rules matter here and both are load-bearing:
///
/// 1. The callback must return almost immediately. Windows enforces
///    LowLevelHooksTimeout (300 ms by default) and will silently stop calling
///    a hook that overruns it — the hotkey then dies until the app restarts.
///    So the callback only updates a bool and posts to the UI queue; all real
///    work (opening the mic, stopping it) happens after the callback returns.
///
/// 2. We must ignore the keystrokes VoxFlow itself synthesizes when pasting,
///    or Ctrl+V would re-trigger us. We identify those by a magic dwExtraInfo
///    tag rather than by the generic "injected" flag, so legitimate injected
///    input from remappers, KVMs, AutoHotkey, macro keyboards and test
///    harnesses still works the way the user expects.
/// </summary>
public sealed class KeyboardHook : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_RCONTROL = 0xA3;

    // Each carries the Stopwatch timestamp captured inside the hook callback,
    // so handlers can report how much latency the hand-off itself cost.
    public event Action<long>? Pressed;
    public event Action<long>? Released;
    public event Action<long>? UserActivity;

    private IntPtr _hookHandle = IntPtr.Zero;
    private LowLevelKeyboardProc? _proc; // held to prevent GC of the delegate
    private bool _rightCtrlDown;
    private SynchronizationContext? _ui;
    private long _callbackCount;

    /// <summary>Number of hook callbacks received — used for diagnostics.</summary>
    public long CallbackCount => Interlocked.Read(ref _callbackCount);

    public bool IsInstalled => _hookHandle != IntPtr.Zero;

    public bool Start()
    {
        if (_hookHandle != IntPtr.Zero) return true;

        // Captured on the UI thread so we can hand work back to it without
        // doing that work inside the hook callback itself.
        _ui = SynchronizationContext.Current;
        if (_ui == null)
            Log.Warn("KeyboardHook.Start: no SynchronizationContext — events will run inline");

        _proc = HookCallback;
        using var process = Process.GetCurrentProcess();
        using var module = process.MainModule!;
        _hookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, _proc,
            GetModuleHandle(module.ModuleName), 0);
        int err = Marshal.GetLastWin32Error();
        Log.Info($"SetWindowsHookEx(WH_KEYBOARD_LL) handle=0x{_hookHandle:X} lastError={err} module={module.ModuleName}");
        return _hookHandle != IntPtr.Zero;
    }

    /// <summary>Tears the hook down and installs a fresh one.</summary>
    public bool Reinstall()
    {
        Log.Info("KeyboardHook.Reinstall requested");
        Dispose();
        _rightCtrlDown = false;
        return Start();
    }

    public void Dispose()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookHandle);
            _hookHandle = IntPtr.Zero;
        }
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        // Anything slow in here risks Windows evicting the hook. Keep it tiny.
        if (nCode >= 0)
        {
            long ts = Stopwatch.GetTimestamp();
            Interlocked.Increment(ref _callbackCount);
            var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);

            // Only skip keystrokes *we* synthesized (see TextInserter).
            bool selfInjected = info.dwExtraInfo == TextInserter.InjectionMarker;

            int msg = (int)wParam;
            bool isDown = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            bool isUp = msg == WM_KEYUP || msg == WM_SYSKEYUP;

            if (!selfInjected)
            {
                if (info.vkCode == VK_RCONTROL)
                {
                    if (isDown && !_rightCtrlDown)
                    {
                        _rightCtrlDown = true;
                        Dispatch(Pressed, ts);
                    }
                    else if (isUp && _rightCtrlDown)
                    {
                        _rightCtrlDown = false;
                        Dispatch(Released, ts);
                    }
                }
                else if (isDown)
                {
                    Dispatch(UserActivity, ts);
                }
            }
        }
        return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }

    /// <summary>
    /// Queues the handler on the UI thread and returns at once, so the hook
    /// callback never blocks on microphone or transcription work.
    /// </summary>
    private void Dispatch(Action<long>? handler, long timestamp)
    {
        if (handler == null) return;
        var ui = _ui;
        if (ui != null) ui.Post(_ => SafeInvoke(handler, timestamp), null);
        else SafeInvoke(handler, timestamp);
    }

    private static void SafeInvoke(Action<long> handler, long timestamp)
    {
        try { handler(timestamp); }
        catch (Exception ex) { Log.Error("Hotkey handler threw", ex); }
    }

    /// <summary>Milliseconds elapsed since a Stopwatch timestamp.</summary>
    public static double MsSince(long timestamp) =>
        (Stopwatch.GetTimestamp() - timestamp) * 1000.0 / Stopwatch.Frequency;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}
