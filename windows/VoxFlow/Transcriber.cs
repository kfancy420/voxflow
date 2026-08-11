using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Whisper.net;

namespace VoxFlow;

/// <summary>
/// Whisper.net wrapper: downloads the GGML model on first use to
/// %APPDATA%\VoxFlow\models and transcribes 16 kHz mono Float32 samples.
/// </summary>
public sealed class Transcriber : IDisposable
{
    public enum ModelChoice { BaseEn, SmallEn }

    /// <summary>Progress messages for the tray ("Downloading model… 43%", "Ready").</summary>
    public event Action<string>? Status;

    private WhisperFactory? _factory;
    private WhisperProcessor? _processor;
    private readonly SemaphoreSlim _gate = new(1, 1);
    public bool IsReady { get; private set; }

    private static string ModelsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoxFlow", "models");

    private static string ModelFileName(ModelChoice choice) => choice switch
    {
        ModelChoice.BaseEn => "ggml-base.en.bin",
        _ => "ggml-small.en.bin"
    };

    private static string ModelUrl(ModelChoice choice) =>
        $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{ModelFileName(choice)}";

    public async Task LoadAsync(ModelChoice choice)
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
            string modelPath = Path.Combine(ModelsDirectory, ModelFileName(choice));

            if (!File.Exists(modelPath))
            {
                await DownloadModelAsync(choice, modelPath);
            }

            Status?.Invoke("Loading model…");
            _factory = WhisperFactory.FromPath(modelPath);
            _processor = _factory.CreateBuilder()
                .WithLanguage("en")
                .Build();

            // Warm-up with half a second of silence so the first real
            // dictation doesn't pay initialization costs.
            var warmup = new float[8000];
            await foreach (var _ in _processor.ProcessAsync(warmup)) { }

            IsReady = true;
            Status?.Invoke("Ready");
        }
        catch (Exception ex)
        {
            Status?.Invoke($"Model error: {ex.Message}");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task DownloadModelAsync(ModelChoice choice, string destination)
    {
        Status?.Invoke("Downloading model… 0%");
        using var http = new HttpClient();
        using var response = await http.GetAsync(ModelUrl(choice), HttpCompletionOption.ResponseHeadersRead);
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
    }

    /// <summary>Transcribes samples to raw text. Returns "" for very short takes.</summary>
    public async Task<string> TranscribeAsync(float[] samples)
    {
        if (!IsReady || _processor == null)
            throw new InvalidOperationException("Model not loaded yet — check the tray icon for status.");
        if (samples.Length < 4800) // under 0.3 s
            return string.Empty;

        await _gate.WaitAsync();
        try
        {
            var sb = new StringBuilder();
            await foreach (var segment in _processor.ProcessAsync(samples))
            {
                sb.Append(segment.Text);
            }
            return StripArtifacts(sb.ToString());
        }
        finally
        {
            _gate.Release();
        }
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
