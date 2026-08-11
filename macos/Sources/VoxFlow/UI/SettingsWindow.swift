import AppKit
import SwiftUI
import Combine
import AVFoundation
import ApplicationServices
import os

// MARK: - WindowManager

/// Lazily creates and shows the Settings and History windows. Windows are
/// never released on close so their SwiftUI state (and scroll positions,
/// tab selection, etc.) survives across show/hide cycles.
@MainActor
final class WindowManager {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "WindowManager")

    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private init() {}

    /// Read-only-ish status relay so Settings' Model tab can display an
    /// externally-driven status string without VoxFlow's UI layer knowing
    /// about Transcriber directly.
    let statusRelay = StatusRelay()

    /// Lets the app layer report model load/download progress into Settings
    /// without SettingsWindow needing to know about Transcriber.
    func setModelStatus(_ text: String) {
        statusRelay.modelStatus = text
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VoxFlow Settings"
            window.isReleasedWhenClosed = false
            window.center()
            let root = SettingsView(statusRelay: statusRelay)
            window.contentViewController = NSHostingController(rootView: root)
            window.contentMinSize = NSSize(width: 480, height: 360)
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VoxFlow History"
            window.isReleasedWhenClosed = false
            window.center()
            let root = HistoryView()
            window.contentViewController = NSHostingController(rootView: root)
            window.contentMinSize = NSSize(width: 460, height: 400)
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Simple observable relay used to surface a free-text model status (e.g.
/// "Downloading model… 43%") into the Settings window's Model tab.
@MainActor
final class StatusRelay: ObservableObject {
    @Published var modelStatus: String = ""
}

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var statusRelay: StatusRelay

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Text("General") }

            ModelSettingsTab(statusRelay: statusRelay)
                .tabItem { Text("Model") }

            DictionarySettingsTab()
                .tabItem { Text("Dictionary") }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @State private var cleanupMode: CleanupMode = Preferences.shared.cleanupMode
    @State private var playSounds: Bool = Preferences.shared.playSounds
    @State private var insertTrailingSpace: Bool = Preferences.shared.insertTrailingSpace
    @State private var launchAtLogin: Bool = Preferences.shared.launchAtLogin

    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Cleanup mode", selection: $cleanupMode) {
                    Text("Off").tag(CleanupMode.off)
                    Text("Rules").tag(CleanupMode.rules)
                    Text("AI Polish").tag(CleanupMode.ai)
                }
                .onChange(of: cleanupMode) { _, newValue in
                    Preferences.shared.cleanupMode = newValue
                }

                Toggle("Play sounds", isOn: $playSounds)
                    .onChange(of: playSounds) { _, newValue in
                        Preferences.shared.playSounds = newValue
                    }

                Toggle("Insert trailing space", isOn: $insertTrailingSpace)
                    .onChange(of: insertTrailingSpace) { _, newValue in
                        Preferences.shared.insertTrailingSpace = newValue
                    }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        Preferences.shared.launchAtLogin = newValue
                    }
            }

            Section("Permissions") {
                HStack {
                    permissionDot(granted: micStatus == .authorized)
                    Text("Microphone")
                    Spacer()
                    Button("Open System Settings") {
                        openSystemSettings(pane: "Privacy_Microphone")
                    }
                }
                HStack {
                    permissionDot(granted: accessibilityGranted)
                    Text("Accessibility")
                    Spacer()
                    Button("Open System Settings") {
                        openSystemSettings(pane: "Privacy_Accessibility")
                    }
                }
            }
        }
        .onReceive(prefsChanged) { _ in
            cleanupMode = Preferences.shared.cleanupMode
            playSounds = Preferences.shared.playSounds
            insertTrailingSpace = Preferences.shared.insertTrailingSpace
            launchAtLogin = Preferences.shared.launchAtLogin
        }
        .onReceive(permissionTimer) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityGranted = AXIsProcessTrusted()
        }
        .padding(.top, 8)
    }

    private func permissionDot(granted: Bool) -> some View {
        Circle()
            .fill(granted ? Color.green : Color.red)
            .frame(width: 8, height: 8)
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Model tab

private struct ModelSettingsTab: View {
    @ObservedObject var statusRelay: StatusRelay
    @State private var modelChoice: WhisperModelChoice = Preferences.shared.modelChoice

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)

    var body: some View {
        Form {
            Section {
                Picker("Whisper model", selection: $modelChoice) {
                    ForEach(WhisperModelChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .onChange(of: modelChoice) { _, newValue in
                    Preferences.shared.modelChoice = newValue
                }

                Text("Changing the model triggers a download the next time you dictate, if it hasn't been fetched yet.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Status") {
                Text(statusRelay.modelStatus.isEmpty ? "Ready" : statusRelay.modelStatus)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .onReceive(prefsChanged) { _ in
            modelChoice = Preferences.shared.modelChoice
        }
        .padding(.top, 8)
    }
}

// MARK: - Dictionary tab

private struct DictionarySettingsTab: View {
    @State private var entries: [DictionaryEntry] = PersonalDictionary.shared.entries

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(entries) { entry in
                    DictionaryRow(
                        entry: entry,
                        onChange: { updated in
                            PersonalDictionary.shared.update(updated)
                            refresh()
                        },
                        onDelete: {
                            PersonalDictionary.shared.remove(id: entry.id)
                            refresh()
                        }
                    )
                }
            }
            .listStyle(.inset)

            HStack {
                Button {
                    let entry = DictionaryEntry(trigger: "", replacement: "", caseInsensitive: true)
                    PersonalDictionary.shared.add(entry)
                    refresh()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add entry")

                Spacer()
            }
        }
        .onAppear { refresh() }
        .onReceive(prefsChanged) { _ in refresh() }
        .padding(.top, 8)
    }

    private func refresh() {
        entries = PersonalDictionary.shared.entries
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onChange: (DictionaryEntry) -> Void
    let onDelete: () -> Void

    @State private var trigger: String
    @State private var replacement: String
    @State private var caseInsensitive: Bool

    init(entry: DictionaryEntry, onChange: @escaping (DictionaryEntry) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onChange = onChange
        self.onDelete = onDelete
        _trigger = State(initialValue: entry.trigger)
        _replacement = State(initialValue: entry.replacement)
        _caseInsensitive = State(initialValue: entry.caseInsensitive)
    }

    var body: some View {
        HStack {
            TextField("Trigger", text: $trigger)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)
                .onSubmit { commit() }

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)

            TextField("Replacement", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .onSubmit { commit() }

            Toggle("Aa", isOn: $caseInsensitive)
                .toggleStyle(.checkbox)
                .help("Case-insensitive match")
                .onChange(of: caseInsensitive) { _, _ in commit() }

            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .onChange(of: trigger) { _, _ in commit() }
        .onChange(of: replacement) { _, _ in commit() }
    }

    private func commit() {
        var updated = entry
        updated.trigger = trigger
        updated.replacement = replacement
        updated.caseInsensitive = caseInsensitive
        onChange(updated)
    }
}
