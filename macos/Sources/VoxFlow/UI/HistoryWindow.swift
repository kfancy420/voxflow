import AppKit
import SwiftUI
import Combine
import os

/// SwiftUI view listing past dictations from `HistoryStore.shared`. Hosted
/// inside an NSWindow by `WindowManager`.
struct HistoryView: View {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "HistoryWindow")

    @State private var entries: [HistoryEntry] = HistoryStore.shared.entries
    @State private var showingClearConfirm = false

    private let prefsChanged = NotificationCenter.default.publisher(for: .voxFlowPrefsChanged)

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Spacer()
                Text("No dictations yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(entries.count) item\(entries.count == 1 ? "" : "s") · expires after \(HistoryStore.shared.retentionDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear History") {
                    showingClearConfirm = true
                }
                .disabled(entries.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 400)
        .onAppear { refresh() }
        .onReceive(prefsChanged) { _ in refresh() }
        .alert("Clear History?", isPresented: $showingClearConfirm) {
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
        entries = HistoryStore.shared.entries
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    @State private var expanded = false
    @State private var showRaw = false
    @State private var copied = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

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
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Text(entry.cleanedText)
                .font(.body)
                .lineLimit(expanded ? nil : 3)
                .onTapGesture {
                    expanded.toggle()
                }

            DisclosureGroup(isExpanded: $showRaw) {
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
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                copied = false
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
