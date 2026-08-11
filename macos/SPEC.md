# VoxFlow — Architecture Spec (FROZEN INTERFACES)

VoxFlow is a native macOS menu-bar dictation app (a Wispr Flow–style workflow):
hold **Right ⌘** anywhere → speak → release → transcribed, cleaned text is
inserted into whatever app has focus.

Target: Apple Silicon, macOS 14+ (FoundationModels cleanup requires macOS 26,
guarded with availability checks). Built with SwiftPM (swift-tools-version 5.10,
Swift 5 language mode — do NOT require Swift 6 strict concurrency). No Xcode
project; an app bundle is assembled by `scripts/make_app.sh`.

Dependency: `WhisperKit` product from `argmax-oss-swift` **v1.x**
(https://github.com/argmaxinc/argmax-oss-swift). NOTE v1.0 breaking changes:
`transcribe` returns `[TranscriptionResult]` (array), CLI renamed. Verify usage
against v1.x docs at https://swiftpackageindex.com/argmaxinc/WhisperKit/main/documentation/whisperkit

Shared types live in `Sources/VoxFlow/Support/Contracts.swift` (FlowState,
CleanupMode, HistoryEntry, DictionaryEntry, WhisperModelChoice, notification
names, StateBox). Never redefine them.

Pipeline (owned by AppDelegate):
hotkey press → AudioRecorder.start + HUD show → hotkey release →
AudioRecorder.stop → Transcriber.transcribe → PersonalDictionary.apply →
TextCleaner.clean → TextInserter.insert → HistoryStore.add → idle.

## Module contracts — public API must match EXACTLY

### Core/HotkeyMonitor.swift
```swift
@MainActor final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Starts a CGEvent tap listening for flagsChanged on the RIGHT command key
    /// (keycode 54). Hold = press, release = release. Must auto-re-enable the
    /// tap on kCGEventTapDisabledByTimeout. Returns false if the tap could not
    /// be created (missing Accessibility/Input Monitoring permission).
    @discardableResult func start() -> Bool
    func stop()
}
```
Implementation notes: use `CGEvent.tapCreate` with `.listenOnly` option on
`flagsChanged`; distinguish right-⌘ via keycode 54 in the event's
`.keyboardEventKeycode` field. Ignore presses when other modifier keys are also
held (so ⌘C etc. never trigger). Debounce: a press shorter than 0.15 s that
produced no audio should cancel silently.

### Core/AudioRecorder.swift
```swift
final class AudioRecorder {
    /// Requests mic permission if needed. Throws descriptive errors.
    func startRecording() throws
    /// Stops and returns mono 16 kHz Float32 samples of the whole take.
    func stopRecording() -> [Float]
    var isRecording: Bool { get }
}
```
Implementation notes: AVAudioEngine input node tap; convert from the hardware
format to 16 kHz mono Float32 with AVAudioConverter; accumulate in memory.
Post `.voxFlowAudioLevel` notifications (~30 Hz) with userInfo["level"] Float
0–1 (RMS-based) for the HUD waveform. Play subtle start/stop feedback sounds
using NSSound (system sounds like "Pop"/"Bottle"), respecting a
`Preferences.shared.playSounds` flag.

### Core/TextInserter.swift
```swift
@MainActor final class TextInserter {
    /// Inserts text at the cursor of the frontmost app: saves the pasteboard,
    /// sets the text, synthesizes ⌘V via CGEvent, then restores the previous
    /// pasteboard contents after ~0.6 s.
    func insert(_ text: String)
    /// Bundle ID of the frontmost app (for app-aware cleanup + history).
    static func frontmostAppBundleID() -> String?
}
```

### Intelligence/Transcriber.swift
```swift
actor Transcriber {
    enum State { case unloaded, loading(progress: Double), ready, failed(String) }
    private(set) var state: State
    /// Loads/downloads the WhisperKit model named by WhisperModelChoice.rawValue.
    func loadModel(_ choice: WhisperModelChoice) async
    /// Transcribes 16 kHz mono samples to raw text. Throws if not ready.
    func transcribe(_ samples: [Float]) async throws -> String
}
```
Use WhisperKit v1.x: init with a config selecting the model by name; models are
auto-downloaded to Application Support on first use. Join segment texts, trim
Whisper artifacts like "[BLANK_AUDIO]", "(silence)". Skip transcription if
samples represent under 0.3 s of audio (return "").

### Intelligence/TextCleaner.swift
```swift
final class TextCleaner {
    /// Cleans per mode. `appBundleID` lets `ai` mode adapt tone (e.g. Mail →
    /// complete sentences; Slack/Messages → casual). Never throws — on any AI
    /// failure fall back to rules output. Preserve meaning; never add content.
    func clean(_ raw: String, appBundleID: String?, mode: CleanupMode) async -> String
}
```
`rules`: strip fillers (um, uh, uhh, er, like when sentence-initial disfluency,
you know as interjection — be conservative), collapse repeated words ("the the"),
fix spacing before punctuation, capitalize sentence starts, ensure final period
for multi-word outputs. Also handle spoken commands: "new line"/"new paragraph"
→ line breaks (only when they appear as standalone phrases).
`ai`: `#if canImport(FoundationModels)` + `if #available(macOS 26.0, *)`; use
SystemLanguageModel availability check, LanguageModelSession with strict
instructions (fix grammar/punctuation, remove fillers and false starts, keep
wording and meaning, output ONLY the cleaned text). Timeout 10 s → fall back
to rules. Always run rules first, then AI on the rules output.

### Intelligence/PersonalDictionary.swift
```swift
final class PersonalDictionary {
    static let shared = PersonalDictionary()
    private(set) var entries: [DictionaryEntry] { get }
    func add(_ e: DictionaryEntry); func update(_ e: DictionaryEntry)
    func remove(id: UUID)
    /// Whole-word replacements, longest trigger first.
    func apply(to text: String) -> String
}
```
Persist as JSON at `~/Library/Application Support/VoxFlow/dictionary.json`.
Post `.voxFlowPrefsChanged` on mutation.

### Intelligence/HistoryStore.swift
```swift
final class HistoryStore {
    static let shared = HistoryStore()
    private(set) var entries: [HistoryEntry] { get }  // newest first, cap 200
    func add(_ e: HistoryEntry)
    func clear()
}
```
Persist as JSON at `~/Library/Application Support/VoxFlow/history.json`.

### Support/Preferences.swift
```swift
final class Preferences {
    static let shared = Preferences()
    var cleanupMode: CleanupMode          // default .ai
    var modelChoice: WhisperModelChoice   // default .smallEn
    var playSounds: Bool                  // default true
    var launchAtLogin: Bool               // SMAppService.mainApp backed
    var insertTrailingSpace: Bool         // default true
}
```
UserDefaults-backed; `launchAtLogin` setter registers/unregisters
`SMAppService.mainApp` (import ServiceManagement) and reads status from it.
Post `.voxFlowPrefsChanged` on any change.

### UI/StatusBarController.swift
```swift
@MainActor final class StatusBarController: NSObject {
    /// Menu: state line, cleanup-mode picker, model picker (with download
    /// state), History window, Settings window, Launch at Login toggle, Quit.
    override init()
    func update(state: FlowState)
    func update(modelState: String)  // e.g. "Downloading model… 43%"
}
```
Menu-bar icon: SF Symbol microphone that changes for idle/recording/working
(use NSImage(systemSymbolName:accessibilityDescription:)). Observes
`.voxFlowStateChanged`.

### UI/HUDController.swift
```swift
@MainActor final class HUDController {
    func show()   // small floating always-on-top pill near bottom-center
    func update(state: FlowState)
    func hide()
}
```
Borderless non-activating NSPanel (`.nonactivatingPanel`), level `.statusBar`,
ignores mouse. Shows a live waveform (observe `.voxFlowAudioLevel`) while
recording, then "Transcribing…" / "Polishing…" text. Never steals focus —
critical, since insertion targets the focused app.

### UI/SettingsWindow.swift  +  UI/HistoryWindow.swift
SwiftUI views hosted in NSWindow via NSHostingController (create lazily,
`isReleasedWhenClosed = false`). Settings tabs: General (cleanup mode, sounds,
trailing space, launch at login, permissions status + "Open System Settings"
buttons), Model (WhisperModelChoice picker + download progress), Dictionary
(editable table: add/edit/delete DictionaryEntry rows). History window: list of
HistoryEntry with relative date, app name, cleaned text, click-to-copy button.
Expose:
```swift
@MainActor final class WindowManager {
    static let shared = WindowManager()
    func showSettings()
    func showHistory()
}
```

### App wiring (AppDelegate.swift + main.swift) — written by integrator, not agents.

## Style rules for ALL files
- Swift 5 mode. Every AppKit/SwiftUI touch on the main thread (@MainActor or DispatchQueue.main).
- No third-party deps beyond WhisperKit. No force-unwraps of optionals that can be nil at runtime.
- Log via `os.Logger(subsystem: "com.voxflow.app", category: <module>)`.
- Each file compiles standalone against Contracts.swift — no cross-module private access.
