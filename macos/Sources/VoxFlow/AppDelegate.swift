import AppKit
import ApplicationServices
import AVFoundation
import os

/// Owns the dictation pipeline:
/// hotkey press → record → (release) → transcribe → dictionary → clean → insert → history.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.voxflow.app", category: "AppDelegate")

    private var statusBar: StatusBarController!
    private let hud = HUDController()
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleaner = TextCleaner()
    private let inserter = TextInserter()

    private var state: FlowState = .idle
    private var recordingStart: Date?
    /// Timestamp of the last real user keystroke/click; used to decide when
    /// background-polish replacement is no longer safe.
    private var lastUserActivity = Date.distantPast
    /// Increments on every new dictation so a stale background polish never
    /// replaces text from a later dictation.
    private var dictationCounter = 0
    private var currentModelChoice: WhisperModelChoice?
    private var modelLoadTask: Task<Void, Never>?
    private var hotkeyRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        promptForAccessibilityIfNeeded()
        // Surface the mic permission dialog at launch rather than mid-dictation.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Logger(subsystem: "com.voxflow.app", category: "AppDelegate")
                    .notice("Microphone permission granted: \(granted)")
            }
        }
        startHotkey()
        loadModel(Preferences.shared.modelChoice)
        cleaner.prewarmAI()

        NotificationCenter.default.addObserver(
            forName: .voxFlowPrefsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prefsChanged()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
    }

    // MARK: - Permissions & hotkey

    private func promptForAccessibilityIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.notice("Accessibility trusted: \(trusted, privacy: .public)")
    }

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onUserActivity = { [weak self] in self?.lastUserActivity = Date() }
        if hotkey.start() {
            hotkeyRetryTimer?.invalidate()
            hotkeyRetryTimer = nil
            log.info("Hotkey monitor running.")
        } else {
            log.error("Could not create event tap — waiting for permissions.")
            statusBar.update(modelState: "Grant Accessibility permission, then VoxFlow will activate.")
            // Retry until the user grants Accessibility / Input Monitoring.
            if hotkeyRetryTimer == nil {
                hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.startHotkey()
                    }
                }
            }
        }
    }

    // MARK: - Model lifecycle

    private func loadModel(_ choice: WhisperModelChoice) {
        currentModelChoice = choice
        modelLoadTask?.cancel()
        modelLoadTask = Task { [weak self] in
            guard let self else { return }
            // Poll the actor's state for progress while loading.
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let s = await self.transcriber.state
                    await MainActor.run { self.reflectModelState(s) }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            await self.transcriber.loadModel(choice)
            poller.cancel()
            let s = await self.transcriber.state
            await MainActor.run { self.reflectModelState(s) }
        }
    }

    private func reflectModelState(_ s: Transcriber.State) {
        switch s {
        case .unloaded:
            setModelStatus("Model not loaded")
        case .loading(let progress):
            let pct = Int(progress * 100)
            setModelStatus(pct > 0 && pct < 100 ? "Downloading model… \(pct)%" : "Loading model…")
        case .ready:
            setModelStatus("")
        case .failed(let message):
            setModelStatus("Model error: \(message)")
        }
    }

    private func setModelStatus(_ text: String) {
        statusBar.update(modelState: text)
        WindowManager.shared.setModelStatus(text.isEmpty ? "Model ready" : text)
    }

    private func prefsChanged() {
        let choice = Preferences.shared.modelChoice
        if choice != currentModelChoice {
            loadModel(choice)
        }
    }

    // MARK: - Dictation pipeline

    private func setState(_ new: FlowState) {
        state = new
        statusBar.update(state: new)
        hud.update(state: new)
        NotificationCenter.default.post(
            name: .voxFlowStateChanged, object: nil,
            userInfo: ["state": StateBox(new)]
        )
    }

    private func hotkeyPressed() {
        guard case .idle = state else { return }
        dictationCounter += 1
        do {
            try recorder.startRecording()
            recordingStart = Date()
            setState(.recording)
            hud.show()
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription)")
            showTransientError("Mic unavailable: \(error.localizedDescription)")
        }
    }

    private func hotkeyReleased() {
        guard case .recording = state else { return }
        let samples = recorder.stopRecording()
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil
        let bundleID = TextInserter.frontmostAppBundleID()

        // Too-short press: cancel silently (SPEC: < 0.15 s).
        if duration < 0.15 || samples.count < 2400 {
            setState(.idle)
            hud.hide()
            return
        }

        setState(.transcribing)
        let thisDictation = dictationCounter
        Task { [weak self] in
            guard let self else { return }
            do {
                let tStart = Date()
                let raw = try await self.transcriber.transcribe(samples)
                let msTranscribe = Int(Date().timeIntervalSince(tStart) * 1000)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    await MainActor.run {
                        self.setState(.idle)
                        self.hud.hide()
                    }
                    return
                }
                let withDictionary = PersonalDictionary.shared.apply(to: trimmed)
                let mode = Preferences.shared.cleanupMode

                // FAST PATH: rules-clean and insert immediately. The AI polish
                // (if enabled) runs afterwards in the background and replaces
                // the text in place only when it is provably safe to do so.
                let fastCleaned = (mode == .off) ? withDictionary : TextCleaner.applyRules(withDictionary)
                let entryID = UUID()
                let insertedString: String = await MainActor.run {
                    self.setState(.inserting)
                    let inserted = self.inserter.insert(fastCleaned)
                    HistoryStore.shared.add(HistoryEntry(
                        id: entryID,
                        rawText: trimmed,
                        cleanedText: fastCleaned,
                        appBundleID: bundleID,
                        durationSeconds: duration
                    ))
                    self.setState(.idle)
                    self.hud.hide()
                    return inserted
                }
                self.log.notice("pipeline timing: transcribe=\(msTranscribe, privacy: .public)ms to-insert=\(Int(Date().timeIntervalSince(tStart) * 1000), privacy: .public)ms audio=\(samples.count / 16000, privacy: .public)s")

                // BACKGROUND POLISH
                let wordCount = fastCleaned.split(whereSeparator: { $0.isWhitespace }).count
                guard mode == .ai, wordCount > 4 else { return }
                let insertedAt = Date()
                let tPolish = Date()
                let polished = await self.cleaner.clean(withDictionary, appBundleID: bundleID, mode: .ai)
                let msPolish = Int(Date().timeIntervalSince(tPolish) * 1000)
                guard !polished.isEmpty, polished != fastCleaned else {
                    self.log.notice("background polish (\(msPolish, privacy: .public)ms): no changes")
                    return
                }
                await MainActor.run {
                    // Replace only when provably safe:
                    guard case .idle = self.state,                                  // not mid-dictation
                          self.dictationCounter == thisDictation,                   // no newer dictation
                          self.lastUserActivity < insertedAt,                       // user hasn't typed/clicked
                          TextInserter.frontmostAppBundleID() == bundleID,          // same target app
                          insertedString.count <= 400 else {                        // reasonable selection walk
                        self.log.notice("background polish (\(msPolish, privacy: .public)ms): skipped, unsafe to replace")
                        return
                    }
                    var finalPolished = polished
                    if insertedString.hasSuffix(" ") { finalPolished += " " }
                    self.inserter.replaceLast(insertedString.count, with: finalPolished)
                    HistoryStore.shared.updateCleanedText(id: entryID, to: polished)
                    self.log.notice("background polish (\(msPolish, privacy: .public)ms): applied in place")
                }
            } catch {
                self.log.error("Pipeline failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.showTransientError(error.localizedDescription)
                }
            }
        }
    }

    private func showTransientError(_ message: String) {
        setState(.error(message))
        hud.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .error = self.state {
                    self.setState(.idle)
                    self.hud.hide()
                }
            }
        }
    }
}
