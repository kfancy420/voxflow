# VoxFlow

Native macOS voice dictation, Wispr Flow–style, with zero ongoing costs.
Hold **Right ⌘** anywhere, speak, release — your words are transcribed,
cleaned up, and typed into whatever app has focus. Everything runs
on-device: audio never leaves your Mac and there are no API fees.

## Features

- **Hold-to-talk global hotkey** — Right ⌘, works in every app, never
  conflicts with normal shortcuts (⌘C etc. are ignored).
- **On-device Whisper transcription** via WhisperKit (CoreML, Metal
  accelerated). Choice of Base / Small / Medium / Large-v3-Turbo models
  in Settings; the menu marks which are already downloaded.
- **Punctuation that survives fast speech** — sentence breaks are
  restored at Whisper's segment boundaries, breathless run-ons are split
  at spoken sentence openers, and a grammar-aware sanity pass removes
  the breaks that cannot be right ("…the. The goal…"). Single-pass
  decoding (no temperature fallback) keeps latency predictable.
- **Silence guard** — quiet takes are rejected and Whisper's
  silence hallucinations ("Thank you.", "Thanks for watching!") never
  reach your document.
- **Never loses a dictation** — every take is vaulted to disk before
  transcription. If the speech engine dies it is rebuilt and the same
  audio retried; if it hangs, VoxFlow restarts itself and the take is
  transcribed into History (never pasted anywhere) on the next launch.
  Crashes relaunch automatically via launchd.
- **AI cleanup pass** using Apple's on-device Foundation model
  (macOS 26 + Apple Intelligence): removes filler words and false
  starts, fixes grammar and punctuation, adapts tone to the target app
  (complete sentences in Mail, casual in Slack/Messages, no trailing
  period in code editors). Falls back to fast rule-based cleanup if
  Apple Intelligence is off — switchable per-mode from the menu bar.
- **Spoken commands** — "new line", "new paragraph".
- **Personal dictionary** — your own trigger → replacement rules so
  names, brands, and jargon come out right every time.
- **History window** — recent dictations with raw + cleaned text and
  one-click copy. Entries **expire after 24 hours** by default (configurable
  in Settings → General; 200-entry cap on top) because everything you
  dictate sits there in plain text.
- **Recording HUD** — floating waveform pill on the screen you're working
  on; never steals focus from the app you're dictating into.
- **Menu-bar native** — no Dock icon, launch-at-login (enabled on first
  run), model download progress, permission status indicators, and
  maintenance actions: Restart Speech Engine, Recover Last Take, Restart
  Hotkey Monitor, Clear History Now, Open Log.
- **Clipboard-safe insertion** — pastes via a synthesized ⌘V and then
  restores whatever was on your clipboard, images and files included.

## Install

From a fresh Mac, in Terminal:

```bash
xcode-select --install 2>/dev/null; git clone https://github.com/kfancy420/voxflow.git && cd voxflow/macos && bash scripts/install.sh
```

If the command-line tools weren't installed yet, a dialog appears — click
*Install*, wait for it, then run the line again. Already have the repo?
Just `cd voxflow/macos && bash scripts/install.sh`; to update,
`git pull` first.

Requires: Apple Silicon Mac, macOS 14+ (macOS 26 for AI cleanup),
Xcode Command Line Tools (`xcode-select --install`). No admin password
is needed; nothing is installed outside `/Applications/VoxFlow.app`,
`~/Library/Application Support/VoxFlow` and the model cache in
`~/Documents/huggingface`.

The script builds a release binary with SwiftPM, assembles
`VoxFlow.app` (with its LaunchAgent), signs it, installs it to
`/Applications`, and launches it. First launch downloads the Whisper
model (~500 MB for the default Small model) and registers VoxFlow to
launch at login and relaunch after a crash (System Settings → General →
Login Items → "Allow in the Background").

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
- **Something odd happened** — menu bar → **Open Log…** opens
  `~/Library/Application Support/VoxFlow/voxflow.log`: hotkey and
  permission state, model loads, every recording, transcription timings
  (`LATENCY release→text …`), insertion results, faults and recoveries.
- **Rebuild after editing code** — `bash scripts/install.sh` again.

Headless checks, useful when tuning cleanup rules or when the pipeline
seems dead:

```bash
/Applications/VoxFlow.app/Contents/MacOS/VoxFlow --selftest-clean transcript.txt   # cleanup pipeline only
/Applications/VoxFlow.app/Contents/MacOS/VoxFlow --selftest-wav   speech.wav       # model + transcription + cleanup
```
Results print to the terminal and to `~/Library/Application Support/VoxFlow/selftest.txt`.

## Architecture

Single SwiftPM executable target. `Sources/VoxFlow/`:

- `Core/` — `HotkeyMonitor` (CGEvent tap, right-⌘ keycode 54),
  `AudioRecorder` (AVAudioEngine → 16 kHz mono Float32),
  `TextInserter` (clipboard-preserving synthesized ⌘V).
- `Intelligence/` — `Transcriber` (WhisperKit actor: silence guard,
  segment joiner, watchdog), `TextCleaner` (rules pipeline +
  FoundationModels polish), `PunctuationSanity` + `RunOnSplitter`
  (sentence-break inference, shared rules with Windows),
  `PersonalDictionary`, `HistoryStore` (JSON in Application Support,
  time-based expiry), `TakeVault` (pending take on disk).
- `UI/` — `StatusBarController`, `HUDController` (non-activating
  NSPanel), `SettingsWindow` + `HistoryWindow` (SwiftUI).
- `Support/` — `Contracts` (shared types), `Preferences`, `Log` (file
  log), `ProcessLifecycle` (single instance, self-restart, launchd
  hand-over), `SelfTest`.
- `Resources/com.voxflow.app.plist` — bundled LaunchAgent
  (`SMAppService.agent`): launch at login + relaunch after crash.
- `AppDelegate` — owns the pipeline: press → record → release → vault →
  transcribe (retry on fault) → dictionary → clean → insert → history.

VoxFlow is an original implementation inspired by the Wispr Flow
workflow; it shares no code or assets with Wispr.
