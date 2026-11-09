import Foundation
import Darwin
import Synchronization

/// Puts the macOS Dock and menu bar back if Clear Dock stops without doing it itself: a crash, or
/// being force quit. Without this they'd stay hidden (the Dock shrunk to nothing on the left) until
/// Clear Dock was opened and quit again.
///
/// The first time Clear Dock hides either, it starts a second copy of itself that does nothing but
/// wait for Clear Dock to end, without waking until then. A normal quit sends it away first, so
/// Clear Dock alone decides what happens then (like keeping the Dock hidden across a restart).
enum CrashGuard {
    private static let flag = "--guard"
    private static let running = Mutex<Process?>(nil)

    /// Starts the guard, once. Safe to call from any thread.
    static func start() {
        running.withLock { running in
            guard running == nil, let executable = Bundle.main.executableURL else { return }
            let process = Process()
            process.executableURL = executable
            process.arguments = [flag, String(getpid())]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                running = process
            } catch {
                NSLog("Clear Dock: could not start the crash guard: \(error)")
            }
        }
    }

    /// Clear Dock is quitting normally and sees to the Dock and menu bar itself.
    static func standDown() {
        running.withLock { running in
            guard let process = running else { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            running = nil
        }
    }

    /// The Clear Dock to watch over, when this copy was started as its guard.
    static func watchedApp(in arguments: [String]) -> pid_t? {
        guard arguments.count == 3, arguments[1] == flag else { return nil }
        return pid_t(arguments[2])
    }

    /// Waits for Clear Dock to end, then puts back whatever it left hidden. Never returns.
    static func watch(_ app: pid_t) -> Never {
        // Clear Dock ignores the usual request to stop (to quit cleanly instead), and a copy it
        // starts would inherit that: this one should just stop.
        signal(SIGTERM, SIG_DFL)
        let source = DispatchSource.makeProcessSource(identifier: app, eventMask: .exit, queue: .main)
        source.setEventHandler { putBack() }
        source.resume()
        // Already gone before the watching started: it's no longer this copy's parent.
        if getppid() != app { putBack() }
        dispatchMain()
    }

    private static func putBack() -> Never {
        // Read what Clear Dock noted down most recently, not anything from before it ended.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        SystemDock.restore()
        MainActor.assumeIsolated { SystemMenuBar.restore() }
        exit(0)
    }
}
