using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace VoxFlow;

/// <summary>
/// Low-level keyboard hook: hold RIGHT CTRL to dictate. Also reports real
/// user keystrokes (never injected ones) so callers know when the user is
/// typing. Must be created on a thread with a message pump (the UI thread).
/// </summary>
public sealed class KeyboardHook : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_RCONTROL = 0xA3;
    private const uint LLKHF_INJECTED = 0x10;

    public event Action? Pressed;
    public event Action? Released;
    public event Action? UserActivity;

    private IntPtr _hookHandle = IntPtr.Zero;
    private LowLevelKeyboardProc? _proc; // held to prevent GC of the delegate
    private bool _rightCtrlDown;

    public bool Start()
    {
        if (_hookHandle != IntPtr.Zero) return true;
        _proc = HookCallback;
        using var process = Process.GetCurrentProcess();
        using var module = process.MainModule!;
        _hookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, _proc,
            GetModuleHandle(module.ModuleName), 0);
        return _hookHandle != IntPtr.Zero;
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
        if (nCode >= 0)
        {
            var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            bool injected = (info.flags & LLKHF_INJECTED) != 0;
            int msg = (int)wParam;
            bool isDown = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            bool isUp = msg == WM_KEYUP || msg == WM_SYSKEYUP;

            if (!injected)
            {
                if (info.vkCode == VK_RCONTROL)
                {
                    if (isDown && !_rightCtrlDown)
                    {
                        _rightCtrlDown = true;
                        Pressed?.Invoke();
                    }
                    else if (isUp && _rightCtrlDown)
                    {
                        _rightCtrlDown = false;
                        Released?.Invoke();
                    }
                }
                else if (isDown)
                {
                    UserActivity?.Invoke();
                }
            }
        }
        return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }

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
