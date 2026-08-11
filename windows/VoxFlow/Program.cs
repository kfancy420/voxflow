using System;
using System.Threading;
using System.Windows.Forms;

namespace VoxFlow;

internal static class Program
{
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

        using var mutex = new Mutex(true, "VoxFlowWinSingleInstance", out bool createdNew);
        if (!createdNew)
        {
            Log.Info("Another instance is already running — exiting");
            MessageBox.Show("VoxFlow is already running (check the system tray).",
                "VoxFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

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
