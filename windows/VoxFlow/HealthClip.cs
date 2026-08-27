using System;
using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using NAudio.Wave;

namespace VoxFlow;

/// <summary>
/// A short clip of real speech used to prove the whisper backend is alive
/// *before* a dictation depends on it. Silence is useless for this — a dead
/// GPU context and a healthy engine both return nothing for silence — so the
/// clip is generated once with the Windows speech synthesiser and cached.
/// </summary>
public static class HealthClip
{
    private const string Phrase = "Testing, one, two, three.";
    public static readonly string[] ExpectedWords = { "test", "one", "two", "three" };

    private static float[]? _samples;

    public static string Path =>
        System.IO.Path.Combine(Settings.AppDataDirectory(), "healthcheck.wav");

    /// <summary>16 kHz mono float samples, or null if the clip is unavailable.</summary>
    public static float[]? Samples
    {
        get
        {
            if (_samples != null) return _samples;
            try
            {
                if (!File.Exists(Path)) Generate();
                _samples = Load();
                Log.Info($"Health clip ready: {_samples.Length / 16000.0:F2}s from {Path}");
            }
            catch (Exception ex)
            {
                Log.Error("Health clip unavailable — engine probes will fall back to timing only", ex);
            }
            return _samples;
        }
    }

    private static void Generate()
    {
        Directory.CreateDirectory(Settings.AppDataDirectory());
        using var synth = new SpeechSynthesizer();
        synth.Rate = -1;
        synth.SetOutputToWaveFile(Path,
            new SpeechAudioFormatInfo(16000, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
        synth.Speak(Phrase);
        synth.SetOutputToNull();
        Log.Info($"Generated health clip \"{Phrase}\" at {Path}");
    }

    private static float[] Load()
    {
        using var reader = new WaveFileReader(Path);
        if (reader.WaveFormat.SampleRate != 16000 || reader.WaveFormat.Channels != 1)
            throw new InvalidDataException($"Health clip must be 16 kHz mono, got {reader.WaveFormat}");
        var provider = reader.ToSampleProvider();
        var buffer = new float[reader.SampleCount];
        int total = 0, read;
        while ((read = provider.Read(buffer, total, buffer.Length - total)) > 0) total += read;
        // Whisper needs at least a second of audio to behave; pad with silence.
        int minimum = 16000 * 2;
        if (total < minimum) Array.Resize(ref buffer, minimum);
        else Array.Resize(ref buffer, total);
        return buffer;
    }

    /// <summary>True when the transcript contains any of the phrase's words.</summary>
    public static bool Matches(string transcript)
    {
        string t = transcript.ToLowerInvariant();
        foreach (var w in ExpectedWords)
            if (t.Contains(w, StringComparison.Ordinal)) return true;
        return false;
    }
}
