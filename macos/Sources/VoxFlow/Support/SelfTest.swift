import AVFoundation
import Foundation

/// Headless verification entry points. VoxFlow is a hold-a-key-and-talk app,
/// which makes it awkward to prove correct without a human in the chair;
/// these modes exercise the pipeline stages independently so a failure can be
/// pinned to one component. Mirrors the Windows `--selftest-*` switches.
///
///   VoxFlow --selftest-clean <file.txt>   cleanup pipeline on a raw transcript
///   VoxFlow --selftest-wav   <file.wav>   model load → transcribe → dictionary → cleanup
///
/// Results go to stdout and to `~/Library/Application Support/VoxFlow/selftest.txt`.
enum SelfTest {
    static var resultURL: URL {
        PersonalDictionary.applicationSupportDirectory().appendingPathComponent("selftest.txt")
    }

    /// Returns nil when the arguments are not a self-test; otherwise the
    /// process exit code.
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1].hasPrefix("--selftest") else { return nil }
        let mode = arguments[1]
        let argument = arguments.count > 2 ? arguments[2] : ""
        var report = ""
        var exitCode: Int32 = 0

        switch mode {
        case "--selftest-clean":
            exitCode = cleanFile(argument, &report)
        case "--selftest-wav":
            exitCode = transcribeWav(argument, &report)
        default:
            report += "unknown selftest mode: \(mode)\n"
            exitCode = 2
        }

        print(report, terminator: "")
        Log.info("selftest result:\n" + report)
        try? report.write(to: resultURL, atomically: true, encoding: .utf8)
        return exitCode
    }

    /// Runs the cleanup pipeline on a text file so punctuation rules can be
    /// tuned against real transcripts offline.
    private static func cleanFile(_ path: String, _ report: inout String) -> Int32 {
        report += "MODE --selftest-clean \(path)\n"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            report += "  FAIL: could not read file\n"
            return 1
        }
        let withDictionary = PersonalDictionary.shared.apply(to: text.trimmingCharacters(in: .whitespacesAndNewlines))
        report += "RAW     : \(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        report += "CLEANED : \(TextCleaner.applyRules(withDictionary))\n"
        return 0
    }

    private static func transcribeWav(_ path: String, _ report: inout String) -> Int32 {
        report += "MODE --selftest-wav \(path)\n"
        let samples: [Float]
        do {
            samples = try load16kMono(URL(fileURLWithPath: path), &report)
        } catch {
            report += "  FAIL: \(error.localizedDescription)\n"
            return 1
        }
        report += "  samples=\(samples.count) (\(String(format: "%.2f", Double(samples.count) / 16000))s)\n"

        let choice = Preferences.shared.modelChoice
        let transcriber = Transcriber()
        let outcome = Outcome()

        // Block the (non-main) caller until the async pipeline finishes.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let loadStart = Date()
            await transcriber.loadModel(choice)
            outcome.loadSeconds = Date().timeIntervalSince(loadStart)
            guard await transcriber.isReady else {
                outcome.failure = "model not ready (\(await transcriber.state))"
                done.signal()
                return
            }
            do {
                let t = Date()
                outcome.raw = try await transcriber.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                outcome.transcribeMs = Log.ms(since: t)
            } catch {
                outcome.failure = error.localizedDescription
            }
            done.signal()
        }
        done.wait()

        report += "  model \(choice.rawValue) load: \(String(format: "%.1f", outcome.loadSeconds))s\n"
        if let failure = outcome.failure {
            report += "  FAIL: \(failure)\n"
            return 1
        }
        let raw = outcome.raw
        let cleaned = TextCleaner.applyRules(PersonalDictionary.shared.apply(to: raw))
        report += "  transcribe: \(outcome.transcribeMs) ms\n"
        report += "  RAW     : \"\(raw)\"\n"
        report += "  CLEANED : \"\(cleaned)\"\n"
        report += raw.isEmpty ? "  FAIL: empty transcript\n" : "  PASS\n"
        return raw.isEmpty ? 1 : 0
    }

    /// Mutable results handed across the async boundary (written before the
    /// semaphore is signalled, read after it is waited on).
    private final class Outcome: @unchecked Sendable {
        var raw = ""
        var loadSeconds = 0.0
        var transcribeMs = 0
        var failure: String?
    }

    /// Reads any audio file CoreAudio understands into 16 kHz mono Float32.
    static func load16kMono(_ url: URL, _ report: inout String) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        report += "  audio format: \(Int(source.sampleRate)) Hz, \(source.channelCount) ch\n"
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "VoxFlow.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not allocate audio buffer"])
        }
        try file.read(into: inBuffer)

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "VoxFlow.SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not create audio converter"])
        }
        let ratio = 16_000 / source.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "VoxFlow.SelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not allocate output buffer"])
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error, let conversionError { throw conversionError }
        guard let channel = outBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }
}
