import Foundation
import WhisperKit
import os

/// Errors surfaced by `Transcriber`.
enum TranscriberError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The transcription model is not loaded yet."
        }
    }
}

/// Wraps a WhisperKit pipeline, owning model load/download lifecycle and
/// exposing a simple transcribe entry point. See Sources/VoxFlow/Support/Contracts.swift
/// for the frozen public shape this must match.
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

    private let logger = Logger(subsystem: "com.voxflow.app", category: "Transcriber")

    private var pipe: WhisperKit?
    private var loadedChoice: WhisperModelChoice?

    /// Loads/downloads the WhisperKit model named by `choice.rawValue`. Tears
    /// down any previously-loaded pipeline first.
    func loadModel(_ choice: WhisperModelChoice) async {
        // Tear down any existing instance before loading a new one.
        pipe = nil
        loadedChoice = nil
        state = .loading(progress: 0)

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
        }

        do {
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
            loadedChoice = choice
            // Warm the full GPU decode pipeline with half a second of silence so
            // the first real dictation doesn't pay shader-compile costs.
            _ = try? await newPipe.transcribe(audioArray: [Float](repeating: 0, count: 8000))
            state = .ready
            logger.info("WhisperKit model loaded & warmed: \(choice.rawValue, privacy: .public)")
        } catch {
            pipe = nil
            loadedChoice = nil
            let message = error.localizedDescription
            logger.error("Failed to load WhisperKit model \(choice.rawValue, privacy: .public): \(message, privacy: .public)")
            state = .failed(message)
        }
    }

    /// Transcribes 16 kHz mono samples to raw text. Throws if not ready.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard case .ready = state, let pipe else {
            throw TranscriberError.notReady
        }
        guard samples.count >= Self.minimumSampleCount else {
            return ""
        }

        // Skipping timestamp tokens shrinks the decode meaningfully — we only
        // need the text.
        var options = DecodingOptions()
        options.withoutTimestamps = true
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let joined = results.map(\.text).joined(separator: " ")
        return Self.stripArtifacts(joined)
    }

    // MARK: - Helpers

    private func updateLoadingProgress(_ fraction: Double) {
        guard case .loading = state else { return }
        state = .loading(progress: fraction)
    }

    /// Strips Whisper decoding artifacts such as "[BLANK_AUDIO]", "[MUSIC]",
    /// "(silence)", and "<|...|>" special tokens, then trims whitespace.
    private static func stripArtifacts(_ text: String) -> String {
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
}
