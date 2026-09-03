import AppKit
import Foundation

/// Process-level plumbing that keeps exactly one VoxFlow alive: the
/// single-instance rule, the self-restart used when the speech engine hangs,
/// and the hand-over to the launchd-managed copy that provides crash
/// recovery (see `Resources/com.voxflow.app.plist`).
///
/// launchd relaunches the agent after any unsuccessful exit (`KeepAlive` →
/// `SuccessfulExit: false`), which is the macOS equivalent of Windows'
/// `RegisterApplicationRestart`. A clean quit from the menu exits 0 and stays
/// down.
enum ProcessLifecycle {
    static let bundleID = "com.voxflow.app"
    static let restartedFlag = "--restarted-after-crash"
    /// Set by the bundled LaunchAgent plist so a launchd-started instance can
    /// recognise itself and take over from a manually-launched one.
    static let launchdEnvKey = "VOXFLOW_LAUNCHD"

    static var isLaunchdManaged: Bool {
        ProcessInfo.processInfo.environment[launchdEnvKey] == "1"
    }

    static var wasRestartedAfterCrash: Bool {
        CommandLine.arguments.contains(restartedFlag)
    }

    /// Where the bundled LaunchAgent expects the app to live.
    static let installedBundlePath = "/Applications/VoxFlow.app"

    /// True when running from the installed `.app` bundle (as opposed to the
    /// bare SwiftPM binary during development, or a build/ copy). The
    /// LaunchAgent carries this path, so only this location may register it.
    static var isInstalledBundle: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == installedBundlePath
    }

    /// `--register-agent` / `--unregister-agent`: lets install.sh retire the
    /// previous build's registration before replacing the bundle (Background
    /// Task Management caches the plist it was registered with) and re-arm it
    /// after. Returns nil when the arguments are not one of these.
    static func runAgentCommand(arguments: [String]) -> Int32? {
        guard arguments.count > 1 else { return nil }
        switch arguments[1] {
        case "--register-agent":
            guard isInstalledBundle else {
                print("VoxFlow: --register-agent only works from \(installedBundlePath)")
                return 1
            }
            Preferences.shared.launchAtLogin = true
            Preferences.shared.autoStartConfigured = true
            print("VoxFlow: launch agent \(Preferences.launchAgentStatus)")
            return 0
        case "--unregister-agent":
            // Reports the prior state so install.sh can restore the user's
            // choice afterwards rather than forcing launch-at-login back on.
            let wasEnabled = Preferences.shared.launchAtLogin
            Preferences.shared.launchAtLogin = false
            print(wasEnabled ? "was-enabled" : "was-disabled")
            return 0
        default:
            return nil
        }
    }

    /// Enforces the single-instance rule. Returns normally when this process
    /// should carry on; exits the process otherwise.
    ///
    /// Precedence: a launchd-managed instance always wins (it is the one with
    /// crash recovery) and asks the others to quit; an instance relaunched
    /// after a fault waits for the dying one to go; any other duplicate — a
    /// second double-click on the app — yields to whatever is already running.
    static func enforceSingleInstance() {
        var others = otherInstances()
        guard !others.isEmpty else { return }

        if isLaunchdManaged {
            Log.info("launchd-managed instance taking over from \(others.count) running copy/copies")
            for app in others { _ = app.terminate() }
            let deadline = Date().addingTimeInterval(15)
            while !others.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                others = otherInstances()
            }
            for app in others {
                Log.warn("Copy pid \(app.processIdentifier) ignored terminate — forcing")
                _ = app.forceTerminate()
            }
            return
        }

        if wasRestartedAfterCrash {
            // The previous process may still be tearing down (a stuck native
            // call is abandoned, not unwound); give it a while.
            let deadline = Date().addingTimeInterval(60)
            while !others.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                others = otherInstances()
            }
            if others.isEmpty {
                Log.info("Relaunched after a fault; previous instance is gone")
                return
            }
        }

        Log.info("Another instance is already running (pid \(others.map { String($0.processIdentifier) }.joined(separator: ","))) — exiting")
        exit(0)
    }

    private static func otherInstances() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// A native call that never returns cannot be unwound, so the only clean
    /// recovery is a fresh process. Under launchd, exiting unsuccessfully is
    /// enough — it relaunches us. Otherwise spawn the replacement ourselves.
    /// `_exit` rather than `exit`: the stuck thread must not get a chance to
    /// block process teardown.
    static func restartSelf(reason: String) -> Never {
        Log.info("Restarting VoxFlow: \(reason)")
        if !isLaunchdManaged, Bundle.main.bundleURL.pathExtension == "app" {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", "-a", Bundle.main.bundleURL.path, "--args", restartedFlag]
            do {
                try open.run()
            } catch {
                Log.error("Could not relaunch VoxFlow", error)
            }
        }
        _exit(1)
    }

    /// Asks launchd to start the registered agent now. If the job is loaded
    /// (normal after login) `kickstart` does it; if it was booted out (as
    /// `install.sh` does before replacing the bundle) re-registering
    /// bootstraps it again. Either way a managed copy starts and takes over
    /// from this one. Best effort: on failure this copy simply carries on
    /// unmanaged until the next login.
    static func kickstartManagedCopy() {
        let target = "gui/\(getuid())/\(bundleID)"
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", target]
        kick.standardOutput = FileHandle.nullDevice
        kick.standardError = FileHandle.nullDevice
        do {
            try kick.run()
            kick.waitUntilExit()
            if kick.terminationStatus == 0 {
                Log.info("Asked launchd to start the managed copy (\(target))")
                return
            }
            Log.info("launchd job \(target) not loaded (kickstart status \(kick.terminationStatus)); re-registering the agent")
        } catch {
            Log.warn("Could not run launchctl: \(error.localizedDescription)")
            return
        }
        // Re-register so launchd bootstraps the agent (RunAtLoad starts it).
        let prefs = Preferences.shared
        prefs.launchAtLogin = false
        prefs.launchAtLogin = true
    }

    /// Earlier installs were kept alive by a hand-written LaunchAgent at
    /// `~/Library/LaunchAgents/com.voxflow.app.plist`. It carries the same
    /// label as the bundled agent and would fight it, so retire the file.
    /// The job it loaded (possibly this very process) is left running —
    /// `install.sh` boots it out; otherwise it lapses at next login.
    static func retireLegacyLaunchAgent() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacy)
            Log.info("Removed legacy LaunchAgent plist at \(legacy.path); the bundled agent replaces it")
        } catch {
            Log.warn("Could not remove legacy LaunchAgent plist: \(error.localizedDescription)")
        }
    }
}
