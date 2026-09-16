# VoxFlow

Free, fully-local voice dictation for **macOS** and **Windows** — a Wispr
Flow–style workflow with zero ongoing cost. Hold a hotkey, speak, release;
your words are transcribed on-device, cleaned up, and typed into whatever app
has focus. Audio never leaves your machine and there are no API fees.

## Download & run

**Windows (ready-to-run):** grab `VoxFlow-Windows.zip` from the
[latest release](../../releases/latest), extract it, and run `VoxFlow.exe`.
On first launch it registers itself to start with Windows and lives silently
in the system tray — you never have to launch it again. Hold **Right Ctrl** to
dictate. First run downloads a ~470 MB Whisper model (progress in the tray).

**macOS (one command, builds from source):** open Terminal and paste:

```bash
xcode-select --install 2>/dev/null; git clone https://github.com/kfancy420/voxflow.git && cd voxflow/macos && bash scripts/install.sh
```

That installs Apple's command-line tools if they're missing (a dialog appears —
click *Install*, wait for it to finish, then run the line again), downloads
this repo, builds `VoxFlow.app`, puts it in `/Applications` and launches it.
The first build takes a couple of minutes (it fetches WhisperKit); no password
is needed. Prefer not to use git? Click the green **Code** button above →
**Download ZIP**, unzip it, then run
`bash ~/Downloads/voxflow-main/macos/scripts/install.sh` — the command-line
tools are still required to build.

Requires an Apple Silicon Mac on macOS 14+ (macOS 26 for the on-device AI
cleanup pass). When asked, grant **Microphone** and **Accessibility**; the app
picks the grants up within a few seconds, no restart. Hold **Right ⌘** to
dictate. First run downloads a ~500 MB Whisper model (progress in the menu-bar
dropdown). It registers itself to launch at login (and to relaunch after a
crash) and lives in the menu bar — you never have to launch it again.

To update later: `cd voxflow && git pull && bash macos/scripts/install.sh`.
See [`macos/README.md`](macos/README.md) for permissions, usage and
troubleshooting.

## How it works

Both versions share the same pipeline: global hotkey (hold-to-talk) → mic
capture at 16 kHz → take vaulted to disk → on-device Whisper transcription
(silence guard, watchdog, retry on engine fault) → personal-dictionary
substitutions → cleanup (filler/punctuation, sentence-break inference for fast
speech, spoken "new line"/"new paragraph" commands) → clipboard-preserving
paste into the focused app → history log (24-hour expiry).

The punctuation layers (`PunctuationSanity`, `RunOnSplitter`, the segment
joiner) are deliberately the same rules in C# and Swift; tune them together.

