import Foundation
import os

/// Persisted log of completed dictations, newest first, capped at 200
/// entries. See Contracts.swift for the frozen shape.
final class HistoryStore {
    static let shared = HistoryStore()

    private static let capacity = 200

    private let logger = Logger(subsystem: "com.voxflow.app", category: "HistoryStore")
    private let lock = NSLock()
    private let fileURL: URL
    private var storage: [HistoryEntry] = []

    var entries: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(fileURL: URL = HistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func add(_ entry: HistoryEntry) {
        guard !entry.cleanedText.isEmpty else { return }

        lock.lock()
        storage.insert(entry, at: 0)
        if storage.count > Self.capacity {
            storage.removeLast(storage.count - Self.capacity)
        }
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
    }

    /// Swaps in a better cleaned text for an existing entry (used when the
    /// background AI polish finishes after the entry was recorded).
    func updateCleanedText(id: UUID, to text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        if let index = storage.firstIndex(where: { $0.id == id }) {
            let e = storage[index]
            storage[index] = HistoryEntry(
                id: e.id, date: e.date, rawText: e.rawText,
                cleanedText: text, appBundleID: e.appBundleID,
                durationSeconds: e.durationSeconds
            )
        }
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        persist([])
    }

    // MARK: - Persistence

    static func defaultFileURL() -> URL {
        PersonalDictionary.applicationSupportDirectory().appendingPathComponent("history.json")
    }

    private func load() {
        ensureDirectoryExists()

        guard let data = try? Data(contentsOf: fileURL) else {
            storage = []
            return
        }
        guard let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            logger.error("history.json is missing or corrupt; starting with empty history.")
            storage = []
            return
        }
        storage = decoded
    }

    private func persist(_ snapshot: [HistoryEntry]) {
        ensureDirectoryExists()
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist history.json: \(error.localizedDescription, privacy: .public)")
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
}
