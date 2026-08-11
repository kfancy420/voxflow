import Foundation
import os

/// User-maintained trigger -> replacement substitutions, applied to
/// transcripts before cleanup. See Contracts.swift for the frozen shape.
final class PersonalDictionary {
    static let shared = PersonalDictionary()

    private let logger = Logger(subsystem: "com.voxflow.app", category: "PersonalDictionary")
    private let lock = NSLock()
    private let fileURL: URL
    private var storage: [DictionaryEntry] = []

    var entries: [DictionaryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(fileURL: URL = PersonalDictionary.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func add(_ entry: DictionaryEntry) {
        lock.lock()
        storage.append(entry)
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
        postChange()
    }

    func update(_ entry: DictionaryEntry) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.id == entry.id }) {
            storage[index] = entry
        }
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
        postChange()
    }

    func remove(id: UUID) {
        lock.lock()
        storage.removeAll { $0.id == id }
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
        postChange()
    }

    /// Whole-word replacements, longest trigger first, so overlapping
    /// triggers (e.g. "Vitality" and "Vitality Massage") don't clobber each
    /// other unpredictably.
    func apply(to text: String) -> String {
        let snapshot = entries
        guard !text.isEmpty, !snapshot.isEmpty else { return text }

        let ordered = snapshot.sorted { $0.trigger.count > $1.trigger.count }
        var result = text

        for entry in ordered {
            let trigger = entry.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: trigger)
            // Only anchor with \b where the trigger actually starts/ends with a
            // word character — otherwise triggers like "C++" or ".NET" could
            // never match.
            func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
            let leadingBoundary = trigger.first.map(isWordCharacter) == true ? "\\b" : ""
            let trailingBoundary = trigger.last.map(isWordCharacter) == true ? "\\b" : ""
            let pattern = leadingBoundary + escaped + trailingBoundary
            var options: NSRegularExpression.Options = []
            if entry.caseInsensitive {
                options.insert(.caseInsensitive)
            }

            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                logger.error("Skipping invalid dictionary trigger pattern for entry \(entry.id.uuidString, privacy: .public)")
                continue
            }

            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: entry.replacement)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }

        return result
    }

    // MARK: - Persistence

    static func defaultFileURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("dictionary.json")
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VoxFlow", isDirectory: true)
    }

    private func load() {
        ensureDirectoryExists()

        guard let data = try? Data(contentsOf: fileURL) else {
            storage = []
            return
        }
        guard let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            logger.error("dictionary.json is missing or corrupt; starting with an empty dictionary.")
            storage = []
            return
        }
        storage = decoded
    }

    private func persist(_ snapshot: [DictionaryEntry]) {
        ensureDirectoryExists()
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist dictionary.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureDirectoryExists() {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create Application Support/VoxFlow directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voxFlowPrefsChanged, object: nil)
        }
    }
}
