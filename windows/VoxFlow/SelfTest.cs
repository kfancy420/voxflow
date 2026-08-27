using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using NAudio.Wave;

namespace VoxFlow;

/// <summary>
/// Headless verification entry points. VoxFlow is a hold-a-key-and-talk app,
/// which makes it awkward to prove correct without a human in the chair; these
/// modes exercise each stage of the pipeline independently so a failure can be
/// pinned to one component.
///
///   --selftest-wav &lt;path&gt;   model load → transcribe → dictionary → cleanup
///   --selftest-mic &lt;secs&gt;   capture from the default mic, report level, transcribe
///   --selftest-insert &lt;text&gt; clipboard-preserving paste into the focused window
///
/// Results go to %APPDATA%\VoxFlow\selftest.txt as well as the log.
/// </summary>
internal static class SelfTest
{
    public static string ResultPath =>
        Path.Combine(Settings.AppDataDirectory(), "selftest.txt");

    public static int Run(string[] args)
    {
        var report = new StringBuilder();
        int exitCode = 0;
        try
        {
            switch (args[0])
            {
                case "--selftest-wav":
                    exitCode = TranscribeWav(args.Length > 1 ? args[1] : "", report);
                    break;
                case "--selftest-mic":
                    exitCode = RecordMic(args.Length > 1 ? double.Parse(args[1]) : 3.0, report);
                    break;
                case "--selftest-clean":
                    // Runs the cleanup pipeline on a text file: punctuation
                    // rules can be tuned against real transcripts offline.
                    report.AppendLine("MODE --selftest-clean " + args[1]);
                    report.AppendLine("CLEANED : " + TextCleaner.Clean(File.ReadAllText(args[1])));
                    break;
                case "--selftest-insert":
                    exitCode = InsertText(args.Length > 1 ? args[1] : "VoxFlow insertion test", report);
                    break;
                default:
                    report.AppendLine("unknown selftest mode: " + args[0]);
                    exitCode = 2;
                    break;
            }
        }
        catch (Exception ex)
        {
            report.AppendLine("EXCEPTION: " + ex);
            exitCode = 1;
        }

        string text = report.ToString();
        Log.Info("selftest result:" + Environment.NewLine + text);
        try { File.WriteAllText(ResultPath, text); } catch { }
        return exitCode;
    }

    private static Transcriber LoadModel(StringBuilder report)
    {
        var settings = Settings.Load();
        var model = Transcriber.Resolve(settings.Model);

        var transcriber = new Transcriber();
        transcriber.Status += s => report.AppendLine("  status: " + s);
        var started = DateTime.Now;
        transcriber.LoadAsync(model).GetAwaiter().GetResult();
        report.AppendLine($"  model load: {(DateTime.Now - started).TotalSeconds:F1}s ready={transcriber.IsReady}");
        return transcriber;
    }

