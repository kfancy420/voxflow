using System;
using System.IO;
using NAudio.Wave;

namespace VoxFlow;

/// <summary>
/// Keeps the audio of the take currently being transcribed on disk, so that
/// an engine fault — even one that forces a process restart — never costs the
/// user what they just said. Cleared once the text has been delivered.
/// </summary>
public static class TakeVault
{
    public static string Path =>
        System.IO.Path.Combine(Settings.AppDataDirectory(), "pending-take.wav");

    public static void Save(float[] samples)
    {
        try
        {
            Directory.CreateDirectory(Settings.AppDataDirectory());
            using var writer = new WaveFileWriter(Path, new WaveFormat(16000, 16, 1));
            var pcm = new byte[samples.Length * 2];
            for (int i = 0; i < samples.Length; i++)
            {
                short s = (short)Math.Clamp(samples[i] * 32767f, short.MinValue, short.MaxValue);
                pcm[i * 2] = (byte)(s & 0xFF);
                pcm[i * 2 + 1] = (byte)(s >> 8);
            }
            writer.Write(pcm, 0, pcm.Length);
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not save pending take: {ex.Message}");
        }
    }

    public static bool HasPending => File.Exists(Path);

    public static float[]? Load()
    {
        try
        {
            if (!File.Exists(Path)) return null;
            using var reader = new WaveFileReader(Path);
            var provider = reader.ToSampleProvider();
            var buffer = new float[reader.SampleCount];
            int total = 0, read;
            while ((read = provider.Read(buffer, total, buffer.Length - total)) > 0) total += read;
            Array.Resize(ref buffer, total);
            return buffer;
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not load pending take: {ex.Message}");
            return null;
        }
    }

    public static void Clear()
    {
        try { File.Delete(Path); }
        catch (Exception ex) { Log.Warn($"Could not clear pending take: {ex.Message}"); }
    }
}
