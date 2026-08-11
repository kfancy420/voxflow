using System;
using System.Threading;
using System.Windows.Forms;

namespace VoxFlow;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, "VoxFlowWinSingleInstance", out bool createdNew);
        if (!createdNew)
        {
            MessageBox.Show("VoxFlow is already running (check the system tray).",
                "VoxFlow", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayAppContext());
    }
}