- **macOS** — Swift / AppKit / SwiftUI, [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (CoreML, Neural Engine / Metal). Optional AI polish via Apple's on-device
  FoundationModels on macOS 26. Source in [`macos/`](macos/).
- **Windows** — C# / .NET 8 / WinForms, [Whisper.net](https://github.com/sandrohanea/whisper.net)
  (whisper.cpp). Self-contained single-file exe, no .NET install required.
  Source in [`windows/`](windows/).

## Features

Hold-to-talk global hotkey · on-device transcription (no cloud) · filler-word
and punctuation cleanup · spoken line-break commands · personal dictionary ·
dictation history (expires after 24 h) · recording HUD · menu-bar / system-tray
native · launch at login / start with Windows, relaunch after crash ·
clipboard-safe insertion (text, images, files) · never loses a take (vault +
recovery) · file log and headless self-tests.

VoxFlow is an original implementation inspired by the Wispr Flow workflow; it
shares no code or assets with Wispr.

## Build (Windows, from source)

```bash
cd windows/VoxFlow
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -o publish
```
Output: `publish/VoxFlow.exe` plus a small `publish/runtimes/win-x64/` folder.

**Install the whole `publish` folder, not just the .exe.** Whisper.net loads its
native libraries from `<folder>\runtimes\win-x64\`, so `VoxFlow.exe` on its own
cannot transcribe. Do *not* pass
`-p:IncludeNativeLibrariesForSelfExtract=true`: it unpacks those libraries into
a temp directory the loader never searches, and every model load then fails with
`Native Library not found in default paths.` The project file guards against
this, and the build will stop if the flag is set.

### Performance

VoxFlow prefers the **Vulkan** GPU backend and falls back to CPU automatically;
the tray status line and the log both name the backend actually in use.

Measured on an RTX 5080 / i9-13900K with `small.en`:

| Audio length | CPU (4 threads, stock) | CPU (16 threads) | Vulkan |
|---|---|---|---|
| 2.3 s  | 2610 ms | 1550 ms | **132 ms** |
| 5.8 s  | 2650 ms | —       | **158 ms** |
| 19.3 s | 3030 ms | —       | **282 ms** |

Two things dominate CPU-side latency. whisper.cpp pads every clip to a fixed
30-second window, so a two-word utterance costs about as much as a paragraph;
and it defaults to `min(4, cores)` threads, which badly under-uses a modern
desktop CPU (VoxFlow now requests half the logical processors). Reducing
`WithAudioContextSize` cuts the padding cost on CPU, but it is deliberately
*not* used: on the GPU it made long clips slower and measurably less accurate.

`Whisper.net.Runtime.Cuda` is intentionally not referenced — its 1.7.4 build
fails to load on Blackwell (RTX 50-series) with "Cannot load the library on
this platform". Vulkan is faster to load and has no such restriction.

### Choosing a model

Word error rate over a 10-clip dictation set (developer and business
vocabulary, two synthetic voices), clean and mixed with gaussian noise at
10 dB SNR, all on Vulkan:

| Model | Size | WER clean | WER noisy | median ms |
|---|---|---|---|---|
| base.en             | 141 MB | 15.1% | 17.6% | 93 |
| small.en            | 465 MB | 15.1% | 13.4% | 139 |
| **medium.en**       | 1.46 GB | **12.6%** | 14.3% | 247 |
| large-v3-turbo-q5_0 | 547 MB | 13.4% | 13.4% | 193 |
| large-v3-turbo      | 1.55 GB | 13.4% | 13.4% | 234 |

Read these deltas with care. Much of the residual WER is *not* error: the
reference says "ninety minute" and "seventeen percent" while every model
writes "90 minute" and "17%", which is what you actually want from dictation.
The set is small (~120 words) and synthesized, so differences of one or two
points are inside the noise floor.

What does survive scrutiny:

- **base.en is genuinely worse** — it was alone in producing real garbage
  ("dearthearance" for "dereference", "500080" for "5080", "an old check"
  for "a null check"). It is a fallback, not a daily driver.
- **medium.en is the best English model here.** On the clip with the densest
  technical vocabulary it made 3 errors where small.en made 6, and it was the
  only model to get "dereference" right.
- **large-v3-turbo is not worth its size for English.** It scored no better
  than medium.en while being multilingual and larger; the q5_0 quantisation
  is free — identical WER, a third of the size, and faster. Only the
  quantised build is offered, for non-English dictation.

Default is `medium.en` on Windows; switch from the tray menu, which marks which
models are already on disk and downloads on demand.

The macOS build offers the same four choices (WhisperKit CoreML builds) but
defaults to `small.en`: without a discrete GPU the extra accuracy of
`medium.en` costs a few times the latency per take on Apple Silicon, which is
very noticeable in a hold-and-release workflow. Pick Medium from the menu if
accuracy on technical vocabulary matters more to you than the wait.

### History retention

Every dictation is written to `%APPDATA%\VoxFlow\history.json` (Windows) or
`~/Library/Application Support/VoxFlow/history.json` (macOS) in plaintext. It
**expires after 24 hours** by default on both platforms, on top of the existing
200-entry cap.

Expiry is event-driven: it runs at startup, on every new dictation, and when
History is opened from the tray. There is no background sweep, so on a machine
left running and unused an expired entry stays on disk until the next of those
happens — in practice, until you next dictate or restart.

Change it with `HistoryRetentionHours` in `%APPDATA%\VoxFlow\settings.json`
on Windows, or Settings → General → "Keep dictations for" on macOS; `0`
disables time-based expiry and leaves only the count cap. **Clear History
Now** in the tray / menu-bar menu deletes everything immediately.

### Troubleshooting

VoxFlow writes a log to `%APPDATA%\VoxFlow\voxflow.log` (Windows) or
`~/Library/Application Support/VoxFlow/voxflow.log` (macOS), also reachable via
**Open Log…** in the tray / menu-bar menu. It records hook installation, model
loading, each recording, transcription timings and insertion results.

Headless checks, useful when the hotkey or audio seems dead:

```bat
VoxFlow.exe --selftest-wav  C:\path\to\speech.wav   :: model + transcription + cleanup
VoxFlow.exe --selftest-mic  5                       :: capture device, level, transcript
VoxFlow.exe --selftest-insert "hello world"         :: paste into the focused window
VoxFlow.exe --selftest-clean transcript.txt         :: cleanup pipeline on a raw transcript
```
```bash
/Applications/VoxFlow.app/Contents/MacOS/VoxFlow --selftest-wav   speech.wav
/Applications/VoxFlow.app/Contents/MacOS/VoxFlow --selftest-clean transcript.txt
```
Results are written to `%APPDATA%\VoxFlow\selftest.txt` /
`~/Library/Application Support/VoxFlow/selftest.txt`.

### Crash and hang recovery

The take being transcribed is always on disk first (`pending-take.wav`). An
engine that returns nothing is rebuilt and the same audio retried; an engine
that never returns trips a watchdog and the app restarts itself. Whatever was
pending is transcribed on the next launch **into History only** — never onto
the clipboard or into whatever window happens to be focused. Windows relaunches
after any crash via `RegisterApplicationRestart`; macOS via a bundled
LaunchAgent (`KeepAlive` on unsuccessful exit) registered with `SMAppService`.
