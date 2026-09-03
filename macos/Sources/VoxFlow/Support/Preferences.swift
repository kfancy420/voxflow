import Foundation
import ServiceManagement
import os

/// UserDefaults-backed app preferences. See Contracts.swift for the frozen
/// shape; every setter posts `.voxFlowPrefsChanged`.
final class Preferences {
    static let shared = Preferences()

    private enum Keys {
        static let cleanupMode = "cleanupMode"
        static let modelChoice = "modelChoice"
        static let playSounds = "playSounds"
        static let launchAtLogin = "launchAtLogin"
        static let insertTrailingSpace = "insertTrailingSpace"
        static let historyRetentionHours = "historyRetentionHours"
        static let autoStartConfigured = "autoStartConfigured"
    }

    /// Bundled LaunchAgent (Contents/Library/LaunchAgents/com.voxflow.app.plist).
    /// Unlike `SMAppService.mainApp`, an agent can carry `KeepAlive`, which is
    /// what relaunches VoxFlow after a crash.
    private static let agent = SMAppService.agent(plistName: "com.voxflow.app.plist")

    /// Default history retention, in hours (same as Windows).
    static let defaultHistoryRetentionHours = 24

    private let logger = Logger(subsystem: "com.voxflow.app", category: "Preferences")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.cleanupMode: CleanupMode.ai.rawValue,
            Keys.modelChoice: WhisperModelChoice.smallEn.rawValue,
            Keys.playSounds: true,
            Keys.insertTrailingSpace: true,
            Keys.historyRetentionHours: Self.defaultHistoryRetentionHours,
            Keys.autoStartConfigured: false
        ])
    }

    var cleanupMode: CleanupMode {
        get {
            let raw = defaults.string(forKey: Keys.cleanupMode) ?? CleanupMode.ai.rawValue
            return CleanupMode(rawValue: raw) ?? .ai
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.cleanupMode)
            postChange()
        }
    }

    var modelChoice: WhisperModelChoice {
        get {
            let raw = defaults.string(forKey: Keys.modelChoice) ?? WhisperModelChoice.smallEn.rawValue
            return WhisperModelChoice(rawValue: raw) ?? .smallEn
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.modelChoice)
            postChange()
        }
    }

    var playSounds: Bool {
        get { defaults.object(forKey: Keys.playSounds) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.playSounds)
            postChange()
        }
    }

    var insertTrailingSpace: Bool {
        get { defaults.object(forKey: Keys.insertTrailingSpace) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.insertTrailingSpace)
            postChange()
        }
    }

    /// How long dictation history is kept, in hours. Everything dictated is
    /// stored in plaintext, so it expires by default rather than
    /// accumulating. 0 keeps entries until the 200-entry cap evicts them.
    var historyRetentionHours: Int {
        get {
            guard defaults.object(forKey: Keys.historyRetentionHours) != nil else {
                return Self.defaultHistoryRetentionHours
            }
            return max(0, defaults.integer(forKey: Keys.historyRetentionHours))
        }
        set {
            defaults.set(max(0, newValue), forKey: Keys.historyRetentionHours)
            postChange()
        }
    }

    /// True once launch-at-login has been enabled automatically on first run.
    /// Later runs only correct a stale registration; if the user has turned
    /// it off deliberately, it stays off.
    var autoStartConfigured: Bool {
        get { defaults.bool(forKey: Keys.autoStartConfigured) }
        set { defaults.set(newValue, forKey: Keys.autoStartConfigured) }
    }

    /// Backed by the bundled LaunchAgent rather than UserDefaults directly —
    /// the system is the source of truth for whether the login item is
    /// actually registered.
    var launchAtLogin: Bool {
        get {
            Self.agent.status == .enabled
        }
        set {
            if newValue {
                // Migrate away from the plain login item earlier builds used.
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                do {
                    try Self.agent.register()
                    Log.info("Launch agent registered (status=\(Self.describe(Self.agent.status)))")
                } catch {
                    logger.error("Failed to register launch agent: \(error.localizedDescription, privacy: .public)")
                    Log.error("Failed to register launch agent", error)
                }
            } else {
                if Self.agent.status != .notRegistered {
                    do {
                        try Self.agent.unregister()
                        Log.info("Launch agent unregistered")
                    } catch {
                        logger.error("Failed to unregister launch agent: \(error.localizedDescription, privacy: .public)")
                        Log.warn("Failed to unregister launch agent: \(error.localizedDescription)")
                    }
                }
                if SMAppService.mainApp.status != .notRegistered {
                    try? SMAppService.mainApp.unregister()
                }
            }
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            postChange()
        }
    }

    /// Human-readable agent status for the log.
    static var launchAgentStatus: String { describe(agent.status) }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval (System Settings → General → Login Items)"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voxFlowPrefsChanged, object: nil)
        }
    }
}
