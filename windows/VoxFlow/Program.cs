using System;
using System.Threading;
using System.Windows.Forms;

namespace VoxFlow;

internal static class Program
{
    private const int RESTART_NO_PATCH = 4;
    private const int RESTART_NO_REBOOT = 8;

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int RegisterApplicationRestart(string commandLine, int flags);

    /// <summary>
    /// Test hook: reproduces the fatal native fault (an access violation the
    /// runtime cannot catch) so the Windows auto-restart can be verified.
    /// </summary>
    private static void ScheduleCrashForTesting(int seconds)
    {
        Log.Info($"CRASH TEST: process will fault in {seconds}s");
        new Thread(() =>
        {
            Thread.Sleep(seconds * 1000);
            Log.Info("CRASH TEST: faulting now");
            System.Runtime.InteropServices.Marshal.ReadInt32((IntPtr)0x10000000);
        }) { IsBackground = true }.Start();
    }
    [STAThread]
    private static int Main(string[] args)
    {
        Log.Info("=== VoxFlow starting ===");
        Log.Info($"exe={Environment.ProcessPath} base={AppContext.BaseDirectory}");
        Log.Info($"os={Environment.OSVersion} clr={Environment.Version} args=[{string.Join(' ', args)}]");

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Log.Error("UNHANDLED (AppDomain)", e.ExceptionObject as Exception);
        Application.ThreadException += (_, e) =>
            Log.Error("UNHANDLED (WinForms thread)", e.Exception);
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, e) =>
            Log.Error("UNOBSERVED task exception", e.Exception);

        // Self-test modes run headless and deliberately skip the single-instance
        // guard so they can be run against a machine where VoxFlow is resident.
        if (args.Length > 0 && args[0].StartsWith("--selftest", StringComparison.Ordinal))
        {
            ApplicationConfiguration.Initialize();
            return SelfTest.Run(args);
        }

        bool restartedAfterCrash = args.Length > 0 && args[0] == "--restarted-after-crash";

        // Single instance. After a crash, Windows relaunches us while the
        // dying process is still being held open for the crash report — and
        // still owns this mutex — so the relaunch waits for it to let go
        // (it becomes abandoned when that process finally terminates).
        using var mutex = new Mutex(false, "VoxFlowWinSingleInstance");
        bool owned = false;
        var deadline = DateTime.Now.AddSeconds(restartedAfterCrash ? 60 : 0);
        do
        {
            try { owned = mutex.WaitOne(restartedAfterCrash ? 500 : 0); }
            catch (AbandonedMutexException) { owned = true; } // previous owner died: it is ours
        } while (!owned && DateTime.Now < deadline);
        if (!owned)
        {
            Log.Info("Another instance is already running — exiting");
            if (!restartedAfterCrash)
                MessageBox.Show("VoxFlow is already running (check the system tray).",
                    "VoxFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        // If the process ever dies from something managed code cannot catch
        // (a native access violation in an audio or GPU driver), Windows
        // Error Reporting relaunches it with this command line. Windows only
        // honours it once the app has been up for 60 s, which also prevents
        // a crash loop. Nothing to do with clean exits from the tray menu.
        int rar = RegisterApplicationRestart("--restarted-after-crash", RESTART_NO_PATCH | RESTART_NO_REBOOT);
        Log.Info($"RegisterApplicationRestart hr=0x{rar:X}");
        if (restartedAfterCrash)
            Log.Info("Relaunched by Windows after a crash");
        if (args.Length > 0 && args[0] == "--crash-after" && args.Length > 1)
            ScheduleCrashForTesting(int.Parse(args[1]));

        try
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new TrayAppContext());
            Log.Info("=== VoxFlow exited normally ===");
            return 0;
        }
        catch (Exception ex)
        {
            Log.Error("FATAL during startup", ex);
            MessageBox.Show("VoxFlow failed to start:\n\n" + ex.Message +
                            "\n\nDetails were written to:\n" + Log.Path,
                "VoxFlow", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
