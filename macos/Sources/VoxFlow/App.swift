import AppKit

// VoxFlow — native macOS dictation. Menu-bar only (no Dock icon).
// @main + @MainActor gives the entry point main-actor isolation, so the
// @MainActor AppDelegate can be constructed here (top-level code in a
// main.swift is nonisolated and cannot).
@main
@MainActor
struct VoxFlowApp {
    private static var delegate: AppDelegate?

    static func main() {
        // Headless checks run without the UI and skip the single-instance
        // rule, so they can be run against a Mac where VoxFlow is resident.
        if let code = SelfTest.run(arguments: CommandLine.arguments) {
            exit(code)
        }
        if let code = ProcessLifecycle.runAgentCommand(arguments: CommandLine.arguments) {
            exit(code)
        }

        ProcessLifecycle.enforceSingleInstance()

        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d          // NSApplication.delegate is unretained; keep a strong ref.
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
