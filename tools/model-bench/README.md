# model-bench

Measures word error rate and latency for Whisper models and backends, so the
model choice in VoxFlow rests on numbers rather than intuition. This is what
produced the tables in the root README.

## Use

```bat
:: 1. generate a synthetic dictation set (writes clips\ and manifest.tsv)
powershell -ExecutionPolicy Bypass -File make-clips.ps1

:: 2. score every model you have on disk
dotnet run -c Release -- manifest.tsv ^
  "%APPDATA%\VoxFlow\models\ggml-small.en.bin" ^
  "%APPDATA%\VoxFlow\models\ggml-medium.en.bin"
```

Each model is scored on the clean audio and on the same audio mixed with
gaussian noise at 10 dB SNR (fixed seed, so every model meets identical
noise). Clips where a model made errors are printed with its actual output,
because the aggregate number hides which mistakes matter.

## Reading the output honestly

- Reference text is spelled out ("ninety minute", "seventeen percent") while
  models emit "90 minute" and "17%". Those score as errors and are not.
- The set is ~120 words. One or two points of WER is inside the noise floor;
  look at the per-clip error lines to see whether a difference is real.
- The audio is text-to-speech, which is cleaner and more consistent than a
  human at a desk. Expect real-world WER to be higher across the board, and
  expect larger models to help somewhat more than they do here.

## Backends

`RuntimeLibraryOrder` is set to Vulkan then CPU. Note that `WhisperFactory`
caches its native-library resolution in a static `Lazy`, so a failed backend
poisons every later attempt in the same process — test one backend per
process run if you are comparing them.
