import Foundation
import WhisperKit
import os

/// Errors surfaced by `Transcriber`.
enum TranscriberError: LocalizedError {
    case notReady
    case downloading

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The transcription model is not loaded yet."
        case .downloading:
            return "The speech model is still downloading — check the menu bar for progress."
        }
    }
}

/// The speech backend stopped working mid-session. `hung` means a native
/// call never returned and the process must be restarted (nothing in-process
/// can unwind a stuck CoreML/Metal call); otherwise a model reload is enough
/// and the caller should retry the same audio.
struct TranscriberFault: LocalizedError {
    let message: String
    let hung: Bool
    var errorDescription: String? { message }
}

/// Wraps a WhisperKit pipeline, owning model load/download lifecycle and
/// exposing a simple transcribe entry point. See Sources/VoxFlow/Support/Contracts.swift
/// for the public shape this must match.
actor Transcriber {
    enum State: Equatable {
        case unloaded
        case loading(progress: Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .unloaded

    /// 0.3s of audio at 16 kHz mono.
    private static let minimumSampleCount = 4_800
    private static let sampleRate = 16_000.0

    private let logger = Logger(subsystem: "com.voxflow.app", category: "Transcriber")

    private var pipe: WhisperKit?
    private var loadedChoice: WhisperModelChoice?
    /// The most recent transcription task; every call chains behind the
    /// previous one so two takes never run through the pipeline at once.
    private var lastWork: Task<[TranscriptionResult], Error>?

    /// Which compute path is in use (for the status line and the log).
    let backend = "Metal"

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// The model currently loaded (or being loaded).
    var currentChoice: WhisperModelChoice? { loadedChoice }

    private static let hungSeconds: TimeInterval = 30      // floor for short takes
    private static let hungMultiplier: TimeInterval = 3    // × audio length for long takes
    private static let reloadSeconds: TimeInterval = 90
    private static let instantEmptyMs = 150

    private static let silenceRms: Float = 0.004   // ≈ -48 dBFS: nothing was said
    private static let quietRms: Float = 0.02      // low enough to distrust filler

    /// Whisper reliably invents polite filler when handed silence — "Thank
    /// you.", "Thanks for watching!" and friends are artefacts of its training
    /// data, not transcription. Without a guard those get pasted into whatever
    /// the user is typing in, so quiet takes are rejected outright and a short
    /// result from a quiet take is treated as a hallucination.
    private static let silenceHallucinations: Set<String> = [
        "thank you", "thank you.", "thanks", "thanks.", "thank you very much",
        "thanks for watching", "thanks for watching!", "thank you for watching",
        "you", "bye", "bye.", "okay", "ok", ".", "so", "yeah",
    ]

    /// Loads/downloads the WhisperKit model named by `choice.rawValue`. Tears
    /// down any previously-loaded pipeline first.
    func loadModel(_ choice: WhisperModelChoice) async {
        // Tear down any existing instance before loading a new one.
        pipe = nil
        loadedChoice = choice
        state = .loading(progress: 0)
        Log.info("Loading model \(choice.rawValue) (downloaded=\(choice.isDownloaded))")

        // Best-effort real download progress via the static download helper.
        // WhisperKitConfig itself has no progress callback, but
        // `WhisperKit.download(variant:progressCallback:)` does — use it to
        // pre-fetch the model so we can surface real percentages. If this
        // step fails for any reason we still fall through to the normal
        // (self-downloading) initializer below.
        do {
            _ = try await WhisperKit.download(
                variant: choice.rawValue,
                progressCallback: { [weak self] progress in
                    let fraction = min(max(progress.fractionCompleted, 0), 1)
                    Task { await self?.updateLoadingProgress(fraction * 0.95) }
                }
            )
        } catch {
            logger.notice("Pre-download step failed (will still attempt normal load): \(error.localizedDescription, privacy: .public)")
            Log.warn("Model pre-download failed for \(choice.rawValue): \(error.localizedDescription)")
        }

        do {
            state = .loading(progress: 0.96)
            let loadStart = Date()
            // NOTE: `verbose: false` makes WhisperKit force its log level to
            // `.none` internally, so we deliberately do not pass `logLevel:`.
            // CPU+GPU compute: the default cpuAndNeuralEngine path can wedge
            // indefinitely in aned's first-run model specialization on some
            // macOS 26 systems; Metal-only is reliably fast on Apple Silicon.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            )
            let config = WhisperKitConfig(model: choice.rawValue, computeOptions: compute, verbose: false, prewarm: true)
            let newPipe = try await WhisperKit(config)
            pipe = newPipe
            // Warm the full GPU decode pipeline with half a second of silence so
            // the first real dictation doesn't pay shader-compile costs.
            let warmStart = Date()
            _ = try? await newPipe.transcribe(audioArray: [Float](repeating: 0, count: 8000), decodeOptions: Self.decodingOptions())
            state = .ready
            logger.info("WhisperKit model loaded & warmed: \(choice.rawValue, privacy: .public)")
            Log.info("Model ready: \(choice.rawValue) (load \(Log.ms(since: loadStart)) ms, warm-up \(Log.ms(since: warmStart)) ms, backend=\(backend))")
        } catch {
            pipe = nil
            let message = error.localizedDescription
            logger.error("Failed to load WhisperKit model \(choice.rawValue, privacy: .public): \(message, privacy: .public)")
            Log.error("Model load FAILED for \(choice.rawValue)", error)
            state = .failed(message)
        }
    }

    /// Re-creates the backend for the current model after a fault.
    func reload() async {
        guard let choice = loadedChoice else { return }
        Log.info("Reloading speech engine (\(choice.rawValue))")
        await loadModel(choice)
    }

    private static func decodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        // Skipping timestamp tokens shrinks the decode meaningfully — we only
        // need the text.
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        // No temperature fallback. By default a window that fails whisper's
        // confidence checks (fast speech with restarts does this) is
        // re-decoded at up to five higher temperatures — on Windows a 60 s
        // take went from ~1.5 s to 12.5 s that way. Dictation needs
        // predictable latency: one deterministic pass per window.
        options.temperatureFallbackCount = 0
        return options
    }

    /// Transcribes 16 kHz mono samples to raw text. Throws if not ready.
    /// Returns "" for very short or silent takes.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await waitForEngine()
        guard isReady, pipe != nil else { throw TranscriberError.notReady }
        guard samples.count >= Self.minimumSampleCount else { return "" }

        let rms = Self.rms(samples)
        if rms < Self.silenceRms {
            Log.info("Take rejected as silence (rms=\(String(format: "%.5f", rms)))")
            return ""
        }

        let audioSeconds = Double(samples.count) / Self.sampleRate
        let budget = max(Self.hungSeconds, audioSeconds * Self.hungMultiplier)
        let (rawText, segmentCount, elapsedMs) = try await runGuarded(samples, budget: budget, what: "dictation")

        // A dead backend does not throw — it just returns no segments almost
        // instantly. Real inference on a second or more of clearly audible
        // speech never finishes that fast.
        if segmentCount == 0, audioSeconds >= 1.0, rms >= Self.quietRms, elapsedMs < Self.instantEmptyMs {
            state = .failed("Speech engine returned nothing")
            Log.error("Backend returned nothing in \(elapsedMs) ms for \(String(format: "%.1f", audioSeconds))s of audio " +
                      "(rms=\(String(format: "%.4f", rms)), backend=\(backend)) — treating as a dead engine")
            throw TranscriberFault(message: "The speech engine stopped working; reloading it and retrying your dictation.", hung: false)
        }

        // Resolve the provisional segment breaks here so the raw transcript
        // (History, cleanup-off mode) never carries the marker.
        let text = PunctuationSanity.apply(rawText)

        if rms < Self.quietRms, Self.isLikelyHallucination(text) {
            Log.info("Discarded likely hallucination \"\(text)\" (rms=\(String(format: "%.5f", rms)))")
            return ""
        }
        return text
    }

    // MARK: - Engine guard

    /// If a (re)load is in flight, waits for it, so a dictation captured while
    /// the engine was being rebuilt proceeds on the new engine instead of
    /// failing. A first-run download is the exception: that can take minutes
    /// and is reported, not waited on.
    private func waitForEngine() async throws {
        guard case .loading(let progress) = state else { return }
        if progress < 0.95 { throw TranscriberError.downloading }
        Log.info("Waiting for engine reload before transcribing…")
        let deadline = Date().addingTimeInterval(Self.reloadSeconds)
        while case .loading = state {
            if Date() > deadline {
                Log.error("Engine reload did not finish within \(Int(Self.reloadSeconds))s")
                throw TranscriberFault(
                    message: "The speech engine could not be rebuilt. VoxFlow is restarting itself; your dictation was saved.",
                    hung: true)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Runs the native call under a watchdog. The call cannot be cancelled,
    /// so on timeout the engine is marked failed and the caller must restart
    /// the process; the take is already vaulted on disk by then.
    private func runGuarded(_ samples: [Float], budget: TimeInterval, what: String) async throws
        -> (text: String, segments: Int, elapsedMs: Int)
    {
        guard let pipe else { throw TranscriberError.notReady }
        let options = Self.decodingOptions()
        let previous = lastWork
        let started = Date()
        let work = Task<[TranscriptionResult], Error> {
            // Serialise behind whatever is still running (a recovery, say).
            _ = try? await previous?.value
            return try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        }
        lastWork = work

        // Race the native call against the watchdog. A task group cannot be
        // used here: it would wait for the (possibly hung) child before
        // returning. Two detached tasks and a resume-once continuation let
        // the timeout win while the stuck call is simply abandoned.
        let outcome: WatchdogOutcome = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task {
                do { once.resume(.done(.success(try await work.value))) }
                catch { once.resume(.done(.failure(error))) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                once.resume(.timeout)
            }
        }

        let results: [TranscriptionResult]
        switch outcome {
        case .done(.success(let value)):
            results = value
        case .done(.failure(let error)):
            throw error
        case .timeout:
            state = .failed("Speech engine stopped responding")
            Log.error("Transcription hung (\(what)): no result after \(Int(budget))s " +
                      "for \(String(format: "%.1f", Double(samples.count) / Self.sampleRate))s of audio (backend=\(backend))")
            throw TranscriberFault(
                message: "The speech engine stopped responding. VoxFlow is restarting itself; your dictation was saved.",
                hung: true)
        }

        let joiner = SegmentJoiner()
        var segments = 0
        for result in results {
            for segment in result.segments {
                segments += 1
                joiner.add(Self.stripArtifacts(segment.text))
            }
        }
        // Some WhisperKit paths report text without segment detail; never
        // lose it.
        if segments == 0 {
            let flat = Self.stripArtifacts(results.map(\.text).joined(separator: " "))
            if !flat.isEmpty { joiner.add(flat); segments = 1 }
        }
        return (joiner.finish(), segments, Log.ms(since: started))
    }

    private enum WatchdogOutcome {
        case done(Result<[TranscriptionResult], Error>)
        case timeout
    }

    /// Resumes a continuation at most once, whichever racer finishes first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<WatchdogOutcome, Never>?

        init(_ continuation: CheckedContinuation<WatchdogOutcome, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: WatchdogOutcome) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
        }
    }

    // MARK: - Helpers

    private func updateLoadingProgress(_ fraction: Double) {
        guard case .loading = state else { return }
        state = .loading(progress: fraction)
    }

    private static func isLikelyHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "!.,?"))
            .lowercased()
        return t.isEmpty || silenceHallucinations.contains(t)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Strips Whisper decoding artifacts such as "[BLANK_AUDIO]", "[MUSIC]",
    /// "(silence)", and "<|...|>" special tokens, then trims whitespace.
    static func stripArtifacts(_ text: String) -> String {
        var cleaned = text

        // Special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
        cleaned = replacing(cleaned, pattern: #"<\|[^>]*\|>"#, with: "")
        // Bracketed tags like [BLANK_AUDIO], [MUSIC].
        cleaned = replacing(cleaned, pattern: #"\[[^\[\]]*\]"#, with: "")
        // Parenthesized tags like (silence), (music playing).
        cleaned = replacing(cleaned, pattern: #"\([^()]*\)"#, with: "")
        // Collapse whitespace left behind by the stripping above.
        cleaned = replacing(cleaned, pattern: #"[ \t]+"#, with: " ")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Joins whisper's segments into one transcript. A segment boundary is
    /// where whisper paused its decoding — usually at a pause in speech — and
    /// it starts every segment with a capital whether or not a sentence
    /// begins there. That capital used to be read as a sentence end and
    /// turned into a full stop; on fast speech the boundaries land
    /// mid-phrase ("there was no negative" + "Consequences or anything"),
    /// so it produced sentences that were never spoken. Pauses are no longer
    /// a punctuation signal at all: segments are joined with a space, and
    /// whisper's own punctuation is the only punctuation the raw transcript
    /// carries. Sentence structure is decided afterwards, over the finished
    /// take (`RunOnSplitter` and `PunctuationSanity`). Same rules as the
    /// Windows build's `SegmentJoiner`; keep the two in step.
    ///
    /// The stray capital at an unpunctuated seam is lowered so the join reads
    /// as one sentence, except where it is plainly not a seam artefact: the
    /// pronoun I, an acronym, or the first word of a capitalised phrase
    /// ("Wild Crazy 8s"), which whisper capitalised because it is a name.
    final class SegmentJoiner {
        private var out = ""
        private var seams = 0

        func add(_ segmentText: String) {
            var t = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if let last = out.last {
                let punctuated = ".!?,;:…—-\"".contains(last)
                if !punctuated {
                    seams += 1
                    t = Self.lowerSeamCapital(t)
                }
                out.append(" ")
            }
            out.append(t)
        }

        private static func lowerSeamCapital(_ t: String) -> String {
            guard let first = t.first, first.isUppercase else { return t }
            let words = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let head = words.first else { return t }
            let word = head.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            if word == "I" || word.hasPrefix("I'") { return t }
            if word.count > 1, word.uppercased() == word { return t } // acronym
            // Next word also capitalised: a name phrase, not a seam artefact.
            if words.count > 1, let next = words[1].first, next.isUppercase { return t }
            return first.lowercased() + t.dropFirst()
        }

        func finish() -> String {
            if seams > 0 { Log.info("Segment seams joined without a break: \(seams)") }
            return out
        }
    }
}
