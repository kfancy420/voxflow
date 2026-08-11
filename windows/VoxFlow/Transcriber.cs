using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace VoxFlow;

/// <summary>
/// Whisper.net wrapper: downloads the GGML model on first use to
/// %APPDATA%\VoxFlow\models and transcribes 16 kHz mono Float32 samples.
/// </summary>
public sealed class Transcriber : IDisposable
{
    /// <summary>A selectable Whisper model.</summary>
    public sealed record ModelInfo(string Id, string FileName, string MenuLabel);

    /// <summary>
    /// Ordered fastest → most accurate. Measured on an RTX 5080 over a
    /// 10-clip dictation set (see README): base.en is the only one that
    /// produces outright garbage on technical vocabulary, and large-v3-turbo
    /// was no more accurate than medium.en for English while being slower, so
    /// only the quantised turbo is offered — and only for non-English use.
    /// </summary>
    public static readonly ModelInfo[] Models =
    {
        new("base.en",             "ggml-base.en.bin",             "Base — fastest (148 MB)"),
        new("small.en",            "ggml-small.en.bin",            "Small — balanced (488 MB)"),
        new("medium.en",           "ggml-medium.en.bin",           "Medium — most accurate English (1.5 GB)"),
        new("large-v3-turbo-q5_0", "ggml-large-v3-turbo-q5_0.bin", "Turbo — multilingual (547 MB)"),
    };

    public static ModelInfo Resolve(string? id) =>
        Array.Find(Models, m => m.Id == id) ?? Models[2];

    /// <summary>Progress messages for the tray ("Downloading model… 43%", "Ready").</summary>
    public event Action<string>? Status;

    private WhisperFactory? _factory;
    private WhisperProcessor? _processor;
    private readonly SemaphoreSlim _gate = new(1, 1);
    public bool IsReady { get; private set; }

    /// <summary>Which whisper backend actually loaded ("Vulkan" / "Cpu").</summary>
    public string Backend { get; private set; } = "unknown";

    /// <summary>
    /// Only used by the CPU backend, but whisper.cpp defaults to min(4, cores)
    /// which badly under-uses a modern desktop CPU. Half the logical
    /// processors keeps dictation fast without monopolising the machine.
    /// </summary>
    private static int ThreadCount => Math.Clamp(Environment.ProcessorCount / 2, 4, 16);

    private static bool _runtimeOrderSet;

    /// <summary>
    /// Prefer the GPU, fall back to CPU. Whisper.net walks this list in order
    /// and uses the first library that loads, so an unsupported driver costs
    /// nothing but a log line. Must be set before the first WhisperFactory.
    /// </summary>
    private static void ConfigureRuntimeOrder()
    {
        if (_runtimeOrderSet) return;
        _runtimeOrderSet = true;
        RuntimeOptions.RuntimeLibraryOrder = new List<RuntimeLibrary>
        {
            RuntimeLibrary.Vulkan,
            RuntimeLibrary.Cpu,
        };
        Log.Info($"Runtime preference: Vulkan then Cpu (cpu threads={ThreadCount}, cores={Environment.ProcessorCount})");
    }

    public static string ModelsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoxFlow", "models");

    public static string ModelPath(ModelInfo model) => Path.Combine(ModelsDirectory, model.FileName);

    public static bool IsDownloaded(ModelInfo model) => File.Exists(ModelPath(model));

    private static string ModelUrl(ModelInfo model) =>
        $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{model.FileName}";

