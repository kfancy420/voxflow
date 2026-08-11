using System.Diagnostics;
using System.Text;
using NAudio.Wave;
using Whisper.net;
using Whisper.net.LibraryLoader;

// bench <manifest.tsv> <model.bin> [<model.bin> ...]
// manifest lines: <wavPath>\t<reference transcript>
//
// Reports word error rate and latency per model, on clean audio and on the
// same audio mixed with noise at 10 dB SNR (a Yeti in a room with a PC fan is
// not a recording booth).

string manifest = args[0];
string[] models = args.Skip(1).ToArray();

var clips = new List<(string Name, float[] Clean, float[] Noisy, string Reference)>();
foreach (var line in File.ReadAllLines(manifest))
{
    if (string.IsNullOrWhiteSpace(line)) continue;
    var parts = line.Split('\t');
    var samples = ReadWav(parts[0]);
    clips.Add((Path.GetFileNameWithoutExtension(parts[0]), samples, AddNoise(samples, 10.0), parts[1]));
}
Console.WriteLine($"{clips.Count} clips, {clips.Sum(c => c.Clean.Length) / 16000.0:F1}s total audio");

RuntimeOptions.RuntimeLibraryOrder = new List<RuntimeLibrary> { RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu };

Console.WriteLine();
Console.WriteLine($"{"model",-28} {"cond",-6} {"WER%",6} {"med ms",7} {"max ms",7}");
Console.WriteLine(new string('-', 62));

var summary = new List<string>();

foreach (var modelPath in models)
{
    string name = Path.GetFileNameWithoutExtension(modelPath);
    if (!File.Exists(modelPath)) { Console.WriteLine($"{name,-28} MISSING"); continue; }

    WhisperFactory factory;
    try { factory = WhisperFactory.FromPath(modelPath); }
    catch (Exception ex) { Console.WriteLine($"{name,-28} LOAD FAILED: {ex.Message}"); continue; }

    using var proc = factory.CreateBuilder()
        .WithLanguage("en")
        .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 4, 16))
        .WithNoContext()
        .Build();

    // warm-up (Vulkan shader compilation / first-run allocation)
    await foreach (var _ in proc.ProcessAsync(new float[8000])) { }

    foreach (var cond in new[] { "clean", "noisy" })
    {
        int totalErrors = 0, totalWords = 0;
        var times = new List<long>();
        foreach (var clip in clips)
        {
            float[] audio = cond == "clean" ? clip.Clean : clip.Noisy;
            var sw = Stopwatch.StartNew();
            var sb = new StringBuilder();
            await foreach (var seg in proc.ProcessAsync(audio)) sb.Append(seg.Text);
            sw.Stop();
            times.Add(sw.ElapsedMilliseconds);

            var (errors, words) = Wer(clip.Reference, sb.ToString());
            totalErrors += errors;
            totalWords += words;
            if (cond == "clean" && errors > 0)
                Console.WriteLine($"    [{name} {clip.Name}] {errors}/{words} err: \"{Norm(sb.ToString())}\"");
        }
        times.Sort();
        double wer = 100.0 * totalErrors / Math.Max(1, totalWords);
        string row = $"{name,-28} {cond,-6} {wer,6:F1} {times[times.Count / 2],7} {times[^1],7}";
        Console.WriteLine(row);
        summary.Add(row);
    }

    factory.Dispose();
}

Console.WriteLine();
Console.WriteLine("=== SUMMARY ===");
foreach (var s in summary) Console.WriteLine(s);

// ---------- helpers ----------

static string Norm(string s)
{
    var sb = new StringBuilder();
    foreach (char c in s.ToLowerInvariant())
        sb.Append(char.IsLetterOrDigit(c) ? c : ' ');
    return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
}

static (int errors, int words) Wer(string reference, string hypothesis)
{
    var r = Norm(reference).Split(' ', StringSplitOptions.RemoveEmptyEntries);
    var h = Norm(hypothesis).Split(' ', StringSplitOptions.RemoveEmptyEntries);
    var d = new int[r.Length + 1, h.Length + 1];
    for (int i = 0; i <= r.Length; i++) d[i, 0] = i;
    for (int j = 0; j <= h.Length; j++) d[0, j] = j;
    for (int i = 1; i <= r.Length; i++)
        for (int j = 1; j <= h.Length; j++)
            d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1),
                               d[i - 1, j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1));
    return (d[r.Length, h.Length], r.Length);
}

static float[] AddNoise(float[] input, double snrDb)
{
    double signalPower = input.Select(s => (double)s * s).DefaultIfEmpty(0).Average();
    double noisePower = signalPower / Math.Pow(10, snrDb / 10.0);
    double amplitude = Math.Sqrt(noisePower);
    var rng = new Random(1234); // fixed seed: every model sees identical noise
    var outp = new float[input.Length];
    for (int i = 0; i < input.Length; i++)
    {
        // Box-Muller gaussian
        double u1 = 1.0 - rng.NextDouble(), u2 = rng.NextDouble();
        double g = Math.Sqrt(-2.0 * Math.Log(u1)) * Math.Cos(2.0 * Math.PI * u2);
        outp[i] = (float)Math.Clamp(input[i] + g * amplitude, -1.0, 1.0);
    }
    return outp;
}

static float[] ReadWav(string path)
{
    using var reader = new AudioFileReader(path);
    ISampleProvider p = reader;
    if (p.WaveFormat.Channels > 1) p = p.ToMono();
    if (p.WaveFormat.SampleRate != 16000)
        p = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(p, 16000);
    var buf = new float[16000];
    var all = new List<float>();
    int n;
    while ((n = p.Read(buf, 0, buf.Length)) > 0) all.AddRange(buf.AsSpan(0, n).ToArray());
    return all.ToArray();
}