    private static int TranscribeWav(string path, StringBuilder report)
    {
        report.AppendLine($"MODE --selftest-wav {path}");
        if (!File.Exists(path))
        {
            report.AppendLine("  FAIL: file not found");
            return 1;
        }

        float[] samples = ReadWav16kMono(path, report);
        report.AppendLine($"  samples={samples.Length} ({samples.Length / 16000.0:F2}s)");

        using var transcriber = LoadModel(report);
        if (!transcriber.IsReady)
        {
            report.AppendLine("  FAIL: model not ready");
            return 1;
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        string raw = transcriber.TranscribeAsync(samples).GetAwaiter().GetResult().Trim();
        sw.Stop();

        string withDict = PersonalDictionary.Apply(raw);
        string cleaned = TextCleaner.Clean(withDict);

        report.AppendLine($"  transcribe: {sw.ElapsedMilliseconds} ms");
        report.AppendLine($"  RAW     : \"{raw}\"");
        report.AppendLine($"  CLEANED : \"{cleaned}\"");
        report.AppendLine(raw.Length > 0 ? "  PASS" : "  FAIL: empty transcript");
        return raw.Length > 0 ? 0 : 1;
    }

    private static int RecordMic(double seconds, StringBuilder report)
    {
        report.AppendLine($"MODE --selftest-mic {seconds}s");
        report.AppendLine($"  input devices: {WaveInEvent.DeviceCount}");
        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
            report.AppendLine($"    [{i}] {WaveInEvent.GetCapabilities(i).ProductName}");

        if (WaveInEvent.DeviceCount == 0)
        {
            report.AppendLine("  FAIL: no capture device");
            return 1;
        }

        var recorder = new AudioRecorder();
        float peakLevel = 0f;
        recorder.Level += l => { if (l > peakLevel) peakLevel = l; };

        recorder.Start();
        Thread.Sleep((int)(seconds * 1000));
        float[] samples = recorder.Stop();
        recorder.Dispose();

        double sumSquares = 0;
        float peakSample = 0f;
        foreach (float s in samples)
        {
            sumSquares += s * (double)s;
            float a = Math.Abs(s);
            if (a > peakSample) peakSample = a;
        }
        double rms = samples.Length > 0 ? Math.Sqrt(sumSquares / samples.Length) : 0;

        report.AppendLine($"  captured samples={samples.Length} ({samples.Length / 16000.0:F2}s)");
        report.AppendLine($"  rms={rms:F5} peak={peakSample:F5} peakHudLevel={peakLevel:F3}");

        if (samples.Length < 16000 * seconds * 0.5)
        {
            report.AppendLine("  FAIL: capture delivered far fewer samples than expected");
            return 1;
        }
        report.AppendLine(peakSample > 0.001f
            ? "  PASS: device open and delivering non-silent audio"
            : "  PASS(device): capture works, but the signal is silent — check the input device/level");

        using var transcriber = LoadModel(report);
        if (transcriber.IsReady && samples.Length >= 4800)
        {
            string raw = transcriber.TranscribeAsync(samples).GetAwaiter().GetResult().Trim();
            report.AppendLine($"  transcript from mic: \"{raw}\"");
        }
        return 0;
    }

    private static int InsertText(string text, StringBuilder report)
    {
        report.AppendLine($"MODE --selftest-insert \"{text}\"");
        report.AppendLine("  waiting 3s for the caller to focus a target window…");
        PumpFor(3000);

        string before = "";
        try { before = Clipboard.ContainsText() ? Clipboard.GetText() : ""; } catch { }
        report.AppendLine($"  clipboard before: \"{Truncate(before)}\"");

        var inserter = new TextInserter();
        inserter.Insert(text, trailingSpace: false);

        // Let the paste land and the clipboard-restore timer fire.
        PumpFor(2000);

        string after = "";
        try { after = Clipboard.ContainsText() ? Clipboard.GetText() : ""; } catch { }
        report.AppendLine($"  clipboard after : \"{Truncate(after)}\"");
        report.AppendLine(after == before
            ? "  PASS: clipboard restored to its original contents"
            : "  WARN: clipboard was not restored to its original contents");
        return 0;
    }

    private static string Truncate(string s) =>
        s.Length <= 40 ? s.Replace("\r", "").Replace("\n", "\\n") : s.Substring(0, 40).Replace("\r", "").Replace("\n", "\\n") + "…";

    /// <summary>Runs a WinForms message pump for a while so timers can tick.</summary>
    private static void PumpFor(int milliseconds)
    {
        var until = DateTime.Now.AddMilliseconds(milliseconds);
        while (DateTime.Now < until)
        {
            Application.DoEvents();
            Thread.Sleep(20);
        }
    }

    /// <summary>Reads a WAV into the 16 kHz mono float format Whisper expects.</summary>
    private static float[] ReadWav16kMono(string path, StringBuilder report)
    {
        using var reader = new AudioFileReader(path);
        report.AppendLine($"  wav format: {reader.WaveFormat}");

        ISampleProvider provider = reader;
        if (provider.WaveFormat.Channels > 1)
            provider = provider.ToMono();
        if (provider.WaveFormat.SampleRate != 16000)
        {
            report.AppendLine("  resampling to 16 kHz");
            provider = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(provider, 16000);
        }

        var buffer = new float[16000];
        var all = new System.Collections.Generic.List<float>();
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            all.AddRange(new ReadOnlySpan<float>(buffer, 0, read).ToArray());
        return all.ToArray();
    }
}
