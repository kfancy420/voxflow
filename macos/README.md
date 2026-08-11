# VoxFlow

Native macOS voice dictation, Wispr Flow–style, with zero ongoing costs.
Hold **Right ⌘** anywhere, speak, release — your words are transcribed,
cleaned up, and typed into whatever app has focus. Everything runs
on-device: audio never leaves your Mac and there are no API fees.

## Features

- **Hold-to-talk global hotkey** — Right ⌘, works in every app, never
  conflicts with normal shortcuts (⌘C etc. are ignored).
- **On-device Whisper transcription** via WhisperKit (CoreML, Neural
  Engine / Metal accelerated). Choice of Base / Small / Large-v3-Turbo
  models in Settings.
- **AI cleanup pass** using Apple's on-device Foundation model
  (macOS 26 + Apple Intelligence): removes filler words and false
  starts, fixes grammar and punctuation, adapts tone to the target app
  (complete sentences in Mail, casual in Slack/Messages, no trailing
  period in code editors). Falls back to fast rule-based cleanup if
  Apple Intelligence is off — switchable per-mode from the menu bar.
- **Spoken commands** — "new line", "new paragraph".
- **Personal dictionary** — your own trigger → replacement rules so
  names, brands, and jargon come out right every time.
- **History window** — last 200 dictations with raw + cleaned text and
  one-click copy.
- **Recording HUD** — floating waveform pill while you speak; never
  steals focus from the app you're dictating into.
- **Menu-bar native** — no Dock icon, launch-at-login toggle, model
  download progress, permission status indicators.
- **Clipboard-safe insertion** — pastes via a synthesized ⌘V and then
  restores whatever was on your clipboard.

## Install

```bash
cd voxflow
bash scripts/install.sh
```

Requires: Apple Silicon Mac, macOS 14+ (macOS 26 for AI cleanup),
Xcode Command Line Tools (`xcode-select --install`).

The script builds a release binary with SwiftPM, assembles
`VoxFlow.app`, ad-hoc signs it, installs it to `/Applications`, and
launches it. First launch downloads the Whisper model (~500 MB for the
default Small model).

### Permissions (one-time)

| Permission | Why | Where |
|---|---|---|
| Microphone | recording your voice | prompted automatically |
| Accessibility | global hotkey + text insertion | System Settings → Privacy & Security → Accessibility |
| Input Monitoring | only if the hotkey stays dead after Accessibility | System Settings → Privacy & Security → Input Monitoring |

VoxFlow detects newly-granted permissions within a few seconds — no
restart needed. Settings → General shows live status for each.

## Usage

Hold **Right ⌘** → speak → release. That's it.

Menu bar mic icon → Cleanup mode (Off / Rules / AI polish), model
picker, History, Settings, Launch at Login.

Tips: dictate punctuation naturally — the cleanup pass handles it. Add
your product names and personal jargon to the Dictionary tab. If a
dictation goes to the wrong app, click into the right text field first
— insertion targets the focused app.

## Troubleshooting

- **Hotkey does nothing** — grant Accessibility (and Input Monitoring
  if needed) to *VoxFlow* specifically; if you rebuilt the app, remove
  the old entry and re-add (ad-hoc signatures change per build).
- **"Model error" in the menu** — check disk space and network, then
  pick the model again in Settings → Model to retry the download.
- **AI polish greyed out / falling back** — Apple Intelligence must be
  enabled in System Settings on macOS 26+. Rules mode works everywhere.
- **Rebuild after editing code** — `bash scripts/install.sh` again.

## Architecture

Single SwiftPM executable target. `Sources/VoxFlow/`:

- `Core/` — `HotkeyMonitor` (CGEvent tap, right-⌘ keycode 54),
  `AudioRecorder` (AVAudioEngine → 16 kHz mono Float32),
  `TextInserter` (clipboard-preserving synthesized ⌘V).
- `Intelligence/` — `Transcriber` (WhisperKit actor),
  `TextCleaner` (rules pipeline + FoundationModels polish),
  `PersonalDictionary`, `HistoryStore` (JSON in Application Support).
- `UI/` — `StatusBarController`, `HUDController` (non-activating
  NSPanel), `SettingsWindow` + `HistoryWindow` (SwiftUI).
- `Support/` — `Contracts` (shared types), `Preferences`.
- `AppDelegate` — owns the pipeline: press → record → release →
  transcribe → dictionary → clean → insert → history.

VoxFlow is an original implementation inspired by the Wispr Flow
workflow; it shares no code or assets with Wispr.
