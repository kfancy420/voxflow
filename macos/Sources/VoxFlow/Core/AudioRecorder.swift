import AVFoundation
import AppKit
import os

/// Captures microphone audio while recording is active, converting each
/// buffer to 16 kHz mono Float32 as it arrives and accumulating the whole
/// take in memory for later transcription.
final class AudioRecorder {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "AudioRecorder")
    private static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private var samples: [Float] = []
    private let samplesLock = NSLock()

    private(set) var isRecording: Bool = false

    init() {}

    /// Requests mic permission if needed, then starts the audio engine and
    /// installs a tap on the input node. Throws a descriptive NSError on any
    /// failure (permission denied, no input device, engine start failure).
    func startRecording() throws {
        guard !isRecording else { return }

        try requestMicPermissionIfNeeded()

        let inputNode = engine.inputNode
        // IMPORTANT: use the input node's own output format for the tap —
        // never hardcode a format, since hardware sample rates/channel
        // counts vary (e.g. AirPods vs. built-in mic).
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw Self.error("No audio input is available. Check that a microphone is connected and selected in System Settings > Sound > Input.")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Self.error("Could not create the target 16 kHz mono audio format.")
        }
        self.targetFormat = targetFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw Self.error("Could not create an audio converter for the current input device.")
        }
        self.converter = converter

        samplesLock.lock()
        samples.removeAll()
        samplesLock.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            throw Self.error("Failed to start the audio engine: \(error.localizedDescription)")
        }

        isRecording = true
        playFeedbackSound(named: "Pop")
        Self.logger.info("Recording started")
    }

    /// Stops recording and returns the accumulated mono 16 kHz Float32
    /// samples for the whole take.
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        targetFormat = nil

        playFeedbackSound(named: "Bottle")

        samplesLock.lock()
        let result = samples
        samples.removeAll()
        samplesLock.unlock()

        Self.logger.info("Recording stopped; captured \(result.count) samples")
        return result
    }

    // MARK: - Permission

    private func requestMicPermissionIfNeeded() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            // Never block the caller (this runs on the main thread) waiting on
            // the TCC dialog — kick off the request and ask the user to retry.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Self.logger.notice("Microphone permission granted: \(granted)")
            }
            throw Self.error("VoxFlow needs microphone access. Allow it in the prompt, then hold the hotkey again.")
        case .denied, .restricted:
            throw Self.error("Microphone access is disabled for VoxFlow. Enable it in System Settings > Privacy & Security > Microphone.")
        @unknown default:
            throw Self.error("Unknown microphone authorization status.")
        }
    }

    // MARK: - Audio processing (runs on the audio tap thread)

    private func process(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let conversionError {
                Self.logger.error("Audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            }
            return
        }

        guard let channelData = outputBuffer.floatChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }

        let samplePointer = channelData[0]
        let newSamples = Array(UnsafeBufferPointer(start: samplePointer, count: frameLength))

        samplesLock.lock()
        samples.append(contentsOf: newSamples)
        samplesLock.unlock()

        postAudioLevel(for: newSamples)
    }

    private func postAudioLevel(for chunk: [Float]) {
        guard !chunk.isEmpty else { return }

        var sumSquares: Float = 0
        for sample in chunk {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(chunk.count))
        // Scale RMS (typically ~0.02-0.2 for speech) so normal speech reads
        // roughly 0.3-0.8 on the 0-1 meter.
        let level: Float = min(1.0, max(0.0, rms * 6.0))

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .voxFlowAudioLevel,
                object: nil,
                userInfo: ["level": level]
            )
        }
    }

    // MARK: - Feedback sounds

    private func playFeedbackSound(named name: String) {
        let playSounds = (UserDefaults.standard.object(forKey: "playSounds") as? Bool) ?? true
        guard playSounds else { return }
        // AppKit work always goes to the main thread; this method is called
        // from a nonisolated type.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let sound = NSSound(named: NSSound.Name(name))
                _ = sound?.play()
            }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.voxflow.app.AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
