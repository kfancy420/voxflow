using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
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
    private readonly object _deviceLock = new();
    public bool IsRecording { get; private set; }

    private long _startTimestamp;
    private bool _awaitingFirstBuffer;

    public void Start()
    {
        if (IsRecording) return;
        lock (_lock) { _samples.Clear(); }
        _startTimestamp = System.Diagnostics.Stopwatch.GetTimestamp();
        _awaitingFirstBuffer = true;

        _waveIn = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16000, 16, 1),
            BufferMilliseconds = 30
        };
        _waveIn.DataAvailable += OnDataAvailable;
        lock (_deviceLock) { _waveIn.StartRecording(); }
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
            // Never dispose the device while its capture thread may still be
            // returning a buffer to the driver: that is a use-after-free in
            // native code (AccessViolation in waveInAddBuffer) that .NET
            // cannot catch and that killed the whole process on 2026-08-27.
            // StopRecording asks the thread to finish; RecordingStopped fires
            // after its loop has exited, and only then is the device closed.
            // RecordingStopped can fire on the capture thread the instant its
            // loop exits — before StopRecording() below has finished with the
            // handle — so every call into the device is serialised on one
            // lock; winmm faults (AccessViolation in waveInReset) rather than
            // failing cleanly when a handle is closed under it.
            int disposed = 0;
            void DisposeOnce(string how)
            {
                if (Interlocked.Exchange(ref disposed, 1) == 1) return;
                lock (_deviceLock)
                {
                    try { wi.Dispose(); }
                    catch (Exception ex) { Log.Warn($"WaveIn dispose ({how}) failed: {ex.Message}"); }
                }
            }
            wi.RecordingStopped += (_, _) => DisposeOnce("stopped");
            lock (_deviceLock)
            {
                try { wi.StopRecording(); }
                catch (Exception ex) { Log.Warn("StopRecording failed: " + ex.Message); }
            }
            // Safety net if the device never reports stopping (unplugged mid-take).
            _ = Task.Delay(2000).ContinueWith(_ => DisposeOnce("timeout"));
        }

        lock (_lock)
        {
            return _samples.ToArray();
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_awaitingFirstBuffer)
        {
            _awaitingFirstBuffer = false;
            // How much speech would be lost if the user starts talking the
            // instant they press the key.
            Log.Info($"First audio buffer {KeyboardHook.MsSince(_startTimestamp):F1} ms after mic start");
        }
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
