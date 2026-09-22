import AppKit
import SwiftUI
import Combine
import os

// View state lives in small ObservableObject holders rather than `@State`.
// On the macOS 26/27 SDKs `@State` is a macro whose plugin
// (libSwiftUIMacros.dylib) ships only inside Xcode, so a Mac with just the
// Command Line Tools — the documented one-command install — cannot compile
// it. `@ObservedObject` / `@Published` are plain property wrappers and build
// everywhere.

/// SwiftUI view listing past dictations from `HistoryStore.shared`. Hosted
/// inside an NSWindow by `WindowManager`.
struct HistoryView: View {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "HistoryWindow")

    @MainActor
    private final class Model: ObservableObject {
        @Published var entries: [HistoryEntry] = HistoryStore.shared.entries
        @Published var showingClearConfirm = false
    }

    @ObservedObject private var model = Model()

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                Spacer()
                Text("No dictations yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(model.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(model.entries.count) item\(model.entries.count == 1 ? "" : "s") · expires after \(HistoryStore.shared.retentionDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear History") {
                    model.showingClearConfirm = true
                }
                .disabled(model.entries.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 400)
        .onAppear { refresh() }
        .onReceive(prefsChanged) { _ in refresh() }
        .alert("Clear History?", isPresented: $model.showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                HistoryStore.shared.clear()
                refresh()
            }
        } message: {
            Text("This removes all saved dictations. This cannot be undone.")
        }
    }

    private func refresh() {
        model.entries = HistoryStore.shared.entries
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    @MainActor
    private final class Model: ObservableObject {
        @Published var expanded = false
        @Published var showRaw = false
        @Published var copied = false
    }

    @ObservedObject private var model = Model()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(entry: HistoryEntry) {
        self.entry = entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("·")
                    .foregroundColor(.secondary)

                Text(appDisplayName(for: entry.appBundleID))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    copy()
                } label: {
                    Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Text(entry.cleanedText)
                .font(.body)
                .lineLimit(model.expanded ? nil : 3)
                .onTapGesture {
                    model.expanded.toggle()
                }

            DisclosureGroup(isExpanded: $model.showRaw) {
                Text(entry.rawText)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            } label: {
                Text("Raw transcript")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.cleanedText, forType: .string)
        model.copied = true
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                model.copied = false
            }
        }
    }

    private func appDisplayName(for bundleID: String?) -> String {
        guard let bundleID else { return "Unknown app" }
        if bundleID == "recovered" { return "Recovered after restart" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        let trimmed = (name as NSString).deletingPathExtension
        return trimmed.isEmpty ? bundleID : trimmed
    }
}