    public async Task LoadAsync(ModelInfo model)
    {
        await _gate.WaitAsync();
        try
        {
            IsReady = false;
            _processor?.Dispose();
            _factory?.Dispose();
            _processor = null;
            _factory = null;

            Directory.CreateDirectory(ModelsDirectory);
            string modelPath = ModelPath(model);

            if (!File.Exists(modelPath))
            {
                await DownloadModelAsync(model, modelPath);
            }

            Status?.Invoke("Loading model…");
            Log.Info($"Loading {model.Id} from {modelPath} " +
                     $"(bytes={(File.Exists(modelPath) ? new FileInfo(modelPath).Length : -1)})");
            EnsureNativeLibrariesPresent();
            ConfigureRuntimeOrder();

            _factory = WhisperFactory.FromPath(modelPath);
            Backend = RuntimeOptions.LoadedLibrary?.ToString() ?? "Cpu";
            Log.Info($"WhisperFactory.FromPath OK — backend={Backend}");

            _processor = _factory.CreateBuilder()
                .WithLanguage("en")
                .WithThreads(ThreadCount)
                // Each dictation is independent, so carrying decoder context
                // between them only costs time and invites cross-contamination.
                .WithNoContext()
                .Build();

            // Warm-up with half a second of silence so the first real
            // dictation doesn't pay initialization costs. On the Vulkan
            // backend this is also where shader compilation happens — without
            // it, the user's first dictation would stall for several seconds.
            var warmSw = System.Diagnostics.Stopwatch.StartNew();
            var warmup = new float[8000];
            await foreach (var _ in _processor.ProcessAsync(warmup)) { }
            warmSw.Stop();

            IsReady = true;
            Log.Info($"Model ready: {model.Id} (warm-up {warmSw.ElapsedMilliseconds} ms, backend={Backend})");
            Status?.Invoke($"Ready — {model.Id} on {Backend}");
        }
        catch (Exception ex)
        {
            Log.Error($"LoadAsync FAILED for {model.Id}", ex);
            Status?.Invoke($"Model error: {ex.Message}");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task DownloadModelAsync(ModelInfo model, string destination)
    {
        Log.Info($"Downloading {model.Id} from {ModelUrl(model)}");
        Status?.Invoke("Downloading model… 0%");
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        using var response = await http.GetAsync(ModelUrl(model), HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        long total = response.Content.Headers.ContentLength ?? -1;

        string tempPath = destination + ".part";
        await using (var input = await response.Content.ReadAsStreamAsync())
        await using (var output = File.Create(tempPath))
        {
            var buffer = new byte[1 << 16];
            long written = 0;
            int lastPercent = -1;
            int read;
            while ((read = await input.ReadAsync(buffer)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read));
                written += read;
                if (total > 0)
                {
                    int percent = (int)(written * 100 / total);
                    if (percent != lastPercent)
                    {
                        lastPercent = percent;
                        Status?.Invoke($"Downloading model… {percent}%");
                    }
                }
            }
        }
        File.Move(tempPath, destination, overwrite: true);
        Log.Info($"Downloaded {model.Id} ({new FileInfo(destination).Length} bytes)");
    }

    /// <summary>
    /// Whisper.net probes AppContext.BaseDirectory\runtimes\{rid}\ for its
    /// native libraries and, when they are absent, throws a message that says
    /// nothing about where it looked. Check first so the failure names the
    /// actual missing path.
    /// </summary>
    private static void EnsureNativeLibrariesPresent()
    {
        string rid = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.Arm64 => "win-arm64",
            Architecture.X86 => "win-x86",
            _ => "win-x64"
        };
        string whisperDll = Path.Combine(AppContext.BaseDirectory, "runtimes", rid, "whisper.dll");
        string vulkanDll = Path.Combine(AppContext.BaseDirectory, "runtimes", "vulkan", rid, "whisper.dll");
        Log.Info($"native probe: cpu={File.Exists(whisperDll)}, vulkan={File.Exists(vulkanDll)}");

        if (!File.Exists(whisperDll))
        {
            throw new FileNotFoundException(
                "VoxFlow's Whisper native libraries are missing. Expected: " + whisperDll +
                ". Copy the whole VoxFlow folder (VoxFlow.exe *and* the runtimes folder), not just the .exe.",
                whisperDll);
        }
    }

    /// <summary>
    /// Whisper reliably invents polite filler when handed silence — "Thank
    /// you.", "Thanks for watching!" and friends are artefacts of its training
    /// data, not transcription. Without a guard those get pasted into whatever
    /// the user is typing in, so quiet takes are rejected outright and a short
    /// result from a quiet take is treated as a hallucination.
    /// </summary>
    private static readonly string[] SilenceHallucinations =
    {
        "thank you", "thank you.", "thanks", "thanks.", "thank you very much",
        "thanks for watching", "thanks for watching!", "thank you for watching",
        "you", "bye", "bye.", "okay", "ok", ".", "so", "yeah",
    };

    private const float SilenceRms = 0.004f;   // ≈ -48 dBFS: nothing was said
    private const float QuietRms = 0.02f;      // low enough to distrust filler

    /// <summary>Transcribes samples to raw text. Returns "" for very short takes.</summary>
    public async Task<string> TranscribeAsync(float[] samples)
    {
        if (!IsReady || _processor == null)
            throw new InvalidOperationException("Model not loaded yet — check the tray icon for status.");
        if (samples.Length < 4800) // under 0.3 s
            return string.Empty;

        float rms = Rms(samples);
        if (rms < SilenceRms)
        {
            Log.Info($"Take rejected as silence (rms={rms:F5})");
            return string.Empty;
        }

        await _gate.WaitAsync();
        try
        {
            var sb = new StringBuilder();
            await foreach (var segment in _processor.ProcessAsync(samples))
            {
                sb.Append(segment.Text);
            }
            string text = StripArtifacts(sb.ToString());

            if (rms < QuietRms && IsLikelyHallucination(text))
            {
                Log.Info($"Discarded likely hallucination \"{text}\" (rms={rms:F5})");
                return string.Empty;
            }
            return text;
        }
        finally
        {
            _gate.Release();
        }
    }

    private static bool IsLikelyHallucination(string text)
    {
        string t = text.Trim().Trim('!', '.', ',', '?').ToLowerInvariant();
        return t.Length == 0 || Array.IndexOf(SilenceHallucinations, t) >= 0;
    }

    private static float Rms(float[] samples)
    {
        double sum = 0;
        foreach (float s in samples) sum += s * (double)s;
        return samples.Length == 0 ? 0f : (float)Math.Sqrt(sum / samples.Length);
    }

    private static string StripArtifacts(string text)
    {
        string t = Regex.Replace(text, @"\[[A-Z_ ]+\]|\((?:silence|music|noise)\)|<\|[^|]*\|>", "",
            RegexOptions.IgnoreCase);
        return Regex.Replace(t, @"\s+", " ").Trim();
    }

    public void Dispose()
    {
        _processor?.Dispose();
        _factory?.Dispose();
        _gate.Dispose();
    }
}
