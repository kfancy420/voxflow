import AppKit
import CoreGraphics
import os

/// Inserts transcribed text into whatever app currently has focus by
/// round-tripping through the system pasteboard and synthesizing ⌘V.
@MainActor
final class TextInserter {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "TextInserter")

    /// Virtual keycode for "v".
    private static let vKeycode: CGKeyCode = 9
    /// Virtual keycode for left arrow.
    private static let leftArrowKeycode: CGKeyCode = 123
    private static let restoreDelay: TimeInterval = 0.6

    /// Marker stamped on every event we synthesize, so HotkeyMonitor can tell
    /// our own keystrokes apart from real user activity. ("VOX" in hex.)
    static let syntheticEventUserData: Int64 = 0x564F58

    /// Snapshot of everything on the pasteboard prior to insertion, so it
    /// can be restored afterwards.
    private struct SavedPasteboardState {
        let itemStrings: [[NSPasteboard.PasteboardType: String]]
    }

    /// The user's pasteboard contents from before the *first* insertion of a
    /// burst, plus the pending restore job, so back-to-back dictations can't
    /// leave dictated text on the clipboard.
    private var savedPasteboard: SavedPasteboardState?
    private var pendingRestore: DispatchWorkItem?

    init() {}

    /// Saves the pasteboard, writes `text` (optionally with a trailing
    /// space), synthesizes ⌘V into the frontmost app, then restores the
    /// prior pasteboard contents ~0.6s later.
    /// Returns the exact string that was inserted (including any trailing
    /// space) so callers can later replace it in place.
    @discardableResult
    func insert(_ text: String) -> String {
        var finalText = text
        let appendTrailingSpace = (UserDefaults.standard.object(forKey: "insertTrailingSpace") as? Bool) ?? true
        if appendTrailingSpace {
            finalText += " "
        }
        pasteViaClipboard(finalText)
        return finalText
    }

    /// Replaces the last `count` characters before the cursor with `text` by
    /// synthesizing ⇧← `count` times (selecting backwards) and pasting over
    /// the selection. Only safe when the caller has verified the cursor
    /// hasn't moved since the original insertion.
    func replaceLast(_ count: Int, with text: String) {
        guard count > 0 else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Self.logger.error("Failed to create CGEventSource for selection synthesis")
            return
        }
        for _ in 0..<count {
            Self.postKey(Self.leftArrowKeycode, flags: .maskShift, source: source)
        }
        // Give the target app a moment to settle the selection.
        usleep(30_000)
        pasteViaClipboard(text)
    }

    private func pasteViaClipboard(_ finalText: String) {
        let pasteboard = NSPasteboard.general

        // Only snapshot when there is no restore still in flight — otherwise
        // we would "save" the text we ourselves just pasted.
        if pendingRestore == nil {
            savedPasteboard = Self.captureContents(of: pasteboard)
        }
        pendingRestore?.cancel()
        pendingRestore = nil

        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(finalText, forType: .string)

        synthesizePaste()

        let work = DispatchWorkItem {
            // asyncAfter blocks are nonisolated as far as the compiler is
            // concerned; this always runs on the main queue.
            MainActor.assumeIsolated {
                if let saved = self.savedPasteboard {
                    Self.restore(saved, to: NSPasteboard.general)
                }
                self.savedPasteboard = nil
                self.pendingRestore = nil
            }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    /// Bundle ID of the frontmost app (for app-aware cleanup + history).
    static func frontmostAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Pasteboard save/restore

    private static func captureContents(of pasteboard: NSPasteboard) -> SavedPasteboardState {
        let itemStrings: [[NSPasteboard.PasteboardType: String]] = (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: String] = [:]
            for type in item.types {
                if let value = item.string(forType: type) {
                    dict[type] = value
                }
            }
            return dict
        }
        return SavedPasteboardState(itemStrings: itemStrings)
    }

    private static func restore(_ saved: SavedPasteboardState, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.itemStrings.isEmpty else { return }

        let items: [NSPasteboardItem] = saved.itemStrings.map { dict in
            let item = NSPasteboardItem()
            for (type, value) in dict {
                item.setString(value, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Keystroke synthesis

    private func synthesizePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Self.logger.error("Failed to create CGEventSource for ⌘V synthesis")
            return
        }
        Self.postKey(Self.vKeycode, flags: .maskCommand, source: source)
    }

    private static func postKey(_ keycode: CGKeyCode, flags: CGEventFlags, source: CGEventSource) {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) else {
            Self.logger.error("Failed to create CGEvent for key synthesis")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        keyDown.post(tap: .cghidEventTap)
        usleep(3_000)
        keyUp.post(tap: .cghidEventTap)
        usleep(3_000)
    }
}
