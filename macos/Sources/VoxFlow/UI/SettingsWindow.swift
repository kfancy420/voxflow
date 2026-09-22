import AppKit
import SwiftUI
import Combine
import AVFoundation
import ApplicationServices
import os

// View state lives in small ObservableObject holders rather than `@State`.
// On the macOS 26/27 SDKs `@State` is a macro whose plugin
// (libSwiftUIMacros.dylib) ships only inside Xcode, so a Mac with just the
// Command Line Tools — the documented one-command install — cannot compile
// it. `@ObservedObject` / `@Published` are plain property wrappers and build
// everywhere.

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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VoxFlow Settings"
            window.isReleasedWhenClosed = false
            window.center()
            let root = SettingsView(statusRelay: statusRelay)
            window.contentViewController = NSHostingController(rootView: root)
            window.contentMinSize = NSSize(width: 520, height: 460)
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
        .frame(minWidth: 520, minHeight: 460)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @MainActor
    private final class Model: ObservableObject {
        @Published var cleanupMode: CleanupMode = Preferences.shared.cleanupMode
        @Published var playSounds: Bool = Preferences.shared.playSounds
        @Published var insertTrailingSpace: Bool = Preferences.shared.insertTrailingSpace
        @Published var launchAtLogin: Bool = Preferences.shared.launchAtLogin
        @Published var historyRetentionHours: Int = Preferences.shared.historyRetentionHours

        @Published var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        @Published var accessibilityGranted: Bool = AXIsProcessTrusted()

        func reloadPreferences() {
            cleanupMode = Preferences.shared.cleanupMode
            playSounds = Preferences.shared.playSounds
            insertTrailingSpace = Preferences.shared.insertTrailingSpace
            launchAtLogin = Preferences.shared.launchAtLogin
            historyRetentionHours = Preferences.shared.historyRetentionHours
        }

        func reloadPermissions() {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    @ObservedObject private var model = Model()

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Cleanup mode", selection: $model.cleanupMode) {
                    Text("Off").tag(CleanupMode.off)
                    Text("Rules").tag(CleanupMode.rules)
                    Text("AI Polish").tag(CleanupMode.ai)
                }
                .onChange(of: model.cleanupMode) { _, newValue in
                    Preferences.shared.cleanupMode = newValue
                }

                Toggle("Play sounds", isOn: $model.playSounds)
                    .onChange(of: model.playSounds) { _, newValue in
                        Preferences.shared.playSounds = newValue
                    }

                Toggle("Insert trailing space", isOn: $model.insertTrailingSpace)
                    .onChange(of: model.insertTrailingSpace) { _, newValue in
                        Preferences.shared.insertTrailingSpace = newValue
                    }

                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _, newValue in
                        Preferences.shared.launchAtLogin = newValue
                    }
            }

            Section("History") {
                Picker("Keep dictations for", selection: $model.historyRetentionHours) {
                    Text("1 hour").tag(1)
                    Text("24 hours").tag(24)
                    Text("7 days").tag(168)
                    Text("30 days").tag(720)
                    Text("Forever (200-entry cap)").tag(0)
                }
                .onChange(of: model.historyRetentionHours) { _, newValue in
                    Preferences.shared.historyRetentionHours = newValue
                }
                Text("Everything you dictate is stored in plain text in History, so it expires by default. Expiry runs at launch, after each dictation, and when History is opened.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                HStack {
                    permissionDot(granted: model.micStatus == .authorized)
                    Text("Microphone")
                    Spacer()
                    Button("Open System Settings") {
                        openSystemSettings(pane: "Privacy_Microphone")
                    }
                }
                HStack {
                    permissionDot(granted: model.accessibilityGranted)
                    Text("Accessibility")
                    Spacer()
                    Button("Open System Settings") {
                        openSystemSettings(pane: "Privacy_Accessibility")
                    }
                }
            }
        }
        .onReceive(prefsChanged) { _ in
            model.reloadPreferences()
        }
        .onReceive(permissionTimer) { _ in
            model.reloadPermissions()
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
    @MainActor
    private final class Model: ObservableObject {
        @Published var modelChoice: WhisperModelChoice = Preferences.shared.modelChoice
    }

    @ObservedObject var statusRelay: StatusRelay
    @ObservedObject private var model = Model()

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)

    init(statusRelay: StatusRelay) {
        self.statusRelay = statusRelay
    }

    var body: some View {
        Form {
            Section {
                Picker("Whisper model", selection: $model.modelChoice) {
                    ForEach(WhisperModelChoice.allCases, id: \.self) { choice in
                        Text(choice.isDownloaded ? choice.displayName : choice.displayName + " — not downloaded").tag(choice)
                    }
                }
                .onChange(of: model.modelChoice) { _, newValue in
                    Preferences.shared.modelChoice = newValue
                }

                Text("Switching starts the download in the background; dictation stays on the current model until the new one is ready. Medium is the most accurate English model but takes a few times longer per take than Small on Apple Silicon; Large v3 Turbo is for non-English dictation.")
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
            model.modelChoice = Preferences.shared.modelChoice
        }
        .padding(.top, 8)
    }
}

// MARK: - Dictionary tab

private struct DictionarySettingsTab: View {
    @MainActor
    private final class Model: ObservableObject {
        @Published var entries: [DictionaryEntry] = PersonalDictionary.shared.entries
    }

    @ObservedObject private var model = Model()

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(model.entries) { entry in
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
        model.entries = PersonalDictionary.shared.entries
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onChange: (DictionaryEntry) -> Void
    let onDelete: () -> Void

    @MainActor
    private final class Model: ObservableObject {
        @Published var trigger: String
        @Published var replacement: String
        @Published var caseInsensitive: Bool

        init(entry: DictionaryEntry) {
            trigger = entry.trigger
            replacement = entry.replacement
            caseInsensitive = entry.caseInsensitive
        }
    }

    @ObservedObject private var model: Model

    init(entry: DictionaryEntry, onChange: @escaping (DictionaryEntry) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onChange = onChange
        self.onDelete = onDelete
        self.model = Model(entry: entry)
    }

    var body: some View {
        HStack {
            TextField("Trigger", text: $model.trigger)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)
                .onSubmit { commit() }

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)

            TextField("Replacement", text: $model.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .onSubmit { commit() }

            Toggle("Aa", isOn: $model.caseInsensitive)
                .toggleStyle(.checkbox)
                .help("Case-insensitive match")
                .onChange(of: model.caseInsensitive) { _, _ in commit() }

            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .onChange(of: model.trigger) { _, _ in commit() }
        .onChange(of: model.replacement) { _, _ in commit() }
    }

    private func commit() {
        var updated = entry
        updated.trigger = model.trigger
        updated.replacement = model.replacement
        updated.caseInsensitive = model.caseInsensitive
        if updated.trigger == entry.trigger,
           updated.replacement == entry.replacement,
           updated.caseInsensitive == entry.caseInsensitive {
            return
        }
        onChange(updated)
    }
}
