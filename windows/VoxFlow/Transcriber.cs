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
/// The whisper backend stopped working mid-session (seen on Vulkan after the
/// GPU context was lost: a long, audible take came back empty in a few ms and
/// the next call never returned). <see cref="Hung"/> means the native call is
/// still blocked and the process must be restarted; otherwise a model reload
/// is enough.
/// </summary>
public sealed class TranscriberFaultException : Exception
{
    public bool Hung { get; }
    public TranscriberFaultException(string message, bool hung) : base(message) => Hung = hung;
}

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
    private ModelInfo? _loadedModel;
    public bool IsReady { get; private set; }

    /// <summary>Re-creates the backend for the current model after a fault.</summary>
    public Task ReloadAsync() => LoadAsync(_loadedModel ?? Models[2]);

    /// <summary>Which whisper backend actually loaded ("Vulkan" / "Cpu").</summary>
    public string Backend { get; private set; } = "unknown";

    /// <summary>
    /// Only used by the CPU backend, but whisper.cpp defaults to min(4, cores)
    /// which badly under-uses a modern desktop CPU. Half the logical
    /// processors keeps dictation fast without monopolising the machine.
    /// </summary>
    private static int ThreadCount => Math.Clamp(Environment.ProcessorCount / 2, 4, 16);

    private const string PunctuationPrompt =
        "Okay, so here's the thing. I looked at it again, and honestly, it's not right. " +
        "First, the menu doesn't work. Second, it's slow. Can you fix that? Thanks.";

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

    private Task? _currentLoad;

    public Task LoadAsync(ModelInfo model)
    {
        var task = LoadCoreAsync(model);
        _currentLoad = task;
        return task;
    }

    /// <summary>
    /// If a (re)load is in flight, waits for it. Lets a dictation that was
    /// captured while the engine was being rebuilt proceed on the new engine
    /// instead of failing.
    /// </summary>
    public async Task WaitForEngineAsync()
    {
        var load = _currentLoad;
        if (load != null && !load.IsCompleted)
        {
            Log.Info("Waiting for engine reload before transcribing…");
            // Disposing a processor whose GPU context is gone can itself
            // wedge inside the driver; a reload that never finishes is the
            // same as a hang.
            if (await Task.WhenAny(load, Task.Delay(TimeSpan.FromSeconds(ReloadSeconds))) != load)
            {
                Log.Error($"Engine reload did not finish within {ReloadSeconds}s");
                throw new TranscriberFaultException(
                    "The speech engine could not be rebuilt. VoxFlow is restarting itself; your dictation was saved.", hung: true);
            }
        }
    }

    private const double ReloadSeconds = 90;

    private async Task LoadCoreAsync(ModelInfo model)
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
                // Whisper mirrors the style of whatever text precedes the
                // audio. A punctuated, conversational prompt makes it keep
                // emitting commas and full stops on fast, run-on speech, where
                // it otherwise drops them entirely.
                .WithPrompt(PunctuationPrompt)
                // Per-word timing: pauses between words are how sentence
                // boundaries are recovered when whisper drops punctuation.
                .WithTokenTimestamps()
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

            _loadedModel = model;
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
        await WaitForEngineAsync();
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

        double audioSeconds = samples.Length / 16000.0;
        var budget = TimeSpan.FromSeconds(Math.Max(HungSeconds, audioSeconds * HungMultiplier));
        var (rawText, segmentCount, elapsedMs) = await RunGuardedAsync(samples, budget, "dictation");

        // A dead GPU context does not throw — whisper just returns no
        // segments almost instantly. Real inference on a second or more
        // of clearly audible speech never finishes that fast.
        if (segmentCount == 0 && audioSeconds >= 1.0 && rms >= QuietRms && elapsedMs < InstantEmptyMs)
        {
            IsReady = false;
            Log.Error($"Backend returned nothing in {elapsedMs} ms for {audioSeconds:F1}s of audio " +
                      $"(rms={rms:F4}, backend={Backend}) — treating as a lost context");
            throw new TranscriberFaultException(
                "The speech engine lost its GPU context; reloading it and retrying your dictation.", hung: false);
        }

        string text = StripArtifacts(rawText);

        if (rms < QuietRms && IsLikelyHallucination(text))
        {
            Log.Info($"Discarded likely hallucination \"{text}\" (rms={rms:F5})");
            return string.Empty;
        }
        return text;
    }

    public enum Health { Ok, Dead, Hung, Skipped }

    /// <summary>
    /// Proves the backend can still transcribe real speech. Cheap enough
    /// (well under a second on the GPU) to run on every hotkey press, and it
    /// runs concurrently with the microphone, so a dead engine is already
    /// being rebuilt while the user is still talking.
    /// </summary>
    public async Task<Health> ProbeAsync(string trigger)
    {
        if (!IsReady || _processor == null) return Health.Skipped;
        var clip = HealthClip.Samples;

        try
        {
            if (clip != null)
            {
                var (text, segments, ms) = await RunGuardedAsync(clip, TimeSpan.FromSeconds(ProbeSeconds), $"probe:{trigger}");
                string t = StripArtifacts(text);
                if (segments > 0 && HealthClip.Matches(t))
                {
                    Log.Info($"Engine probe OK ({trigger}, {ms} ms, backend={Backend})");
                    return Health.Ok;
                }
                Log.Error($"Engine probe FAILED ({trigger}): {segments} segment(s) in {ms} ms, heard \"{t}\" (backend={Backend})");
            }
            else
            {
                // No speech clip: the best available signal is timing. Half a
                // second of silence takes ~100 ms of real work on the GPU; a
                // dead context returns in a couple of ms.
                var (_, _, ms) = await RunGuardedAsync(new float[8000], TimeSpan.FromSeconds(ProbeSeconds), $"probe:{trigger}");
                if (ms >= 15) return Health.Ok;
                Log.Error($"Engine probe FAILED ({trigger}): silence 'processed' in {ms} ms (backend={Backend})");
            }
        }
        catch (TranscriberFaultException f) when (f.Hung)
        {
            return Health.Hung;
        }

        IsReady = false;
        return Health.Dead;
    }

    /// <summary>
    /// Runs the native call under the gate with a watchdog. The call cannot be
    /// cancelled, so on timeout the gate stays held and the caller must
    /// restart the process.
    /// </summary>
    private async Task<(string Text, int Segments, long ElapsedMs)> RunGuardedAsync(
        float[] samples, TimeSpan budget, string what)
    {
        await _gate.WaitAsync();
        bool hung = false;
        try
        {
            var processor = _processor ?? throw new InvalidOperationException("Model not loaded.");
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var work = Task.Run(async () =>
            {
                var punctuator = new PausePunctuator();
                int segments = 0;
                await foreach (var segment in processor.ProcessAsync(samples))
                {
                    segments++;
                    punctuator.AddSegment(segment);
                }
                return (punctuator.Finish(), segments);
            });

            if (await Task.WhenAny(work, Task.Delay(budget)) != work)
            {
                hung = true;
                IsReady = false;
                Log.Error($"Transcription hung ({what}): no result after {budget.TotalSeconds:F0}s " +
                          $"for {samples.Length / 16000.0:F1}s of audio (backend={Backend})");
                throw new TranscriberFaultException(
                    "The speech engine stopped responding. VoxFlow is restarting itself; your dictation was saved.", hung: true);
            }
            var (text, count) = await work;
            return (text, count, sw.ElapsedMilliseconds);
        }
        finally
        {
            if (!hung) _gate.Release();
        }
    }

    /// <summary>
    /// Rebuilds the transcript from whisper's tokens, restoring the sentence
    /// breaks whisper drops on fast speech. Two signals: (1) a long pause
    /// before a word — people breathe at sentence ends even when talking
    /// fast; (2) whisper starts every new segment capitalised, which on an
    /// unpunctuated predecessor means a sentence ended there. Whisper's own
    /// punctuation is always kept; nothing is inserted next to it. Word
    /// timestamps are noisy by up to ~400 ms on words with no pause at all,
    /// so the pause threshold is deliberately high and commas are never
    /// inferred from timing.
    /// </summary>
    private sealed class PausePunctuator
    {
        private const long PeriodGapCs = 100; // ≥ 1 s of silence: hesitations run 700 ms+
        private static readonly bool DebugGaps =
            Environment.GetEnvironmentVariable("VOXFLOW_DEBUG_GAPS") == "1";

        private readonly StringBuilder _sb = new();
        private long _prevEndCs = -1;
        private int _periods;

        public void AddSegment(SegmentData segment)
        {
            bool firstInSegment = true;
            var tokens = segment.Tokens;
            if (tokens == null || tokens.Length == 0)
            {
                // No token detail: fall back to the segment text as one unit.
                AppendWord(" " + segment.Text.Trim(), -1, true);
                return;
            }
            foreach (var tok in tokens)
            {
                string text = tok.Text;
                if (string.IsNullOrEmpty(text) || text.StartsWith("[_", StringComparison.Ordinal)) continue;
                AppendWord(text, tok.Start, firstInSegment);
                _prevEndCs = tok.End;
                firstInSegment = false;
            }
        }

        private void AppendWord(string text, long startCs, bool segmentStart)
        {
            bool wordStart = text[0] == ' ' || segmentStart || _sb.Length == 0;
            if (wordStart && _sb.Length > 0 && !EndsWithPunctuation())
            {
                long gap = (startCs >= 0 && _prevEndCs >= 0) ? startCs - _prevEndCs : 0;
                string word = text.TrimStart();
                bool capital = word.Length > 0 && char.IsUpper(word[0]);
                bool pronounI = word == "I" || word.StartsWith("I ") || word.StartsWith("I'");
                bool sentence = gap >= PeriodGapCs
                             || (segmentStart && capital && (!pronounI || gap >= 30));
                if (DebugGaps && gap >= 10) Log.Info($"gap {gap * 10} ms before \"{word}\" (segStart={segmentStart})");
                if (sentence)
                {
                    _sb.Append('.');
                    _periods++;
                    text = " " + Capitalize(word);
                }
            }
            if (wordStart && _sb.Length > 0 && text[0] != ' ') _sb.Append(' ');
            _sb.Append(text);
        }

        private bool EndsWithPunctuation()
        {
            for (int i = _sb.Length - 1; i >= 0; i--)
            {
                char c = _sb[i];
                if (char.IsWhiteSpace(c)) continue;
                return c is '.' or '!' or '?' or ',' or ';' or ':' or '…' or '—' or '-' or '"' or '(' or '[';
            }
            return true;
        }

        private static string Capitalize(string w) =>
            w.Length == 0 ? w : char.ToUpperInvariant(w[0]) + w.Substring(1);

        public string Finish()
        {
            if (_periods > 0)
                Log.Info($"Sentence breaks inferred from pauses/segments: {_periods}");
            return _sb.ToString();
        }
    }

    private const double HungSeconds = 30;      // floor for short takes
    private const double HungMultiplier = 3;    // × audio length for long takes
    private const double ProbeSeconds = 15;
    private const int InstantEmptyMs = 150;

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
