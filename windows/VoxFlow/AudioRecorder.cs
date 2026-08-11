using System;
using System.Collections.Generic;
using NAudio.Wave;

namespace VoxFlow;

/// <summary>
/// Captures the default microphone at 16 kHz mono and accumulates Float32
/// samples for Whisper. Raises Level (0..1) events for the recording HUD.
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    public event Action<float>? Level;

    private WaveInEvent? _waveIn;
    private readonly List<float> _samples = new();
    private readonly object _lock = new();
    public bool IsRecording { get; private set; }

    public void Start()
    {
        if (IsRecording) return;
        lock (_lock) { _samples.Clear(); }

        _waveIn = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16000, 16, 1),
            BufferMilliseconds = 30
        };
        _waveIn.DataAvailable += OnDataAvailable;
        _waveIn.StartRecording();
        IsRecording = true;
    }

    public float[] Stop()
    {
        if (!IsRecording) return Array.Empty<float>();
        IsRecording = false;

        var wi = _waveIn;
        _waveIn = null;
        if (wi != null)
        {
            wi.DataAvailable -= OnDataAvailable;
            try { wi.StopRecording(); } catch { /* device may be gone */ }
            wi.Dispose();
        }

        lock (_lock)
        {
            return _samples.ToArray();
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        int count = e.BytesRecorded / 2;
        var chunk = new float[count];
        float sumSquares = 0f;
        for (int i = 0; i < count; i++)
        {
            short s = BitConverter.ToInt16(e.Buffer, i * 2);
            float f = s / 32768f;
            chunk[i] = f;
            sumSquares += f * f;
        }
        lock (_lock)
        {
            _samples.AddRange(chunk);
        }
        if (count > 0)
        {
            float rms = (float)Math.Sqrt(sumSquares / count);
            Level?.Invoke(Math.Clamp(rms * 6f, 0f, 1f));
        }
    }

    public void Dispose()
    {
        if (IsRecording) Stop();
    }
}
