import AppKit
import ApplicationServices
import AVFoundation
import os

/// Owns the dictation pipeline:
/// hotkey press → record → (release) → vault → transcribe → dictionary → clean → insert → history.
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
    private var recovering = false
    private var noticeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("=== VoxFlow starting === bundle=\(Bundle.main.bundleURL.path) " +
                 "version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") " +
                 "launchd=\(ProcessLifecycle.isLaunchdManaged) restarted=\(ProcessLifecycle.wasRestartedAfterCrash) " +
                 "macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

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
        applyHistoryRetention()
        ensureAutoStart()
        loadModel(Preferences.shared.modelChoice)
        cleaner.prewarmAI()

        NotificationCenter.default.addObserver(
            forName: .voxFlowPrefsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prefsChanged()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .voxFlowCommand, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let raw = note.userInfo?["command"] as? String,
                      let command = PipelineCommand(rawValue: raw) else { return }
                self?.handle(command: command)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Shutting down")
        hotkey.stop()
    }

    // MARK: - Permissions & hotkey

    private func promptForAccessibilityIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.notice("Accessibility trusted: \(trusted, privacy: .public)")
        Log.info("Accessibility trusted: \(trusted)")
    }

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onUserActivity = { [weak self] in self?.lastUserActivity = Date() }
        if hotkey.start() {
            hotkeyRetryTimer?.invalidate()
            hotkeyRetryTimer = nil
            log.info("Hotkey monitor running.")
            Log.info("Hotkey monitor running")
        } else {
            log.error("Could not create event tap — waiting for permissions.")
            Log.warn("Could not create event tap — waiting for Accessibility permission")
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

    // MARK: - Startup housekeeping

    /// Applies the retention setting and drops anything already expired.
    private func applyHistoryRetention() {
        HistoryStore.shared.retentionHours = Preferences.shared.historyRetentionHours
        Log.info("History retention: \(HistoryStore.shared.retentionDescription)")
        HistoryStore.shared.prune()
    }

    /// First run registers launch-at-login (through the bundled LaunchAgent,
    /// which also relaunches VoxFlow after a crash). Later runs leave the
    /// user's choice alone. Skipped for the bare development binary, which
    /// has no bundle to register.
    private func ensureAutoStart() {
        ProcessLifecycle.retireLegacyLaunchAgent()
        guard ProcessLifecycle.isInstalledBundle else { return }
        let prefs = Preferences.shared
        if !prefs.autoStartConfigured {
            prefs.launchAtLogin = true
            prefs.autoStartConfigured = true
            Log.info("First run: launch at login enabled (agent status: \(Preferences.launchAgentStatus))")
            return
        }
        Log.info("Launch agent status: \(Preferences.launchAgentStatus)")

        // Launched by hand (Finder, install.sh) while the agent is registered:
        // hand over to launchd so this session gets crash recovery too. The
        // managed copy it starts asks this one to quit (ProcessLifecycle).
        if prefs.launchAtLogin, !ProcessLifecycle.isLaunchdManaged, !ProcessLifecycle.wasRestartedAfterCrash {
            ProcessLifecycle.kickstartManagedCopy()
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
            setModelStatus(pct > 0 && pct < 95 ? "Downloading model… \(pct)%" : "Loading model…")
        case .ready:
            setModelStatus(readyStatus())
            // Deliver anything a previous instance had to leave behind.
            if case .idle = state, TakeVault.hasPending {
                recoverPendingTake(reason: "engine ready")
            }
        case .failed(let message):
            setModelStatus("Model error: \(message)")
        }
    }

    private func readyStatus(lastMs: Int? = nil) -> String {
        let model = currentModelChoice?.rawValue ?? Preferences.shared.modelChoice.rawValue
        if let lastMs {
            return "Ready — last: \(lastMs) ms (\(model) on \(transcriber.backend))"
        }
        return "Ready — \(model) on \(transcriber.backend)"
    }

    private func setModelStatus(_ text: String) {
        statusBar.update(modelState: text)
        WindowManager.shared.setModelStatus(text.isEmpty ? "Model ready" : text)
    }

    private func prefsChanged() {
        let choice = Preferences.shared.modelChoice
        if choice != currentModelChoice {
            Log.info("Switching model to \(choice.rawValue)")
            loadModel(choice)
        }
        let retention = Preferences.shared.historyRetentionHours
        if retention != HistoryStore.shared.retentionHours {
            applyHistoryRetention()
        }
    }

    // MARK: - Menu commands

    private func handle(command: PipelineCommand) {
        switch command {
        case .restartEngine:
            if case .idle = state {
                Log.info("Manual speech engine reload")
                guard let choice = currentModelChoice else { return }
                loadModel(choice)
            } else {
                ProcessLifecycle.restartSelf(reason: "manual restart while busy")
            }
        case .recoverLastTake:
            if TakeVault.hasPending {
                recoverPendingTake(reason: "manual")
            } else {
                showNotice("Nothing to recover — the last take was delivered.")
            }
        case .restartHotkey:
            Log.info("Hotkey monitor restart requested")
            hotkey.stop()
            startHotkey()
            showNotice(hotkey.isRunning ? "Hotkey monitor restarted." : "Could not restart the hotkey monitor.")
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
        switch state {
        case .idle, .notice:
            break
        default:
            return
        }
        noticeTimer?.invalidate()
        dictationCounter += 1
        do {
            let t = Date()
            try recorder.startRecording()
            let micMs = Log.ms(since: t)
            recordingStart = Date()
            setState(.recording)
            hud.show()
            Log.info("Recording started (mic open \(micMs) ms)")
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription)")
            Log.error("Microphone start failed: \(error.localizedDescription)")
            showTransientError("Mic unavailable: \(error.localizedDescription)")
        }
    }

    private func hotkeyReleased() {
        guard case .recording = state else { return }
        let released = Date()
        let samples = recorder.stopRecording()
        let stopMs = Log.ms(since: released)
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil
        let bundleID = TextInserter.frontmostAppBundleID()
        Log.info("Recording stopped: \(String(format: "%.2f", duration))s held, \(samples.count) samples " +
                 "(\(String(format: "%.2f", Double(samples.count) / 16000))s captured, mic stop \(stopMs) ms)")

        // Too-short press: cancel silently (SPEC: < 0.15 s).
        if duration < 0.15 || samples.count < 2400 {
            Log.info("Take too short — discarded")
            setState(.idle)
            hud.hide()
            return
        }

        setState(.transcribing)
        let thisDictation = dictationCounter

        // To disk in parallel with transcription (a few ms of SSD write, off
        // the critical path): if the process has to restart, the take is
        // recovered on the next launch.
        let vaulted = Task.detached(priority: .utility) { TakeVault.save(samples) }

        Task { [weak self] in
            guard let self else { return }
            do {
                let tStart = Date()
                let raw = try await self.transcribeWithRetry(samples)
                let msTranscribe = Log.ms(since: tStart)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("Transcribed in \(msTranscribe) ms: \"\(trimmed)\"")
                guard !trimmed.isEmpty else {
                    await vaulted.value
                    await MainActor.run {
                        TakeVault.clear()
                        self.setState(.idle)
                        self.hud.hide()
                        self.setModelStatus("Ready — nothing heard")
                    }
                    return
                }
                let withDictionary = PersonalDictionary.shared.apply(to: trimmed)
                let mode = Preferences.shared.cleanupMode

                // FAST PATH: rules-clean and insert immediately. The AI polish
                // (if enabled) runs afterwards in the background and replaces
                // the text in place only when it is provably safe to do so.
                let tClean = Date()
                let fastCleaned = (mode == .off) ? withDictionary : TextCleaner.applyRules(withDictionary)
                let msClean = Log.ms(since: tClean)
                let entryID = UUID()
                let insertedString: String = await MainActor.run {
                    self.setState(.inserting)
                    let tInsert = Date()
                    let inserted = self.inserter.insert(fastCleaned)
                    let msInsert = Log.ms(since: tInsert)
                    HistoryStore.shared.add(HistoryEntry(
                        id: entryID,
                        rawText: trimmed,
                        cleanedText: fastCleaned,
                        appBundleID: bundleID,
                        durationSeconds: duration
                    ))
                    self.setState(.idle)
                    self.hud.hide()
                    self.setModelStatus(self.readyStatus(lastMs: msTranscribe))
                    // The number that actually matters: key release → text on screen.
                    Log.info("LATENCY release→text \(Log.ms(since: released)) ms " +
                             "(mic stop \(stopMs), transcribe \(msTranscribe), clean \(msClean), insert \(msInsert))")
                    return inserted
                }
                await vaulted.value
                TakeVault.clear()
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
                    Log.info("AI polish applied in place (\(msPolish) ms)")
                }
            } catch let fault as TranscriberFault where fault.hung {
                // Only reached when the engine could not be brought back in
                // place; the take is still in the vault for the next launch.
                Log.error("Speech engine fault — restarting: \(fault.message)")
                await MainActor.run { self.showTransientError(fault.message) }
                await vaulted.value          // never restart before the take is on disk
                try? await Task.sleep(nanoseconds: 1_500_000_000) // let the HUD show
                ProcessLifecycle.restartSelf(reason: "speech engine hung")
            } catch {
                self.log.error("Pipeline failed: \(error.localizedDescription)")
                Log.error("Transcription failed", error)
                await MainActor.run {
                    self.showTransientError(error.localizedDescription +
                        "  Your dictation was kept — use Recover Last Take in the menu.")
                }
            }
        }
    }

    /// A dead engine surfaces as a non-hung fault: rebuild it and run the
    /// same audio again, so the user never has to repeat themselves. A hang
    /// propagates — nothing in-process can fix that.
    private func transcribeWithRetry(_ samples: [Float]) async throws -> String {
        do {
            return try await transcriber.transcribe(samples)
        } catch let fault as TranscriberFault where !fault.hung {
            Log.info("Engine fault during dictation — reloading and retrying the same take")
            await MainActor.run { self.hud.update(state: .notice("Restarting engine…")) }
            await transcriber.reload()
            guard await transcriber.isReady else {
                throw TranscriberFault(message: "The speech engine could not be reloaded. VoxFlow is restarting itself; your dictation was saved.", hung: true)
            }
            await MainActor.run { self.hud.update(state: .transcribing) }
            return try await transcriber.transcribe(samples)
        }
    }

    /// A take that survived a restart (or a failed transcription) is
    /// transcribed as soon as the engine is ready and saved to History only.
    /// Never the clipboard, never the focused window — pasting into whatever
    /// happens to be focused later would be a nasty surprise.
    private func recoverPendingTake(reason: String) {
        guard !recovering else { return }
        guard let samples = TakeVault.load(), samples.count >= 4800 else {
            TakeVault.clear()
            return
        }
        recovering = true
        Log.info("Recovering pending take (\(String(format: "%.1f", Double(samples.count) / 16000))s, \(reason))")

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.recovering = false } }
            do {
                let raw = try await self.transcriber.transcribe(samples)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    Log.info("Pending take transcribed to nothing — dropped")
                    await MainActor.run { TakeVault.clear() }
                    return
                }
                let withDictionary = PersonalDictionary.shared.apply(to: raw)
                let cleaned = Preferences.shared.cleanupMode == .off
                    ? withDictionary : TextCleaner.applyRules(withDictionary)
                await MainActor.run {
                    HistoryStore.shared.add(HistoryEntry(
                        rawText: raw, cleanedText: cleaned, appBundleID: "recovered",
                        durationSeconds: Double(samples.count) / 16000))
                    TakeVault.clear()
                    Log.info("Recovered take (\(cleaned.count) chars) saved to History")
                    self.showNotice("Your last dictation was saved to History (menu bar → History…).", seconds: 6)
                }
            } catch {
                Log.error("Could not recover pending take (kept on disk)", error)
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

    /// Informational HUD message that does not disturb the pipeline: a new
    /// hotkey press cancels it.
    private func showNotice(_ message: String, seconds: TimeInterval = 3) {
        guard case .idle = state else {
            Log.info("Notice (HUD busy): \(message)")
            return
        }
        setState(.notice(message))
        hud.show()
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .notice = self.state {
                    self.setState(.idle)
                    self.hud.hide()
                }
            }
        }
    }
}
