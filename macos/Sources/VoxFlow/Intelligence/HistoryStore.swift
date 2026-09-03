import Foundation
import os

/// Persisted log of completed dictations, newest first. Bounded two ways: by
/// age (`retentionHours`, 24 h by default) and by count (200).
///
/// The age bound is the one that matters. Everything dictated goes through
/// here in plaintext — messages, invoices, client details — so it should not
/// accumulate on disk indefinitely just because the entry count stayed under
/// a cap.
///
/// Expiry is event-driven: enforced at startup, on every write, and whenever
/// the entries are read (the History window). There is no background sweep,
/// so on a Mac left running and unused an expired entry survives on disk
/// until one of those happens. Same policy as the Windows build.
final class HistoryStore {
    static let shared = HistoryStore()

    private static let capacity = 200

    private let logger = Logger(subsystem: "com.voxflow.app", category: "HistoryStore")
    private let lock = NSLock()
    private let fileURL: URL
    private var storage: [HistoryEntry] = []

    /// Hours to keep dictations for. Zero disables time-based expiry and
    /// falls back to the count cap alone. Set from Preferences at startup.
    var retentionHours: Int = Preferences.defaultHistoryRetentionHours

    /// Entries newest first — pruned first, so what the user reads is never
    /// staler than the retention policy claims.
    var entries: [HistoryEntry] {
        prune()
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Number of entries currently retained (after pruning).
    var count: Int { entries.count }

    init(fileURL: URL = HistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func add(_ entry: HistoryEntry) {
        guard !entry.cleanedText.isEmpty else { return }

        lock.lock()
        storage.insert(entry, at: 0)
        storage = trim(storage)
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

    /// Drops expired entries. Returns how many were removed.
    @discardableResult
    func prune() -> Int {
        lock.lock()
        let before = storage.count
        let kept = trim(storage)
        let removed = before - kept.count
        if removed > 0 { storage = kept }
        let snapshot = storage
        lock.unlock()
        if removed > 0 {
            persist(snapshot)
            Log.info("History pruned: \(removed) expired, \(kept.count) kept (retention \(retentionHours) h)")
        }
        return removed
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        persist([])
        Log.info("History cleared")
    }

    /// "24 hours", "7 days", "no time limit (200-entry cap only)".
    var retentionDescription: String {
        Self.describeRetention(hours: retentionHours)
    }

    static func describeRetention(hours: Int) -> String {
        if hours <= 0 { return "no time limit (200-entry cap only)" }
        if hours % 24 == 0 {
            let days = hours / 24
            return days == 1 ? "24 hours" : "\(days) days"
        }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    // MARK: - Persistence

    static func defaultFileURL() -> URL {
        PersonalDictionary.applicationSupportDirectory().appendingPathComponent("history.json")
    }

    private func trim(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var kept = entries
        if retentionHours > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionHours) * 3600)
            kept = kept.filter { $0.date >= cutoff }
        }
        if kept.count > Self.capacity {
            kept.removeLast(kept.count - Self.capacity)
        }
        return kept
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
