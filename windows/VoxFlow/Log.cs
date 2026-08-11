using System;
using System.IO;
using System.Text;

namespace VoxFlow;

/// <summary>
/// Append-only diagnostic log at %APPDATA%\VoxFlow\voxflow.log.
/// Deliberately dependency-free and exception-proof: logging must never be
/// the reason the app fails.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private static string? _path;

    public static string Path
    {
        get
        {
            if (_path == null)
            {
                string dir = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoxFlow");
                try { Directory.CreateDirectory(dir); } catch { }
                _path = System.IO.Path.Combine(dir, "voxflow.log");
            }
            return _path;
        }
    }

    public static void Info(string message) => Write("INFO ", message);
    public static void Warn(string message) => Write("WARN ", message);

    public static void Error(string message, Exception? ex = null)
    {
        var sb = new StringBuilder(message);
        if (ex != null)
        {
            sb.Append(Environment.NewLine).Append(ex.ToString());
            var inner = ex.InnerException;
            int depth = 0;
            while (inner != null && depth++ < 5)
            {
                sb.Append(Environment.NewLine).Append("--- inner ---").Append(Environment.NewLine).Append(inner.ToString());
                inner = inner.InnerException;
            }
        }
        Write("ERROR", sb.ToString());
    }

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                // Keep the log from growing without bound across a long-running install.
                try
                {
                    var fi = new FileInfo(Path);
                    if (fi.Exists && fi.Length > 1_000_000)
                        File.WriteAllText(Path, $"{Stamp()} INFO  (log truncated){Environment.NewLine}");
                }
                catch { }

                File.AppendAllText(Path, $"{Stamp()} {level} {message}{Environment.NewLine}");
            }
        }
        catch { /* logging must never throw */ }
    }

    private static string Stamp() => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
}
