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
    }

    private let logger = Logger(subsystem: "com.voxflow.app", category: "Preferences")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.cleanupMode: CleanupMode.ai.rawValue,
            Keys.modelChoice: WhisperModelChoice.smallEn.rawValue,
            Keys.playSounds: true,
            Keys.insertTrailingSpace: true
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

    /// Backed by `SMAppService.mainApp` rather than UserDefaults directly —
    /// the system is the source of truth for whether the login item is
    /// actually registered.
    var launchAtLogin: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            if newValue {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    logger.error("Failed to register launch-at-login: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                do {
                    try SMAppService.mainApp.unregister()
                } catch {
                    logger.error("Failed to unregister launch-at-login: \(error.localizedDescription, privacy: .public)")
                }
            }
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            postChange()
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voxFlowPrefsChanged, object: nil)
        }
    }
}
