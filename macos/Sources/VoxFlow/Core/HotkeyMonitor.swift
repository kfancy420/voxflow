import AppKit
import CoreGraphics
import os

/// Watches for hold/release of the RIGHT ⌘ key anywhere on the system via a
/// CGEvent tap, and reports press/release via `onPress` / `onRelease`.
///
/// Implementation notes (see SPEC.md):
/// - Listens on `.flagsChanged` events only, via a `.listenOnly` tap so we
///   never intercept or block system event delivery.
/// - Right ⌘ is identified by keycode 54 (`.keyboardEventKeycode`), not by
///   `.maskCommand` alone (that would also fire for left ⌘).
/// - A press that resolves to a release in under 0.15s and produced no audio
///   is treated as a debounce case by the caller (AppDelegate); this class
///   simply reports raw press/release edges.
@MainActor
final class HotkeyMonitor {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "HotkeyMonitor")

    /// Right-⌘ virtual keycode.
    private static let rightCommandKeycode: Int64 = 54

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired on any real user keystroke or mouse click (never for events
    /// VoxFlow itself synthesizes). Used to know when replacing already-
    /// inserted text is no longer safe.
    var onUserActivity: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightCommandDown = false

    /// True while an event tap is installed.
    var isRunning: Bool { eventTap != nil }

    init() {}

    // Note: deinit intentionally does not call `stop()` — this type is
    // @MainActor-isolated, and deinit runs in a nonisolated context, so it
    // cannot safely touch actor-isolated state. Callers must call `stop()`
    // explicitly before releasing their last reference.

    /// Starts the CGEvent tap. Returns false if the tap could not be created
    /// (most commonly because the app lacks Accessibility / Input Monitoring
    /// permission).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    // The tap's run loop source is added to the main run loop
                    // (see `start()`), so this callback always fires on the
                    // main thread even though the C function pointer itself is
                    // a nonisolated context from the compiler's point of view.
                    MainActor.assumeIsolated {
                        monitor.handle(type: type, event: event)
                    }
                }
                // Listen-only tap: the return value is ignored by the system,
                // so hand back the event unretained (passRetained would leak
                // a reference for every event we see).
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Self.logger.error("Failed to create CGEvent tap — missing Accessibility/Input Monitoring permission?")
            return false
        }

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Self.logger.error("Failed to create run loop source for event tap")
            eventTap = nil
            return false
        }
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Self.logger.notice("HotkeyMonitor started; tap created successfully")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isRightCommandDown = false
        Self.logger.info("HotkeyMonitor stopped")
    }

    /// Called synchronously from the CGEvent tap callback (which runs on the
    /// main run loop, since we added the source to `CFRunLoopGetMain()`).
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
            Self.logger.notice("Event tap disabled (\(reason, privacy: .public)); re-enabling")
            Log.warn("Event tap disabled (\(reason)); re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // We may have missed the key-up while the tap was dead; end any
            // in-flight press so a recording can't get stuck on.
            if isRightCommandDown {
                isRightCommandDown = false
                onRelease?()
            }
            return
        }

        if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // Real user activity — but ignore events VoxFlow itself posted
            // (⌘V / ⇧← synthesis is stamped with a marker).
            if event.getIntegerValueField(.eventSourceUserData) != TextInserter.syntheticEventUserData {
                onUserActivity?()
            }
            return
        }

        guard type == .flagsChanged else { return }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        Self.logger.notice("flagsChanged: keycode=\(keycode, privacy: .public) flags=\(String(event.flags.rawValue), privacy: .public)")
        guard keycode == Self.rightCommandKeycode else { return }

        let flags = event.flags
        let commandHeld = flags.contains(.maskCommand)
        let otherModifiersHeld = flags.contains(.maskShift)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)

        if commandHeld && !isRightCommandDown {
            // Rising edge: right ⌘ just went down.
            if otherModifiersHeld {
                // Some other modifier is already held (e.g. this flagsChanged
                // event coincides with ⌘-something) — ignore so combos like
                // ⌘C never trigger dictation.
                return
            }
            isRightCommandDown = true
            Self.logger.notice("Right ⌘ pressed — starting dictation")
            onPress?()
        } else if !commandHeld && isRightCommandDown {
            // Falling edge: right ⌘ was released.
            isRightCommandDown = false
            Self.logger.notice("Right ⌘ released — ending dictation")
            onRelease?()
        }
    }
}
