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

**macOS (build from source):**
```bash
cd macos
bash scripts/install.sh
```
Requires Apple Silicon, macOS 14+ (macOS 26 for the on-device AI cleanup pass),
and the Xcode Command Line Tools. Grant Accessibility + Microphone when asked.
Hold **Right ⌘** to dictate. Enable "Launch at Login" from the menu-bar icon to
keep it always running.

## How it works

Both versions share the same pipeline: global hotkey (hold-to-talk) → mic
capture at 16 kHz → on-device Whisper transcription → personal-dictionary
substitutions → cleanup (filler/punctuation, spoken "new line"/"new paragraph"
commands) → clipboard-preserving paste into the focused app → history log.

- **macOS** — Swift / AppKit / SwiftUI, [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (CoreML, Neural Engine / Metal). Optional AI polish via Apple's on-device
  FoundationModels on macOS 26. Source in [`macos/`](macos/).
- **Windows** — C# / .NET 8 / WinForms, [Whisper.net](https://github.com/sandrohanea/whisper.net)
  (whisper.cpp). Self-contained single-file exe, no .NET install required.
  Source in [`windows/`](windows/).

## Features

Hold-to-talk global hotkey · on-device transcription (no cloud) · filler-word
and punctuation cleanup · spoken line-break commands · personal dictionary ·
dictation history · recording HUD · menu-bar / system-tray native · launch at
login / start with Windows · clipboard-safe insertion.

VoxFlow is an original implementation inspired by the Wispr Flow workflow; it
shares no code or assets with Wispr.

## Build (Windows, from source)

```bash
cd windows/VoxFlow
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```
Output: `publish/VoxFlow.exe`.
