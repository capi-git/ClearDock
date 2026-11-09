import Foundation
import Darwin
import Synchronization

/// Puts the macOS Dock and menu bar back if Clear Dock stops without doing it itself: a crash, or
/// being force quit. Without this they'd stay hidden (the Dock shrunk to nothing on the left) until
/// Clear Dock was opened and quit again.
///
/// The first time Clear Dock hides either, it starts a second copy of itself that does nothing but
/// wait for Clear Dock to end, without waking until then. A normal quit puts everything back
/// itself and then sends the guard away.
enum CrashGuard {
    private static let flag = "--guard"

    private struct State {
        var process: Process?
        /// A guard should be running: from the first hiding until Clear Dock quits.
        var wanted = false
        /// How many times a guard that stopped on its own has been replaced.
        var restarts = 0
    }
    private static let state = Mutex(State())

    /// The Clear Dock (by process number) that what's hidden now belongs to.
    private static let ownerKey = "guardOwner"
    /// When Clear Dock last quit for a restart or log out, leaving the Dock and menu bar hidden.
    private static let leftKey = "guardLeftForRestart"
    /// How long after that the guard puts them back, if the Mac is still up: the restart was called off.
    private static let restartWait: TimeInterval = 60

    // MARK: In Clear Dock

    /// First thing as Clear Dock opens, before it hides anything: what's hidden is this one's now.
    /// A guard still putting things back after the last Clear Dock (it had crashed a moment ago)
    /// is waited for, so it can't undo what this one is about to hide, or forget what this one notes.
    static func takeOver() {
        let lock = openLock()
        if lock >= 0 {
            // Not for ever: a guard held up (System Events not answering) shouldn't hold this up too.
            var tries = 0
            while flock(lock, LOCK_EX | LOCK_NB) != 0, tries < 100 {
                usleep(50_000)
                tries += 1
            }
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let defaults = UserDefaults.standard
        defaults.set(Int(getpid()), forKey: ownerKey)
        defaults.removeObject(forKey: leftKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        if lock >= 0 {
            flock(lock, LOCK_UN)
            close(lock)
        }
    }

    /// Starts the guard, once. Safe to call from any thread.
    static func start() {
        state.withLock { state in
            state.wanted = true
            launch(&state)
        }
    }

    private static func launch(_ state: inout State) {
        guard state.process == nil, state.wanted, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [flag, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { ended in guardEnded(ended) }
        do {
            try process.run()
            state.process = process
        } catch {
            NSLog("Clear Dock: could not start the crash guard: \(error)")
        }
    }

    /// The guard stopped though Clear Dock didn't send it away (it shows as a second "ClearDock" in
    /// Activity Monitor, where it may get force quit): another takes its place, a few times at most.
    private static func guardEnded(_ ended: Process) {
        let again = state.withLock { state -> Bool in
            guard state.process === ended else { return false }
            state.process = nil
            guard state.wanted, state.restarts < 5 else { return false }
            state.restarts += 1
            return true
        }
        guard again else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            state.withLock { launch(&$0) }
        }
    }

    /// Clear Dock has put the Dock and menu bar back itself, and is quitting.
    static func standDown() {
        state.withLock { state in
            state.wanted = false
            guard let process = state.process else { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            state.process = nil
        }
    }

    /// Clear Dock is quitting for a restart or log out and leaves the Dock and menu bar hidden, to
    /// open again at login. The guard stays, and is stopped with everything else. If the Mac is
    /// still up a minute later (another app called the restart off), it puts them back.
    static func leaveForRestart() {
        state.withLock { $0.wanted = false }
        UserDefaults.standard.set(Date(), forKey: leftKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    // MARK: In the guard

    /// The Clear Dock to watch over, when this copy was started as its guard.
    static func watchedApp(in arguments: [String]) -> pid_t? {
        guard arguments.count == 3, arguments[1] == flag else { return nil }
        return pid_t(arguments[2])
    }

    private static let ended = Mutex(false)

    /// Waits for Clear Dock to end, then puts back whatever it left hidden. Never returns.
    static func watch(_ app: pid_t) -> Never {
        // Clear Dock ignores the usual request to stop (to quit cleanly instead), and a copy it
        // starts would inherit that: this one should just stop.
        signal(SIGTERM, SIG_DFL)
        // Which settings are Clear Dock's is found out now, while its app is where it was started from.
        _ = UserDefaults.standard.object(forKey: ownerKey)
        let source = DispatchSource.makeProcessSource(identifier: app, eventMask: .exit, queue: .main)
        source.setEventHandler { appEnded(app) }
        source.resume()
        // Already gone before the watching started: it's no longer this copy's parent.
        if getppid() != app { appEnded(app) }
        dispatchMain()
    }

    private static func appEnded(_ app: pid_t) {
        // Once, whichever way it was noticed.
        guard ended.withLock({ ended -> Bool in
            defer { ended = true }
            return !ended
        }) else { return }
        // Read what Clear Dock noted down most recently, not anything from before it ended.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        if let left = UserDefaults.standard.object(forKey: leftKey) as? Date, abs(left.timeIntervalSinceNow) < 30 {
            // It left them hidden for a restart or log out, which stops this copy too. Still here
            // after a while: the restart was called off, and nothing else would put them back.
            DispatchQueue.main.asyncAfter(deadline: .now() + restartWait) { putBack(after: app) }
        } else {
            putBack(after: app)
        }
    }

    private static func putBack(after app: pid_t) -> Never {
        // Held until this copy ends: a Clear Dock opening meanwhile waits for it (see `takeOver`).
        let lock = openLock()
        if lock >= 0 { flock(lock, LOCK_EX) }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let defaults = UserDefaults.standard
        // A Clear Dock opened since has taken over what's hidden, and its own guard watches that.
        if let owner = defaults.object(forKey: ownerKey) as? Int, owner != Int(app) { exit(0) }
        defaults.removeObject(forKey: leftKey)
        SystemDock.restore()
        MainActor.assumeIsolated { SystemMenuBar.restore() }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        exit(0)
    }

    /// A file both lock while they change what's hidden, so one finishes before the other starts.
    private static func openLock() -> Int32 {
        let name = (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) + ".guard.lock"
        return open(NSTemporaryDirectory() + name, O_CREAT | O_RDWR, 0o600)
    }
}
