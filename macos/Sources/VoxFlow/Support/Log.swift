import Foundation
import os

/// Append-only diagnostic log at
/// `~/Library/Application Support/VoxFlow/voxflow.log`, mirrored to the
/// unified log. Deliberately dependency-free and exception-proof: logging
/// must never be the reason the app fails.
///
/// The unified log is fine for developers with Console.app open, but a user
/// whose hotkey has just died needs something they can open from the menu
/// bar and paste into a bug report — hence the file (same as the Windows
/// build's `%APPDATA%\VoxFlow\voxflow.log`).
enum Log {
    private static let gate = NSLock()
    private static let unified = Logger(subsystem: "com.voxflow.app", category: "VoxFlow")
    private static let maxBytes: UInt64 = 1_000_000

    static let fileURL: URL = {
        let dir = PersonalDictionary.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voxflow.log")
    }()

    static func info(_ message: String) {
        unified.info("\(message, privacy: .public)")
        write("INFO ", message)
    }

    static func warn(_ message: String) {
        unified.notice("\(message, privacy: .public)")
        write("WARN ", message)
    }

    static func error(_ message: String, _ error: Error? = nil) {
        var text = message
        if let error {
            text += "\n" + String(describing: error)
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                text += "\n--- underlying ---\n" + String(describing: underlying)
            }
        }
        unified.error("\(text, privacy: .public)")
        write("ERROR", text)
    }

    private static func write(_ level: String, _ message: String) {
        gate.lock()
        defer { gate.unlock() }
        let line = "\(stamp()) \(level) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? UInt64, size > maxBytes {
                // Keep the log from growing without bound across a long-running install.
                try? "\(stamp()) INFO  (log truncated)\n".data(using: .utf8)?.write(to: fileURL)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // logging must never throw
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func stamp() -> String { stampFormatter.string(from: Date()) }

    /// Milliseconds elapsed since a reference `Date`.
    static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
