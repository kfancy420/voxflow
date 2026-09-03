import Foundation

/// Keeps the audio of the take currently being transcribed on disk, so that
/// an engine fault — even one that forces a process restart — never costs the
/// user what they just said. Cleared once the text has been delivered.
///
/// Stored as a plain 16 kHz mono 16-bit WAV at
/// `~/Library/Application Support/VoxFlow/pending-take.wav`.
enum TakeVault {
    static var fileURL: URL {
        PersonalDictionary.applicationSupportDirectory().appendingPathComponent("pending-take.wav")
    }

    private static let sampleRate: UInt32 = 16_000

    static var hasPending: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static func save(_ samples: [Float]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var pcm = Data(capacity: samples.count * 2)
            for s in samples {
                let clamped = max(-1.0, min(1.0, s))
                var v = Int16(clamped * 32767.0).littleEndian
                withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
            }
            var data = Data(capacity: 44 + pcm.count)
            data.append(contentsOf: Array("RIFF".utf8))
            data.append(le32(UInt32(36 + pcm.count)))
            data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8))
            data.append(le32(16))                       // PCM chunk size
            data.append(le16(1))                        // PCM
            data.append(le16(1))                        // mono
            data.append(le32(sampleRate))
            data.append(le32(sampleRate * 2))           // byte rate
            data.append(le16(2))                        // block align
            data.append(le16(16))                       // bits per sample
            data.append(contentsOf: Array("data".utf8))
            data.append(le32(UInt32(pcm.count)))
            data.append(pcm)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.warn("Could not save pending take: \(error.localizedDescription)")
        }
    }

    /// Reads back the vaulted take, or nil if there is none / it is unreadable.
    static func load() -> [Float]? {
        guard hasPending else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count > 44,
                  String(data: data[0..<4], encoding: .ascii) == "RIFF",
                  String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
                Log.warn("Pending take is not a WAV file")
                return nil
            }
            // Walk the chunks to the "data" chunk (we always write it last).
            var offset = 12
            var channels = 1
            var bits = 16
            while offset + 8 <= data.count {
                let id = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
                let size = Int(readLE32(data, offset + 4))
                let body = offset + 8
                if id == "fmt ", body + 16 <= data.count {
                    channels = Int(readLE16(data, body + 2))
                    bits = Int(readLE16(data, body + 14))
                } else if id == "data" {
                    guard channels == 1, bits == 16 else {
                        Log.warn("Pending take must be 16-bit mono (got \(bits)-bit, \(channels) ch)")
                        return nil
                    }
                    let end = min(data.count, body + size)
                    let count = (end - body) / 2
                    var samples = [Float](repeating: 0, count: count)
                    data.withUnsafeBytes { raw in
                        let base = raw.baseAddress!.advanced(by: body)
                        for i in 0..<count {
                            let v = Int16(littleEndian: base.advanced(by: i * 2).loadUnaligned(as: Int16.self))
                            samples[i] = Float(v) / 32768.0
                        }
                    }
                    return samples
                }
                offset = body + size + (size & 1)
            }
            return nil
        } catch {
            Log.warn("Could not load pending take: \(error.localizedDescription)")
            return nil
        }
    }

    static func clear() {
        guard hasPending else { return }
        do { try FileManager.default.removeItem(at: fileURL) }
        catch { Log.warn("Could not clear pending take: \(error.localizedDescription)") }
    }

    // MARK: - Byte helpers

    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }

    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func readLE16(_ d: Data, _ at: Int) -> UInt16 {
        UInt16(d[d.startIndex + at]) | (UInt16(d[d.startIndex + at + 1]) << 8)
    }

    private static func readLE32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(readLE16(d, at)) | (UInt32(readLE16(d, at + 2)) << 16)
    }
}
