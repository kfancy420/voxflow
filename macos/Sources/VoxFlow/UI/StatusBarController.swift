import AppKit
import os

/// Owns the menu-bar (NSStatusItem) presence for VoxFlow: shows current
/// pipeline state via the icon, and exposes a menu for cleanup mode, model
/// choice, History/Settings windows, Launch at Login, and Quit.
///
/// Communicates with the rest of the app purely via `Preferences.shared`
/// (read/write) and NotificationCenter (`.voxFlowStateChanged`,
/// `.voxFlowPrefsChanged`) per SPEC.md — never references Transcriber,
/// AudioRecorder, HotkeyMonitor, TextInserter, or AppDelegate directly.
@MainActor
final class StatusBarController: NSObject {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "StatusBarController")

    private let statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let stateMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let modelStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

    private var cleanupMenuItems: [CleanupMode: NSMenuItem] = [:]
    private var modelMenuItems: [WhisperModelChoice: NSMenuItem] = [:]

    private var currentState: FlowState = .idle

    override init() {
        super.init()

        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)

        if let button = statusItem.button {
            button.image = Self.icon(for: .idle)
            button.imagePosition = .imageOnly
        }

        stateMenuItem.isEnabled = false
        modelStatusMenuItem.isEnabled = false
        modelStatusMenuItem.isHidden = true

        statusItem.menu = buildMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleStateChanged(_:)), name: .voxFlowStateChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePrefsChanged(_:)), name: .voxFlowPrefsChanged, object: nil)

        refreshCheckmarks()
        Self.logger.info("StatusBarController initialized")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API (SPEC)

    func update(state: FlowState) {
        currentState = state
        if let button = statusItem.button {
            button.image = Self.icon(for: state)
        }
        stateMenuItem.title = Self.stateTitle(for: state)
    }

    func update(modelState: String) {
        modelStatusMenuItem.title = modelState
        modelStatusMenuItem.isHidden = modelState.isEmpty
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        stateMenuItem.title = Self.stateTitle(for: currentState)
        menu.addItem(stateMenuItem)
        menu.addItem(modelStatusMenuItem)

        menu.addItem(.separator())

        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        let cleanupSubmenu = NSMenu(title: "Cleanup")
        for mode in CleanupMode.allCases {
            let item = NSMenuItem(
                title: Self.displayName(for: mode), action: #selector(selectCleanupMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            cleanupSubmenu.addItem(item)
            cleanupMenuItems[mode] = item
        }
        cleanupItem.submenu = cleanupSubmenu
        menu.addItem(cleanupItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu(title: "Model")
        for choice in WhisperModelChoice.allCases {
            let item = NSMenuItem(
                title: choice.displayName, action: #selector(selectModelChoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            modelSubmenu.addItem(item)
            modelMenuItems[choice] = item
        }
        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoxFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func selectCleanupMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CleanupMode(rawValue: raw) else { return }
        Preferences.shared.cleanupMode = mode
        NotificationCenter.default.post(name: .voxFlowPrefsChanged, object: nil)
        refreshCheckmarks()
    }

    @objc private func selectModelChoice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = WhisperModelChoice(rawValue: raw) else {
            return
        }
        Preferences.shared.modelChoice = choice
        NotificationCenter.default.post(name: .voxFlowPrefsChanged, object: nil)
        refreshCheckmarks()
    }

    @objc private func showHistory() {
        WindowManager.shared.showHistory()
    }

    @objc private func showSettings() {
        WindowManager.shared.showSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        Preferences.shared.launchAtLogin.toggle()
        NotificationCenter.default.post(name: .voxFlowPrefsChanged, object: nil)
        refreshCheckmarks()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Notification handlers

    @objc private func handleStateChanged(_ note: Notification) {
        guard let box = note.userInfo?["state"] as? StateBox else { return }
        update(state: box.state)
    }

    @objc private func handlePrefsChanged(_ note: Notification) {
        refreshCheckmarks()
    }

    // MARK: - Helpers

    private func refreshCheckmarks() {
        let mode = Preferences.shared.cleanupMode
        for (m, item) in cleanupMenuItems {
            item.state = (m == mode) ? .on : .off
        }
        let choice = Preferences.shared.modelChoice
        for (c, item) in modelMenuItems {
            item.state = (c == choice) ? .on : .off
        }
        launchAtLoginItem.state = Preferences.shared.launchAtLogin ? .on : .off
    }

    private static func displayName(for mode: CleanupMode) -> String {
        switch mode {
        case .off: return "Off"
        case .rules: return "Rules"
        case .ai: return "AI Polish"
        }
    }

    private static func stateTitle(for state: FlowState) -> String {
        switch state {
        case .idle: return "Idle"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Polishing…"
        case .inserting: return "Inserting…"
        case .error(let message): return "Error: \(message)"
        }
    }

    private static func icon(for state: FlowState) -> NSImage? {
        let (symbolName, description): (String, String) = {
            switch state {
            case .idle: return ("mic", "VoxFlow — Idle")
            case .recording: return ("mic.fill", "VoxFlow — Recording")
            case .transcribing, .cleaning, .inserting: return ("waveform", "VoxFlow — Working")
            case .error: return ("exclamationmark.triangle", "VoxFlow — Error")
            }
        }()
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }
}
