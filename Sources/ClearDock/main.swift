import AppKit

// Started by Clear Dock as its crash guard: wait for it to end, and nothing else.
if let app = CrashGuard.watchedApp(in: CommandLine.arguments) { CrashGuard.watch(app) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
