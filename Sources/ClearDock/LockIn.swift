import AppKit
import os
@preconcurrency import ApplicationServices
import Accelerate
import ScreenCaptureKit

/// Lock-in mode: the desktop you're on, given over to two windows side by side (or, with three
/// turned on, two stacked in a column on the left and a big one beside them), with the wallpaper
/// showing around them and a glowing edge round each. With just that many apps on the desktop it's
/// those, straight away; with more, you choose which, and the rest are tucked away (minimized)
/// until you unlock. It never takes you to another desktop, and each desktop can be locked in on
/// its own.
///
/// They stay stuck together: drag an edge between them to share the screen differently, or drag
/// one onto another's place to swap them; anything else snaps back. The dock keeps out of the way
/// on a locked-in desktop.
@MainActor
final class LockIn {
    /// A window on the desktop that can be locked in.
    struct Choice: Identifiable {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let frame: CGRect
        let app: String
        let icon: NSImage?
        /// The window's title, when its app has more than one window on the desktop.
        var title: String?
        /// One of the apps lock-in leaves alone: it can be chosen, but isn't tucked away otherwise,
        /// and doesn't count when two lock in straight away.
        var leftAlone = false
    }

    /// Locked-in desktops, by id, for the dock, which keeps out of the way on them.
    static private(set) var lockedSpaces = Set<UInt64>()
    /// While Mission Control is open, the glow and the edge between the windows are put away:
    /// they're windows of Clear Dock's own, and would show there as loose lines.
    static private(set) var missionControlOpen = false
    /// Posted when a desktop is locked in or unlocked.
    static let didChange = Notification.Name("ClearDockLockInChanged")

    var onChange: () -> Void = {}
    /// The colour of the glowing edge, for the screen it's on.
    /// The glow's colour for a desktop (by the window server's id) on a screen.
    var accent: (NSScreen, UInt64) -> NSColor = { _, _ in .systemPurple }
    /// Asks you to choose two of the windows (left, then right) or three (top left, bottom left,
    /// then the big one), and calls back with them, or with nil if you don't.
    var choose: (_ choices: [Choice], _ title: String, _ screen: NSScreen, _ done: @escaping ([Choice]?) -> Void) -> Void = { _, _, _, done in done(nil) }
    /// Closes the chooser if it's open.
    var dismissChooser: () -> Void = {}
    /// Shows a short note under the bar on a screen.
    /// A note under the bar on `screen`, with a button that does `keep` when there's one.
    var notice: (_ screen: NSScreen, _ text: String, _ icon: NSImage?, _ keep: (() -> Void)?) -> Void = { _, _, _, _ in }

    /// Locked-in desktops, by the window server's id for them.
    private var sessions: [UInt64: LockInSession] = [:]
    /// The desktop whose two windows you're choosing right now.
    private(set) var choosing: UInt64?
    /// Getting a desktop's windows ready, which takes a moment.
    private(set) var starting = false
    /// Windows tucked away on desktops whose lock-in ended while you were elsewhere. They come back
    /// when you next go there, so they reappear on their own desktop.
    private var waiting: [UInt64: [AXUIElement]] = [:]
    /// Windows that opened on a locked-in desktop, sent away: minimized until the screen they're on
    /// shows a desktop that isn't locked in, where they come back (macOS brings a minimized window
    /// back on the desktop you're on). macOS doesn't let apps move a window to another desktop.
    private var sentAway: [(window: AXUIElement, display: CGDirectDisplayID)] = []
    private var tokens: [NSObjectProtocol] = []
    /// Looks every few seconds for windows of other apps opening on a locked-in desktop.
    private var newcomerTimer: Timer?

    /// When each locked-in desktop was locked in, by its id.
    var lockedIn: [UInt64: Date] { sessions.mapValues(\.started) }

    init() {
        Self.restoreLeftovers()
    }

    // MARK: Turning it on and off

    /// Locks in the desktop you're on, or unlocks it if it's locked in. While you're choosing the
    /// two windows, closes the chooser instead.
    func toggle(choosing alwaysChoose: Bool = false) {
        if choosing != nil { return dismissChooser() }
        guard !starting else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.screens.first,
              let desktop = Self.currentDesktop(on: screen) else { return }
        if let session = sessions[desktop.id] {
            // A second click straight after locking in is a double-click, not a wish to unlock.
            guard Date().timeIntervalSince(session.started) > 1.5 else { return }
            return end(session)
        }
        // Show "Locking in…" first: finding the windows takes a moment.
        starting = true
        onChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.starting else { return }
                self.starting = false
                self.lock(desktop, on: screen, alwaysChoose: alwaysChoose)
                self.onChange()
            }
        }
    }

    /// Unlocks every desktop and puts back all the windows tucked away: the bar is going away, or
    /// Clear Dock is `quitting` (then it's all done before this returns).
    /// Says whether any windows were put back, which take a moment to get there.
    @discardableResult
    func endAll(quitting: Bool = false) -> Bool {
        let puttingBack = !sessions.isEmpty || !waiting.isEmpty || !sentAway.isEmpty
        starting = false
        dismissChooser()
        // Windows still being minimized are minimized first, so they're brought back after.
        if quitting { Self.windowQueue.sync {} }
        for session in Array(sessions.values) { end(session, now: true, quitting: quitting) }
        for windows in waiting.values { Self.unminimize(windows, waiting: quitting) }
        waiting.removeAll()
        Self.unminimize(sentAway.map(\.window), waiting: quitting)
        sentAway.removeAll()
        updateWatching()
        saveLeftovers()
        return puttingBack
    }

    /// For checking how lock-in looks: locks in the windows of the app `pid` on the desktop showing
    /// on the main screen, tucking nothing else away. False if that can't be done.
    func lockForChecking(pid: pid_t) -> Bool {
        guard let screen = NSScreen.main, let desktop = Self.currentDesktop(on: screen), sessions[desktop.id] == nil else { return false }
        let mine = Self.windows(on: desktop).choices.filter { $0.pid == pid }
        guard !mine.isEmpty else { return false }
        checkingSpace = desktop.id
        // Only another copy of the same app opening meanwhile is dealt with; your own windows stay put.
        start(Self.arranged(Array(mine.prefix(3))), of: mine, hiding: [], on: desktop.id, screen: screen,
              checking: NSRunningApplication(processIdentifier: pid)?.executableURL)
        return sessions[desktop.id] != nil
    }

    /// Unlocks what `lockForChecking` locked in.
    func unlockForChecking() {
        guard let space = checkingSpace, let session = sessions[space] else { return }
        checkingSpace = nil
        end(session, now: true)
    }

    private var checkingSpace: UInt64?

    /// For checking how the chooser looks: the windows it would offer on the desktop showing on
    /// `screen`, and that desktop's name.
    func choicesForChecking(on screen: NSScreen) -> (choices: [Choice], title: String)? {
        guard let desktop = Self.currentDesktop(on: screen) else { return nil }
        return (Self.windows(on: desktop).choices, BarSettings.desktopNames[desktop.key] ?? "Desktop \(desktop.number)")
    }

    /// Locks in the desktop: straight away when its windows fit the layout, otherwise (or when
    /// `alwaysChoose` says so) once you've chosen in the picker.
    private func lock(_ desktop: Desktop, on screen: NSScreen, alwaysChoose: Bool = false) {
        guard AXIsProcessTrusted() else {
            Self.explain("Lock-in needs Accessibility permission",
                         "Turn on Clear Dock in Privacy & Security > Accessibility, then click Lock In again.")
            return SystemSettings.open("com.apple.preference.security?Privacy_Accessibility")
        }
        let (windows, apart) = Self.windows(on: desktop)
        guard !windows.isEmpty else {
            return Self.explain("Lock-in needs a window on this desktop", "Open the apps you want here, then click Lock In.")
        }
        let layout = BarSettings.lockInLayout
        // Apps left alone (usually just playing music alongside) only count when they're needed to
        // fill the layout.
        var pool = windows.filter { !$0.leftAlone }
        if pool.count < min(layout, windows.count) { pool = windows }
        if pool.count <= layout, !alwaysChoose || windows.count == 1 {
            // Just as many as the layout takes, or fewer: those, straight away.
            return start(Self.arranged(pool), of: windows, hiding: apart, on: desktop.id, screen: screen)
        }
        let fronts = Self.frontWindowOfEachApp(pool)
        if fronts.count == layout, !alwaysChoose {
            // That many apps: the front window of each.
            return start(Self.arranged(fronts), of: windows, hiding: apart, on: desktop.id, screen: screen)
        }
        do {
            choosing = desktop.id
            onChange()
            let title = BarSettings.desktopNames[desktop.key] ?? "Desktop \(desktop.number)"
            choose(windows, title, screen) { [weak self] picked in
                guard let self, self.choosing == desktop.id else { return }
                self.choosing = nil
                self.onChange()
                // Only if you're still on that desktop.
                guard let picked, Self.currentDesktop(on: screen)?.id == desktop.id else { return }
                self.start(picked, of: windows, hiding: apart, on: desktop.id, screen: screen)
            }
        }
    }

    /// Windows in their places, going by where they are now: two side by side stay on the side
    /// they're on; of three, the biggest goes on the right and the other two stack in the order
    /// they're in now.
    static func arranged(_ windows: [Choice]) -> [Choice] {
        switch windows.count {
        case 2:
            return windows.sorted { $0.frame.midX < $1.frame.midX }
        case 3:
            guard let big = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return windows }
            return windows.filter { $0.id != big.id }.sorted { $0.frame.minY < $1.frame.minY } + [big]
        default:
            return windows
        }
    }

    /// The front-most window of each app, in the order the apps come (front-most first).
    static func frontWindowOfEachApp(_ windows: [Choice]) -> [Choice] {
        var seen = Set<pid_t>()
        return windows.filter { seen.insert($0.pid).inserted }
    }

    /// Locks in one, two or three of the desktop's windows; the rest of `all` are tucked away
    /// (apart from apps left alone), and the apps in `apart` hidden, if that's on.
    private func start(_ picked: [Choice], of all: [Choice], hiding apart: Set<pid_t>, on space: UInt64, screen: NSScreen,
                       checking app: URL? = nil) {
        guard (1...3).contains(picked.count), Set(picked.map(\.id)).count == picked.count,
              let display = screen.displayID, sessions[space] == nil else { return }
        restoreWaiting(on: space)
        let session = LockInSession(space: space, display: display,
                                    panes: picked.map { LockInSession.Pane(pid: $0.pid, element: $0.element, id: $0.id) })
        session.checkingApp = app
        session.accent = { [weak self, weak session] in
            guard let self, let session, let screen = session.screen else { return .systemPurple }
            return self.accent(screen, session.space)
        }
        session.onEnd = { [weak self, weak session] in
            guard let self, let session else { return }
            self.end(session)
        }
        session.onPutAway = { [weak self] in self?.saveLeftovers() }
        session.onNotice = { [weak self, weak session] text, icon, keep in
            guard let self, let screen = session?.screen else { return }
            self.notice(screen, text, icon, keep)
        }
        session.onKeep = { [weak self] windows in
            guard let self else { return }
            self.sentAway.removeAll { entry in windows.contains { CFEqual($0, entry.window) } }
            self.updateWatching()
            self.saveLeftovers()
        }
        session.onSendAway = { [weak self, weak session] window in
            guard let self, let session else { return }
            self.sentAway.append((window, session.display))
            self.updateWatching()
            // Gone to another desktop while it was being sent away: it can come back there now.
            if !session.showing { self.bringBackSentAway() }
        }
        sessions[space] = session
        if BarSettings.lockInHideOthers {
            let kept = Set(picked.map(\.id))
            session.tuck(all.filter { !kept.contains($0.id) && !$0.leftAlone }.map(\.element))
            session.hide(apart)
            saveLeftovers()
        }
        // First, so the dock is out of the way before the two are given the room.
        publish()
        session.begin()
        updateWatching()
    }

    /// Mission Control opened or closed.
    func missionControl(open: Bool) {
        guard open != Self.missionControlOpen else { return }
        Self.missionControlOpen = open
        for session in sessions.values { session.showDecorationsAgain() }
    }

    /// A bar setting changed. Only a different gap moves the windows; the glow setting only
    /// redraws round them, and anything else (the clock, a desktop's name) changes neither.
    func settingsChanged() {
        for session in sessions.values { session.updateBackdrop() }
        let now = (gap: BarSettings.lockInGap, border: BarSettings.lockInBorder)
        defer { appliedSettings = now }
        guard let before = appliedSettings else { return }
        if now.gap != before.gap {
            for session in sessions.values { session.refit() }
        } else if now.border != before.border {
            for session in sessions.values { session.showDecorationsAgain() }
        }
    }
    private var appliedSettings: (gap: Double, border: Bool)?

    private func publish() {
        Self.lockedSpaces = Set(sessions.keys)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        onChange()
    }

    /// Unlocks a desktop. Its tucked-away windows come back now if it's showing (or `now` says so),
    /// or else when you next go there, since macOS brings a window back on the desktop you're on.
    private func end(_ session: LockInSession, now: Bool = false, quitting: Bool = false) {
        guard sessions[session.space] === session else { return }
        sessions[session.space] = nil
        // Lock-in is for a while: the windows go back to where they were before it.
        session.putBack(waiting: quitting)
        session.finish()
        // Hidden apps come back on their own desktops, wherever you are.
        session.hiddenApps.forEach { NSRunningApplication(processIdentifier: $0)?.unhide() }
        if now || WindowSpaces.currentSpaceIDs().contains(session.space) {
            Self.unminimize(session.tucked, waiting: quitting)
        } else if !session.tucked.isEmpty {
            waiting[session.space, default: []] += session.tucked
        }
        updateWatching()
        publish()
        // That desktop isn't locked in any more, so windows sent away from it can come back now.
        bringBackSentAway(waiting: quitting)
        saveLeftovers()
    }

    // MARK: Keeping up with your desktops and apps

    /// Listens to the system only while a desktop is locked in or has windows waiting to come back.
    private func updateWatching() {
        let needed = !sessions.isEmpty || !waiting.isEmpty || !sentAway.isEmpty
        if needed && tokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.moveNewcomers() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .default)
            newcomerTimer = timer
            tokens = [
                // An app coming forward is usually one opening a window: look straight away, and
                // again once it's had a moment.
                center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                    let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    MainActor.assumeIsolated {
                        if let pid { self?.sessions.values.forEach { $0.noteInFront(pid) } }
                        for delay in [0.3, 1.2] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                MainActor.assumeIsolated { self?.moveNewcomers() }
                            }
                        }
                    }
                },
                center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.spaceChanged() }
                },
                // A screen unplugged or changed: its desktops' lock-ins end, or fit the new size.
                NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screensChanged() }
                },
                // The dock or the bar started or stopped keeping room: the two take the space there is now.
                NotificationCenter.default.addObserver(forName: DockSpaceKeeper.didChange, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.roomChanged() }
                },
                center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                    let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    MainActor.assumeIsolated { if let pid { self?.appQuit(pid) } }
                },
            ]
        } else if !needed && !tokens.isEmpty {
            tokens.forEach {
                NSWorkspace.shared.notificationCenter.removeObserver($0)
                NotificationCenter.default.removeObserver($0)
            }
            tokens.removeAll()
            newcomerTimer?.invalidate()
            newcomerTimer = nil
        }
    }

    private func spaceChanged() {
        let current = WindowSpaces.currentSpaceIDs()
        for space in waiting.keys where current.contains(space) { restoreWaiting(on: space) }
        for session in sessions.values {
            session.showing = current.contains(session.space)
            session.showDecorationsAgain()
        }
        // Back on a desktop whose room changed while it wasn't showing: once the dock and the bar
        // have settled there, fit the two to it.
        if sessions.values.contains(where: { $0.showing && refitWhenShowing.contains($0.space) }) { roomChanged() }
        bringBackSentAway()
    }

    /// Brings back windows sent away from a locked-in desktop, on screens now showing a desktop that
    /// isn't locked in, so they open there.
    private func bringBackSentAway(waiting: Bool = false) {
        guard !sentAway.isEmpty else { return }
        var still: [(window: AXUIElement, display: CGDirectDisplayID)] = []
        for entry in sentAway {
            if let screen = NSScreen.screens.first(where: { $0.displayID == entry.display }) {
                guard let current = WindowSpaces.currentSpaceID(on: screen), !Self.lockedSpaces.contains(current) else {
                    still.append(entry)
                    continue
                }
            }
            // On a desktop that isn't locked in (or its screen has gone, and macOS put it elsewhere).
            Self.unminimize([entry.window], waiting: waiting)
        }
        guard still.count != sentAway.count else { return }
        sentAway = still
        updateWatching()
        saveLeftovers()
    }

    private func screensChanged() {
        for session in Array(sessions.values) {
            if session.screen == nil {
                // Gone for good, rather than for a moment (a display sleeping, a monitor reconnecting):
                // its windows have moved to another screen, onto whatever desktop shows there.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.sessions[session.space] === session else { return }
                        if session.screen == nil { self.end(session, now: true) } else { session.refit() }
                    }
                }
            } else {
                session.refit()
            }
        }
    }

    private func moveNewcomers() {
        // Not in Mission Control: its own windows come and go then, and macOS is busy drawing it.
        guard !Self.missionControlOpen else { return }
        for session in sessions.values where session.showing { session.moveNewcomers() }
    }

    private var pendingRefit: DispatchWorkItem?
    /// Locked-in desktops not showing when the room kept changed, to refit once they're back.
    private var refitWhenShowing = Set<UInt64>()

    /// A moment after the room kept changes (it often changes in a few steps), refits the two on
    /// the desktops showing. A desktop that isn't is left alone till you go back to it: the room
    /// kept for the dock often changes just because you left (it hides on a locked-in desktop),
    /// and changes back when you return.
    private func roomChanged() {
        pendingRefit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions.values {
                    if session.showing {
                        self.refitWhenShowing.remove(session.space)
                        session.refit()
                    } else {
                        self.refitWhenShowing.insert(session.space)
                    }
                }
            }
        }
        pendingRefit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// One of the two apps quit, so that desktop's lock-in is over.
    private func appQuit(_ pid: pid_t) {
        for session in sessions.values where session.involves(pid) { end(session) }
    }

    private func restoreWaiting(on space: UInt64) {
        guard let windows = waiting.removeValue(forKey: space) else { return }
        Self.unminimize(windows)
        updateWatching()
        saveLeftovers()
    }

    // MARK: If Clear Dock stops while locked in

    /// What's tucked away and hidden, written down so it can be put back if Clear Dock stops without
    /// unlocking (a crash, or being forced to quit): with the macOS Dock hidden, minimized windows
    /// would otherwise be hard to get back.
    private static let leftoversKey = "lockIn.leftovers"

    private func saveLeftovers() {
        var windows: [[String: Int]] = []
        for window in sessions.values.flatMap(\.tucked) + waiting.values.flatMap({ $0 }) + sentAway.map(\.window) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success, let id = AppWindowList.windowID(of: window) else { continue }
            windows.append(["pid": Int(pid), "window": Int(id)])
        }
        let apps: [[String: Any]] = sessions.values.flatMap(\.hiddenApps).compactMap { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map { ["pid": Int(pid), "bundle": $0] }
        }
        if windows.isEmpty && apps.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.leftoversKey)
        } else {
            UserDefaults.standard.set(["windows": windows, "apps": apps], forKey: Self.leftoversKey)
        }
    }

    /// Puts back what an earlier run of Clear Dock left tucked away or hidden, if it stopped while
    /// locked in.
    private static func restoreLeftovers() {
        guard let saved = UserDefaults.standard.dictionary(forKey: leftoversKey) else { return }
        UserDefaults.standard.removeObject(forKey: leftoversKey)
        var windows: [pid_t: Set<CGWindowID>] = [:]
        for entry in saved["windows"] as? [[String: Int]] ?? [] {
            guard let pid = entry["pid"], let id = entry["window"] else { continue }
            windows[pid_t(pid), default: []].insert(CGWindowID(id))
        }
        for (pid, ids) in windows {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                guard let id = AppWindowList.windowID(of: window), ids.contains(id) else { continue }
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
        for entry in saved["apps"] as? [[String: Any]] ?? [] {
            // Only the same app: after a restart, the number may belong to another.
            guard let pid = entry["pid"] as? Int, let bundle = entry["bundle"] as? String,
                  let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.bundleIdentifier == bundle else { continue }
            app.unhide()
        }
    }

    // MARK: Finding the windows

    fileprivate static func currentDesktop(on screen: NSScreen) -> Desktop? {
        let desktops = DesktopReader.read()
        return (desktops[screen.displayUUID ?? "Main"] ?? desktops["Main"])?.first(where: \.isCurrent)
    }

    /// The ordinary windows on a desktop, front-most first, and the apps with windows there that
    /// can't be moved or tucked away one window at a time: games, which are left alone, and apps
    /// that don't describe their windows to Accessibility (like League of Legends' launcher).
    private static func windows(on desktop: Desktop) -> (choices: [Choice], apart: Set<pid_t>) {
        var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var choices: [Choice] = []
        var apart = Set<pid_t>()
        for window in desktop.windows {
            // Apps you've let be (like Spotify) can be chosen, but are otherwise left as they are.
            let leftAlone = BarSettings.lockInAllows(window.app)
            if Games.isGame(window.app) {
                if !leftAlone { apart.insert(window.app) }
                continue
            }
            if elements[window.app] == nil {
                let app = AXUIElementCreateApplication(window.app)
                AXUIElementSetMessagingTimeout(app, 0.5)
                var found: [CGWindowID: AXUIElement] = [:]
                for element in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                    guard (attribute(element, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                          (attribute(element, kAXMinimizedAttribute) as? Bool) != true,
                          let id = AppWindowList.windowID(of: element) else { continue }
                    found[id] = element
                }
                elements[window.app] = found
            }
            guard let element = elements[window.app]?[window.id] else {
                if elements[window.app]?.isEmpty == true, !leftAlone { apart.insert(window.app) }
                continue
            }
            let app = NSRunningApplication(processIdentifier: window.app)
            choices.append(Choice(id: window.id, pid: window.app, element: element, frame: window.frame,
                                  app: app?.localizedName ?? "App", icon: app?.icon,
                                  title: attribute(element, kAXTitleAttribute) as? String, leftAlone: leftAlone))
        }
        // Titles are only needed to tell apart windows of the same app.
        for index in choices.indices where choices.filter({ $0.pid == choices[index].pid }).count < 2 {
            choices[index].title = nil
        }
        return (choices, apart.subtracting(choices.map(\.pid)))
    }

    // MARK: Helpers

    /// Where windows are minimized, brought back and put back, off the main thread: an app that's
    /// busy with one window (minimizing it, say) answers about the next only once it's done.
    nonisolated static let windowQueue = DispatchQueue(label: "Clear Dock lock-in windows", qos: .userInitiated)

    /// Brings windows back from the Dock, off the main thread unless `waiting` (Clear Dock is quitting).
    static func unminimize(_ windows: [AXUIElement], waiting: Bool = false) {
        guard !windows.isEmpty else { return }
        let work: @Sendable () -> Void = {
            for window in windows {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
        if waiting { work() } else { windowQueue.async(execute: work) }
    }

    private static func explain(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    nonisolated fileprivate static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated fileprivate static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

}

/// Notes about lock-in, readable with: log show --predicate 'subsystem == "local.cleardock" AND category == "lockin"'
let lockInLog = Logger(subsystem: "local.cleardock", category: "lockin")

/// One locked-in desktop: its two windows kept side by side (or three: two stacked in a column on
/// the left, a big one beside them), and the windows tucked away meanwhile.
@MainActor
private final class LockInSession {
    struct Pane {
        let pid: pid_t
        let element: AXUIElement
        let id: CGWindowID
    }

    let space: UInt64
    /// The display the desktop is on.
    let display: CGDirectDisplayID
    let started = Date()
    /// Other windows on the desktop, minimized while it's locked in.
    private(set) var tucked: [AXUIElement] = []
    /// Apps hidden while it's locked in: games, and apps whose windows can't be minimized one at a
    /// time. Hiding is the gentlest way macOS has of putting an app away.
    private(set) var hiddenApps: [pid_t] = []
    /// Whether the desktop is the one showing on its display.
    var showing = true
    var accent: () -> NSColor = { .systemPurple }
    /// One of the two windows closed.
    var onEnd: () -> Void = {}
    /// It tucked away or hid something more (a window that opened meanwhile).
    var onPutAway: () -> Void = {}
    /// A window that opened on the desktop was sent away, to come back on a desktop that isn't locked in.
    var onSendAway: (AXUIElement) -> Void = { _ in }
    /// Windows sent away that you've asked to keep here after all.
    var onKeep: ([AXUIElement]) -> Void = { _ in }

    /// Left, then right, each with what moves it; or, with three, the top of the stack, its bottom,
    /// then the big one.
    private var panes: [Pane]
    /// Three, two of them stacked.
    private var stacked: Bool { panes.count == 3 }
    private var movers: [WindowMover]
    private var ended = false
    /// While you drag the edge between them, and until both apps have caught up afterwards.
    private var dragging = false
    /// Which edge is being dragged: the one between the left and right (or the stack and the big
    /// one), or the one between the two stacked windows.
    private enum Edge { case upright, across }
    private var draggedEdge = Edge.upright
    /// The left window's (or the stack's) width, and the top stacked one's height, while dragging.
    private var draggedWidth: CGFloat?
    private var draggedHeight: CGFloat?
    /// Where on the edge you took hold of it: from its left side, or from its top for the edge
    /// between the stacked two.
    private var grabOffset: CGFloat = 0
    private var dividerMoved = false
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingSettle: DispatchWorkItem?
    private let divider = DividerPanel(across: false)
    /// Between the two stacked ones.
    private let rowDivider = DividerPanel(across: true)
    private let glows: [GlowFrame]
    /// What you see while you drag the edge between them.
    private var overlay: DragOverlay?
    /// Where the two were last drawn round, in the system's window coordinates.
    private var drawnFrames: [CGRect]?
    /// Where the two were last known to be, kept while the glow is put away (on another desktop, or
    /// in Mission Control), so it can come back without asking the apps where they are.
    private var knownFrames: [CGRect]?
    /// The windows on screen at the last look for newcomers, and how many times it's been asked to look.
    private var lastLookedAt: [UInt] = []
    private var looks = 0
    /// The two (by window) that are minimized right now: nothing to fit or draw round till they're back.
    private var minimized = Set<CGWindowID>()
    /// Counts drags of the edge, so what's left over from one let go of just before doesn't act
    /// on the next.
    private var drag = 0
    /// The edge is held right now (between taking hold of it and letting go).
    private var holding = false
    /// How narrow each app has shown it will go, by window, for those that won't go as narrow as asked.
    private var minimumWidths: [CGWindowID: CGFloat] = [:]
    /// How big each app has shown it will go, by window, for those that won't fill their place.
    private var largestSizes: [CGWindowID: CGSize] = [:]
    /// Where each window was found the last time it needed fitting.
    private var lastFound: [CGWindowID: CGRect] = [:]

    nonisolated private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    init(space: UInt64, display: CGDirectDisplayID, panes: [Pane]) {
        self.space = space
        self.display = display
        self.panes = panes
        movers = panes.map { WindowMover($0.element) }
        glows = panes.map { _ in GlowFrame() }
        divider.onBegin = { [weak self] offset in self?.grabbed(.upright, at: offset) }
        divider.onDrag = { [weak self] _ in self?.dividerMoved = true }
        divider.onEnd = { [weak self] in self?.dividerReleased() }
        rowDivider.onBegin = { [weak self] offset in self?.grabbed(.across, at: offset) }
        rowDivider.onDrag = { [weak self] _ in self?.dividerMoved = true }
        rowDivider.onEnd = { [weak self] in self?.dividerReleased() }
    }

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == display } }

    func involves(_ pid: pid_t) -> Bool { panes.contains { $0.pid == pid } }

    /// Where the windows were before lock-in, to put them back afterwards.
    private var startingFrames: [CGWindowID: CGRect] = [:]

    /// Puts the windows back where they were before lock-in (any that are still open).
    /// Off the main thread, unless `waiting` (Clear Dock is quitting).
    func putBack(waiting: Bool = false) {
        // Only to where a screen still is (one may have been unplugged since), in window coordinates.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        let moves = panes.compactMap { pane -> (element: AXUIElement, frame: CGRect)? in
            guard !minimized.contains(pane.id), let frame = startingFrames[pane.id],
                  screens.contains(where: { $0.intersection(frame).width >= 120 && $0.intersection(frame).height >= 80 }) else { return nil }
            return (pane.element, frame)
        }
        let movers = self.movers
        let work: @Sendable () -> Void = {
            // After any move of the edge between them still under way, too.
            movers.forEach { $0.waitUntilIdle() }
            for (element, frame) in moves where LockIn.frame(of: element) != nil {
                Self.setSize(element, frame.size)
                Self.setPosition(element, frame.origin)
                Self.setSize(element, frame.size)
            }
        }
        // After anything still being done to them, so a fit under way can't undo it.
        if waiting { Self.paneQueue.sync(execute: work) } else { Self.paneQueue.async(execute: work) }
    }

    /// Something lock-in did that's worth a word (a window that opened here was sent elsewhere).
    var onNotice: (_ text: String, _ icon: NSImage?, _ keep: (() -> Void)?) -> Void = { _, _, _ in }

    /// The one of the two you were last using.
    private var lastUsed = 0

    func noteInFront(_ pid: pid_t) {
        if let index = panes.firstIndex(where: { $0.pid == pid }) { lastUsed = index }
    }

    /// Brings back the one of the two you were using.
    private func raiseLastUsed() {
        // Checking lock-in never takes the keyboard from what you're using.
        guard checkingApp == nil else { return }
        let pane = panes[min(lastUsed, panes.count - 1)]
        WindowFocus.raise(pane.id, of: pane.pid)
    }

    func begin() {
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { noteInFront(front) }
        // Where they were, to go back to on unlocking: asked before anything moves them.
        look { [weak self] found in self?.startingFrames = found }
        // First, so it fades in behind the windows as they settle into place.
        updateBackdrop()
        watch()
        fit()
        // Then make room for an app that wouldn't go as narrow as its share.
        scheduleSettle()
        // Bring one forward (the left one, or the big one), unless you're already using one of them.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, !involves(front), checkingApp == nil {
            let main = panes[stacked ? 2 : 0]
            WindowFocus.raise(main.id, of: main.pid)
        }
    }

    func finish() {
        ended = true
        pendingSettle?.cancel()
        overlay?.finish()
        overlay = nil
        backdrop?.finish()
        backdrop = nil
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        hideDecorations()
    }

    /// Minimizes the desktop's other windows, so just the two and the wallpaper show.
    func hide(_ apps: Set<pid_t>) {
        for pid in apps where !hiddenApps.contains(pid) && !involves(pid) {
            if NSRunningApplication(processIdentifier: pid)?.hide() == true { hiddenApps.append(pid) }
        }
    }

    func tuck(_ windows: [AXUIElement]) {
        // Their numbers and apps first, while the apps aren't busy minimizing them.
        let away = windows.compactMap { window -> AwayWindow? in
            var pid: pid_t = 0
            guard let id = AppWindowList.windowID(of: window), AXUIElementGetPid(window, &pid) == .success else { return nil }
            return AwayWindow(window: window, pid: pid, id: id)
        }
        guard !away.isEmpty else { return }
        // Counted as tucked away straight away, so they're brought back on unlocking (or quitting)
        // even if that comes before they've finished going.
        tucked += away.map(\.window)
        putAway.formUnion(away.map(\.id))
        onPutAway()
        LockIn.windowQueue.async {
            for window in away { AXUIElementSetAttributeValue(window.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        }
        // Those that can't be minimized go with their app, hidden.
        afterMinimizing(away) { [weak self] stuck in
            guard let self, !stuck.isEmpty else { return }
            self.hide(Set(stuck.map(\.pid)))
            self.onPutAway()
        }
    }

    /// Windows lock-in minimized (tucked away, or sent away when they opened), by number: one that
    /// shows on the desktop again is one you brought back, and is left alone from then on.
    private var putAway = Set<CGWindowID>()
    /// Windows, and apps (lock-in hid them, as it can't see their windows), you brought back.
    private var keptWindows = Set<CGWindowID>()
    private var keptApps = Set<pid_t>()
    /// Only for checking lock-in: windows opening on the desktop are dealt with only for copies of
    /// the app at this location.
    var checkingApp: URL?

    func refit() {
        guard !ended, !dragging else { return }
        if let screen { backdrop?.cover(screen) }
        fit()
    }

    /// The calm picture behind the windows (see `CalmBackdrop`).
    private var backdrop: CalmBackdrop?

    /// Puts up or takes down the calm backdrop, as the setting says. It's made on the desktop
    /// showing, so only while this one is (otherwise when you next come back to it).
    func updateBackdrop() {
        guard !ended else { return }
        if !BarSettings.lockInCalmBackdrop {
            backdrop?.finish()
            backdrop = nil
        } else if backdrop == nil, showing, let screen {
            backdrop = CalmBackdrop(covering: screen)
        }
    }

    // MARK: Keeping them side by side

    /// The space the two windows share: what's free on the screen (under the bar, beside Clear
    /// Dock), with a gap all round showing the wallpaper.
    private var area: CGRect? {
        guard let screen else { return nil }
        let gap = CGFloat(BarSettings.lockInGap)
        var free = DockSpaceKeeper.shared.freeArea(on: screen)
        // Always below the top bar while it's on, even while it has stepped aside for a moment: the
        // windows would grow into its place and cover it when it comes back.
        if let id = screen.displayID, let bottom = BarRoom.bottoms[id] {
            let line = (NSScreen.screens.first?.frame.height ?? 0) - bottom
            if free.minY < line { free = CGRect(x: free.minX, y: line, width: free.width, height: max(0, free.maxY - line)) }
        }
        let area = free.insetBy(dx: gap, dy: gap)
        return area.width > 240 && area.height > 120 ? area : nil
    }

    /// Where each window goes, in `panes`' order, in the system's window coordinates.
    private var targets: [CGRect] {
        guard let area else { return [] }
        let gap = CGFloat(BarSettings.lockInGap)
        if stacked {
            return Self.stack(in: area, gap: gap, column: ((area.width - gap) * CGFloat(BarSettings.lockInStackColumn)).rounded(),
                              top: ((area.height - gap) * CGFloat(BarSettings.lockInStackRows)).rounded())
        }
        if panes.count == 1 { return [area] }
        let left = ((area.width - gap) * CGFloat(BarSettings.lockInSplit)).rounded()
        return [
            CGRect(x: area.minX, y: area.minY, width: left, height: area.height),
            CGRect(x: area.minX + left + gap, y: area.minY, width: area.width - left - gap, height: area.height),
        ]
    }

    /// Three in `area`: a column `column` wide on the left, its top one `top` high and the other
    /// under it, and the big one beside them (system window coordinates, growing downwards).
    private static func stack(in area: CGRect, gap: CGFloat, column: CGFloat, top: CGFloat) -> [CGRect] {
        [CGRect(x: area.minX, y: area.minY, width: column, height: top),
         CGRect(x: area.minX, y: area.minY + top + gap, width: column, height: area.height - top - gap),
         CGRect(x: area.minX + column + gap, y: area.minY, width: area.width - column - gap, height: area.height)]
    }

    private func fit() {
        look { [weak self] found in self?.fit(found) }
    }

    /// Puts the windows in their places, given where they are now (`found`, by window).
    private func fit(_ found: [CGWindowID: CGRect]) {
        // A drag may have begun while their apps were being asked.
        guard !dragging else { return }
        let places = targets
        var moves: [(element: AXUIElement, frame: CGRect)] = []
        // Whether any was found somewhere new since it was last fitted: worth one more look once
        // they've moved, which finds out one that won't grow all the way.
        var moving = false
        for (pane, place) in zip(panes, places) where !minimized.contains(pane.id) {
            guard let frame = found[pane.id] else { continue }
            // Bigger than it was thought to go: it can fill its place after all.
            if let largest = largestSizes[pane.id], frame.width > largest.width + 16 || frame.height > largest.height + 16 {
                largestSizes[pane.id] = nil
            }
            var target = placed(place, for: pane.id)
            guard !Self.close(frame, target) else { continue }
            // Found short of its place just as the last fit left it: it won't grow any bigger, so
            // it goes in the middle of its place from now on, and isn't asked again.
            if let last = lastFound[pane.id], Self.close(last, frame), last.size == frame.size,
               frame.width < target.width - 16 || frame.height < target.height - 16 {
                // Each way it fell short; a way it was found short before keeps what was learned then.
                let before = largestSizes[pane.id]
                largestSizes[pane.id] = CGSize(width: frame.width < target.width - 16 ? frame.width : before?.width ?? .greatestFiniteMagnitude,
                                               height: frame.height < target.height - 16 ? frame.height : before?.height ?? .greatestFiniteMagnitude)
                target = placed(place, for: pane.id)
                if Self.close(frame, target) { continue }
            }
            if lastFound[pane.id].map({ !(Self.close($0, frame) && $0.size == frame.size) }) ?? true { moving = true }
            lastFound[pane.id] = frame
            lockInLog.notice("Lock-in: fitting a window from \(String(describing: frame), privacy: .public) to \(String(describing: target), privacy: .public)")
            moves.append((pane.element, target))
        }
        if places.count == panes.count { knownFrames = placed(places) }
        guard !moves.isEmpty else { return updateDecorations(frames(from: found)) }
        let ids = panes.map { (id: $0.id, element: $0.element) }
        movesAsked += 1
        Self.paneQueue.async { [weak self] in
            // Size, place, and size again: some apps only accept a size that fits where they are.
            for (element, frame) in moves {
                Self.setSize(element, frame.size)
                Self.setPosition(element, frame.origin)
                Self.setSize(element, frame.size)
            }
            var now: [CGWindowID: CGRect] = [:]
            for pane in ids { now[pane.id] = LockIn.frame(of: pane.element) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.ended, !self.dragging else { return }
                    self.updateDecorations(self.frames(from: now))
                    if moving { self.scheduleSettle() }
                }
            }
        }
    }

    /// Where a window goes in its place: all of it, or the middle of it for one that won't grow that big.
    private func placed(_ place: CGRect, for id: CGWindowID) -> CGRect {
        guard let largest = largestSizes[id] else { return place }
        let size = CGSize(width: min(place.width, largest.width), height: min(place.height, largest.height))
        return CGRect(x: (place.midX - size.width / 2).rounded(), y: (place.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    private func placed(_ places: [CGRect]) -> [CGRect] {
        zip(panes, places).map { placed($1, for: $0.id) }
    }

    /// After you've moved or resized one of them yourself: an inner edge dragged sets how they
    /// share the screen, a window dragged over the other's side swaps them, and everything else
    /// snaps back. Also makes room for an app that won't go as narrow as its share.
    private func settle() {
        // Not while Mission Control is open (it may have opened since this was asked for, before
        // the bar's check noticed): where it shows the windows isn't where they are.
        guard !LockIn.missionControlOpen else { return }
        look(unlessMissionControl: true) { [weak self] found in self?.settle(found) }
    }

    private func settle(_ found: [CGWindowID: CGRect]) {
        // Things may have moved on while their apps were being asked.
        guard !dragging, !LockIn.missionControlOpen, let area, let frames = frames(from: found) else { return }
        if stacked {
            settleStack(frames, in: area)
            return fit(found)
        }
        // Just one: it has the whole space, and goes back to it if moved.
        guard panes.count == 2 else { return fit(found) }
        let goals = targets
        let left = frames[0], right = frames[1]
        let gap = CGFloat(BarSettings.lockInGap)
        let usable = area.width - gap
        if left.midX > right.midX {
            swap(0, 1)
        } else {
            // Some apps have a smallest size; remember it, so dragging the edge stops there.
            if left.width > goals[0].width + 16 { minimumWidths[panes[0].id] = left.width }
            if right.width > goals[1].width + 16 { minimumWidths[panes[1].id] = right.width }
            if abs(left.minX - goals[0].minX) < 3 && abs(left.maxX - goals[0].maxX) > 16 && abs(left.width - goals[0].width) > 16 {
                BarSettings.lockInSplit = Self.clampSplit((left.maxX - area.minX) / usable)
            } else if abs(right.maxX - goals[1].maxX) < 3 && abs(right.minX - goals[1].minX) > 16 && abs(right.width - goals[1].width) > 16 {
                BarSettings.lockInSplit = Self.clampSplit((right.minX - gap - area.minX) / usable)
            } else if abs(right.minX - goals[1].minX) < 3 && right.width > goals[1].width + 16 {
                // The right one would reach off the screen: give it the room it needs.
                BarSettings.lockInSplit = Self.clampSplit((area.width - gap - right.width) / usable)
            }
        }
        fit(found)
    }

    private static func clampSplit(_ value: CGFloat) -> Double { Double(min(0.8, max(0.2, value))) }

    private func swap(_ a: Int, _ b: Int) {
        panes.swapAt(a, b)
        movers.swapAt(a, b)
        if lastUsed == a { lastUsed = b } else if lastUsed == b { lastUsed = a }
    }

    /// The same for three: an inner edge dragged (the big one's left side, a stacked one's right
    /// side, or where the stacked two meet) sets how they share the screen, and one dragged onto
    /// another's place swaps the two. Also makes room for an app that won't go as small as asked.
    private func settleStack(_ frames: [CGRect], in area: CGRect) {
        let goals = targets
        guard frames.count == 3, goals.count == 3 else { return }
        let gap = CGFloat(BarSettings.lockInGap)
        let width = area.width - gap, height = area.height - gap
        let top = frames[0], bottom = frames[1], big = frames[2]
        func kept(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 3 }
        // Moved well clear, rather than an app rounding its size (like Terminal, to whole lines).
        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 16 }
        func column(_ share: CGFloat) { BarSettings.lockInStackColumn = Double(min(0.7, max(0.1, share))) }
        func rows(_ share: CGFloat) { BarSettings.lockInStackRows = Double(min(0.9, max(0.1, share))) }
        if kept(big.maxX, goals[2].maxX), moved(big.minX, goals[2].minX) {
            column((big.minX - gap - area.minX) / width)
        } else if kept(top.minX, goals[0].minX), moved(top.maxX, goals[0].maxX) {
            column((top.maxX - area.minX) / width)
        } else if kept(bottom.minX, goals[1].minX), moved(bottom.maxX, goals[1].maxX) {
            column((bottom.maxX - area.minX) / width)
        } else if kept(top.minY, goals[0].minY), moved(top.maxY, goals[0].maxY) {
            rows((top.maxY - area.minY) / height)
        } else if kept(bottom.maxY, goals[1].maxY), moved(bottom.minY, goals[1].minY) {
            rows((bottom.minY - gap - area.minY) / height)
        } else {
            for index in frames.indices {
                let centre = CGPoint(x: frames[index].midX, y: frames[index].midY)
                guard !goals[index].contains(centre),
                      let other = goals.indices.first(where: { $0 != index && goals[$0].contains(centre) }) else { continue }
                swap(index, other)
                break
            }
        }
    }

    // MARK: Dragging the edge between them

    // While you drag the edge, each window is covered by a frosted panel with its app's icon, and
    // the covers, the glow and the grip follow the pointer as freely as any window you drag. The
    // apps themselves are resized once, when you let go: apps built on web pages (TradingView,
    // Discord, Spotify) can't redraw at every width quickly enough to keep up.

    private func grabbed(_ edge: Edge, at offset: CGFloat) {
        guard !ended, let area, let frames = drawnFrames ?? currentFrames() else { return }
        // Taken hold of again before the last drag had finished: that one's covers go now.
        overlay?.finish()
        drag += 1
        holding = true
        movers.forEach { $0.forget() }
        dragging = true
        dividerMoved = false
        draggedEdge = edge
        draggedWidth = nil
        draggedHeight = nil
        grabOffset = offset
        let stacked = self.stacked
        // At each refresh of the screen it looks where the pointer is right then, rather than
        // where the last mouse event said: mice and screens update at different rates, and
        // going by the events makes it lag a frame now and then and catch up.
        let overlay = DragOverlay(over: Self.flipped(area), icons: panes.map { NSRunningApplication(processIdentifier: $0.pid)?.icon },
                                  color: accent(), glow: BarSettings.lockInBorder,
                                  frostedCovers: BarSettings.lockInFrostedCovers,
                                  grip: { Self.grip(for: edge, stacked: stacked, among: $0) }) { [weak self] in
            guard let self, self.dividerMoved else { return nil }
            // Let go without the edge hearing of it (Mission Control opening mid-drag, say).
            if NSEvent.pressedMouseButtons & 1 == 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.dividerReleased() } }
                return nil
            }
            return self.framesWhileDragging()?.map(Self.flipped)
        }
        overlay.move(frames.map(Self.flipped))
        self.overlay = overlay
        // It draws the glow while you drag; the usual one steps aside.
        glows.forEach { $0.hide() }
    }

    /// Where they all go with the edge being dragged where the pointer is now.
    private func framesWhileDragging() -> [CGRect]? {
        let mouse = NSEvent.mouseLocation
        switch draggedEdge {
        case .upright: return stacked ? stack(columnTo: mouse.x - grabOffset) : split(at: mouse.x - grabOffset)
        case .across: return stack(rowsTo: mouse.y + grabOffset)
        }
    }

    /// Where the three go with the edge beside the stack's left side at `x`, or the edge between
    /// the stacked two's top at `y` (in the usual bottom-up screen coordinates).
    private func stack(columnTo x: CGFloat? = nil, rowsTo y: CGFloat? = nil) -> [CGRect]? {
        guard !ended, stacked, let area else { return nil }
        let gap = CGFloat(BarSettings.lockInGap)
        let width = area.width - gap, height = area.height - gap
        var column = draggedWidth ?? (width * CGFloat(BarSettings.lockInStackColumn)).rounded()
        var top = draggedHeight ?? (height * CGFloat(BarSettings.lockInStackRows)).rounded()
        if let x {
            column = min(max((x + DividerPanel.overlap - area.minX).rounded(), max(160, width * 0.12)), width * 0.7)
            draggedWidth = column
        }
        if let y {
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            top = min(max((mainHeight - y + DividerPanel.overlap - area.minY).rounded(), max(100, height * 0.12)), height * 0.88)
            draggedHeight = top
        }
        return Self.stack(in: area, gap: gap, column: column, top: top)
    }

    /// Where the grip goes among the covers (in the overlay's own, bottom-up coordinates) while
    /// an edge is dragged.
    private static func grip(for edge: Edge, stacked: Bool, among frames: [NSRect]) -> NSRect? {
        switch edge {
        case .upright where stacked:
            guard frames.count == 3 else { return nil }
            return NSRect(x: (frames[0].maxX + frames[2].minX) / 2 - 2, y: frames[2].midY - 22, width: 4, height: 44)
        case .upright:
            guard frames.count == 2 else { return nil }
            let left = frames[0], right = frames[1]
            let midY = (max(left.minY, right.minY) + min(left.maxY, right.maxY)) / 2
            return NSRect(x: (left.maxX + right.minX) / 2 - 2, y: midY - 22, width: 4, height: 44)
        case .across:
            // Bottom-up, so the top one is the higher.
            guard frames.count == 3 else { return nil }
            return NSRect(x: frames[0].midX - 22, y: (frames[0].minY + frames[1].maxY) / 2 - 2, width: 44, height: 4)
        }
    }

    /// Where the two go with the edge's left side at `x`: the left window ends there and the right
    /// one starts after the gap.
    private func split(at x: CGFloat) -> [CGRect]? {
        guard !ended, panes.count == 2, let area else { return nil }
        let gap = CGFloat(BarSettings.lockInGap)
        let usable = area.width - gap
        let narrowest = max(120, usable * 0.2, minimumWidths[panes[0].id] ?? 0)
        let widest = max(narrowest, min(usable * 0.8, usable - max(120, minimumWidths[panes[1].id] ?? 0)))
        let width = min(max((x + DividerPanel.overlap - area.minX).rounded(), narrowest), widest)
        let left = CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
        let right = CGRect(x: left.maxX + gap, y: area.minY, width: area.maxX - left.maxX - gap, height: area.height)
        draggedWidth = width
        return [left, right]
    }

    private func dividerReleased() {
        guard holding else { return }
        holding = false
        let overlay = self.overlay
        self.overlay = nil
        // Where you let go.
        let goals = dividerMoved ? framesWhileDragging() : nil
        // The covers stay where you let go, rather than following the pointer while the apps resize.
        dividerMoved = false
        guard let goals, goals.count == panes.count, let area else {
            // Taken hold of without being moved.
            overlay?.finish()
            dragging = false
            updateDecorations()
            return
        }
        let gap = CGFloat(BarSettings.lockInGap)
        if stacked {
            if let width = draggedWidth { BarSettings.lockInStackColumn = Double(min(0.7, max(0.1, width / (area.width - gap)))) }
            if let height = draggedHeight { BarSettings.lockInStackRows = Double(min(0.9, max(0.1, height / (area.height - gap)))) }
        } else if let width = draggedWidth {
            BarSettings.lockInSplit = Self.clampSplit(width / (area.width - gap))
        }
        draggedWidth = nil
        draggedHeight = nil
        // Now the apps resize, once each, out of sight under the covers.
        overlay?.move(goals.map(Self.flipped))
        drawnFrames = goals
        let inPlace = placed(goals)
        movesAsked += 1
        for (mover, goal) in zip(movers, inPlace) { mover.move(to: goal) }
        let thisDrag = drag
        WindowMover.whenIdle(movers) { [weak self] in
            // A moment for the apps to draw at their new size before the covers lift.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.ended, self.drag == thisDrag else { overlay?.finish(); return }
                    self.dragging = false
                    // The glow and the edge go where the windows were put, straight away, without
                    // asking the apps; a look a moment later makes room for one that wouldn't go
                    // as narrow as asked.
                    self.knownFrames = inPlace
                    self.updateDecorations(inPlace)
                    overlay?.finish()
                    self.scheduleSettle()
                }
            }
        }
    }

    /// From the system's window coordinates (measured down from the top of the main screen) to the
    /// usual bottom-up screen coordinates.
    private static func flipped(_ rect: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Windows opening on the desktop

    /// Windows of other apps that open on the desktop while it's locked in go to a desktop that isn't
    /// locked in: the one showing on another screen, when there is one (macOS lets apps move windows
    /// between screens), or else the next one you go to on this screen (macOS doesn't let apps move
    /// windows between desktops, so it's minimized until you get there, and comes back there).
    func moveNewcomers() {
        guard !ended, !dragging, showing, !arriving else { return }
        // Nothing on screen has changed since the last look: nothing new can have opened. (Every
        // fourth time it looks anyway, for a window that was still fading in or growing then.)
        let numbers = OnScreenWindows.numbers().sorted()
        looks += 1
        guard numbers != lastLookedAt || numbers.isEmpty || looks % 4 == 0 else { return }
        let mine = Set(panes.map(\.pid))
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenArea = screen.map { CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        let space = self.space
        // The windows on screen are listed off the main thread, as is everything asked of their apps:
        // macOS can be slow to list them while it's busy, and an app that's just opened slow to answer.
        arriving = true
        LockIn.windowQueue.async { [weak self] in
            let me = getpid()
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let seen = list.compactMap { info -> (pid: pid_t, id: CGWindowID)? in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me, !mine.contains(pid),
                      let id = info[kCGWindowNumber as String] as? CGWindowID,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 80, rect.height >= 60,
                      screenArea.map({ $0.intersects(rect) }) ?? true,
                      WindowSpaces.spaceIDs(of: id) == [space] else { return nil }
                return (pid, id)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sortNewcomers(seen, numbers: numbers, mainHeight: mainHeight) }
            }
        }
    }

    /// Which of the other apps' windows `seen` on the desktop are new to it, and sends those on.
    private func sortNewcomers(_ seen: [(pid: pid_t, id: CGWindowID)], numbers: [UInt], mainHeight: CGFloat) {
        guard !ended else { return arriving = false }
        var found: [pid_t: Set<CGWindowID>] = [:]
        for (pid, id) in seen {
            guard !keptApps.contains(pid), !Games.isGame(pid), !BarSettings.lockInAllows(pid),
                  checkingApp.map({ NSRunningApplication(processIdentifier: pid)?.executableURL == $0 }) ?? true else { continue }
            // You brought this one back after lock-in put it away: you want it here.
            if putAway.contains(id) { keptWindows.insert(id) }
            guard !keptWindows.contains(id) else { continue }
            found[pid, default: []].insert(id)
        }
        // Only a look that found nothing to do counts as done: a window found but not dealt with yet
        // (its app still opening) is looked for again next time.
        guard !found.isEmpty else {
            arriving = false
            return lastLookedAt = numbers
        }
        let elsewhere = NSScreen.screens.first { screen in
            screen.displayID != display
                && WindowSpaces.currentSpaceID(on: screen).map(LockIn.lockedSpaces.contains) != true
        }
        // Where on the other screen they'd go, in window coordinates.
        let room = elsewhere.map { screen -> CGRect in
            let room = screen.visibleFrame.insetBy(dx: 40, dy: 40)
            return CGRect(x: room.minX, y: mainHeight - room.maxY, width: room.width, height: room.height)
        }
        let work = found.map { (pid: $0.key, ids: $0.value) }
        LockIn.windowQueue.async { [weak self] in
            let arrivals = work.map { Self.deal(with: $0.pid, windows: $0.ids, room: room) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.arrived(arrivals) }
            }
        }
    }

    /// One app's new windows on the desktop, and what was done with them.
    private struct Arrival: @unchecked Sendable {
        let pid: pid_t
        /// Whether the app listed its windows: one that doesn't can only be hidden.
        var listed = false
        var moved = false
        /// Those minimized, to open on the next desktop.
        var sent: [AwayWindow] = []
    }

    /// A window lock-in minimized, with its app and its number.
    struct AwayWindow: @unchecked Sendable {
        let window: AXUIElement
        let pid: pid_t
        let id: CGWindowID
    }

    /// Whether apps are being asked about new windows right now; the next look waits till they've answered.
    private var arriving = false

    /// Moves the app's windows `ids` to `room` on the other screen, or minimizes them when there's
    /// no other screen to go to.
    nonisolated private static func deal(with pid: pid_t, windows ids: Set<CGWindowID>, room: CGRect?) -> Arrival {
        var arrival = Arrival(pid: pid)
        // Off the main thread, so an app that's just opened has the usual half second to answer.
        let app = AXUIElementCreateApplication(pid)
        let windows = (LockIn.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard !windows.isEmpty else { return arrival }
        arrival.listed = true
        for window in windows {
            guard let id = AppWindowList.windowID(of: window), ids.contains(id),
                  (LockIn.attribute(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole else { continue }
            if let room {
                if let frame = LockIn.frame(of: window), frame.width > room.width || frame.height > room.height {
                    setSize(window, CGSize(width: min(frame.width, room.width), height: min(frame.height, room.height)))
                }
                setPosition(window, room.origin)
                arrival.moved = true
            } else {
                // An app too busy to answer in time may still do it: whether it did is looked at later.
                let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                if result == .success || result == .cannotComplete { arrival.sent.append(AwayWindow(window: window, pid: pid, id: id)) }
            }
        }
        return arrival
    }

    /// Back on the main thread, after the apps with new windows have been dealt with.
    private func arrived(_ arrivals: [Arrival]) {
        arriving = false
        let sentWindows = arrivals.flatMap(\.sent)
        // Unlocked meanwhile: what went away comes straight back.
        guard !ended else { return LockIn.unminimize(sentWindows.map(\.window)) }
        var hidAny = false
        var moved: [NSRunningApplication] = [], hidden: [NSRunningApplication] = []
        for arrival in arrivals {
            let pid = arrival.pid
            let running = NSRunningApplication(processIdentifier: pid)
            // Apps that can't be moved one window at a time are hidden instead. (Games starting up
            // were left alone: it may be a match you're joining.)
            if !arrival.listed {
                if hiddenApps.contains(pid) {
                    // Hidden once already, and you've brought it back: you want it here.
                    keptApps.insert(pid)
                } else if BarSettings.lockInHideOthers {
                    hide([pid])
                    hidAny = true
                    if let running { hidden.append(running) }
                }
                continue
            }
            if arrival.moved, let running, !moved.contains(running) { moved.append(running) }
            for away in arrival.sent {
                putAway.insert(away.id)
                onSendAway(away.window)
            }
        }
        let tuckedAny = !sentWindows.isEmpty
        // An app whose window was just tucked away is still the one in front: go back to the two.
        if tuckedAny { raiseLastUsed() }
        if tuckedAny || hidAny { onPutAway() }
        afterMinimizing(sentWindows) { [weak self] stuck in
            guard let self else { return }
            var sent = sentWindows, hidden = hidden
            if !stuck.isEmpty {
                self.onKeep(stuck.map(\.window))
                let pids = Set(stuck.map(\.pid))
                if BarSettings.lockInHideOthers {
                    // Their apps are hidden instead.
                    self.hide(pids)
                    sent.removeAll { pids.contains($0.pid) }
                    for pid in pids {
                        if let app = NSRunningApplication(processIdentifier: pid), !hidden.contains(app) { hidden.append(app) }
                    }
                    self.onPutAway()
                } else {
                    self.keptWindows.formUnion(stuck.map(\.id))
                    sent.removeAll { entry in stuck.contains { $0.id == entry.id } }
                }
            }
            self.tell(sent: sent, moved: moved, hidden: hidden)
        }
    }

    /// Some windows can't be minimized: macOS says it's done, and nothing happens. A moment later
    /// (minimizing takes that long to show), `then` is given those still showing, which no longer
    /// count as put away.
    private func afterMinimizing(_ windows: [AwayWindow], then: @escaping ([AwayWindow]) -> Void) {
        guard !windows.isEmpty else { return then([]) }
        // The apps are asked off the main thread, as when the windows were minimized.
        LockIn.windowQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            // Only one that says it isn't minimized: one that doesn't answer may well be.
            let stuck = windows.filter { (LockIn.attribute($0.window, kAXMinimizedAttribute) as? Bool) == false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.ended else { return }
                    self.putAway.subtract(stuck.map(\.id))
                    then(stuck)
                }
            }
        }
    }

    /// Says under the bar what was just done with windows that opened here, with a button that
    /// undoes it, for an app you opened on purpose.
    private func tell(sent: [AwayWindow], moved: [NSRunningApplication], hidden: [NSRunningApplication]) {
        var apps: [NSRunningApplication] = []
        for away in sent {
            if let app = NSRunningApplication(processIdentifier: away.pid), !apps.contains(app) { apps.append(app) }
        }
        let keep: () -> Void = { [weak self] in self?.keepHere(sent, apps: hidden) }
        if let app = apps.first {
            onNotice(apps.count == 1 ? "\(app.localizedName ?? "That app") will open on your next desktop"
                                     : "\(apps.count) apps will open on your next desktop", app.icon, keep)
        } else if let app = moved.first {
            onNotice(moved.count == 1 ? "Moved \(app.localizedName ?? "that app") to your other screen"
                                      : "Moved \(moved.count) apps to your other screen", app.icon, nil)
        } else if let app = hidden.first {
            onNotice(hidden.count == 1 ? "Hid \(app.localizedName ?? "that app") until you unlock"
                                       : "Hid \(hidden.count) apps until you unlock", app.icon, keep)
        }
    }

    /// Brings back windows just sent away and apps just hidden, as asked from the note: they stay
    /// here, in front of the locked-in windows, until you unlock.
    private func keepHere(_ windows: [AwayWindow], apps: [NSRunningApplication]) {
        guard !ended else { return }
        keptWindows.formUnion(windows.map(\.id))
        if !windows.isEmpty { onKeep(windows.map(\.window)) }
        for app in apps {
            keptApps.insert(app.processIdentifier)
            app.unhide()
        }
        if let first = windows.first {
            // Brought forward, which brings it back; any others once it's back, so the app isn't
            // asked while it's busy bringing it back.
            WindowFocus.raise(first.window, id: first.id, of: first.pid)
            let rest = windows.dropFirst().map(\.window)
            guard !rest.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { LockIn.unminimize(rest) }
        } else if let app = apps.first {
            app.activate()
        }
    }

    // MARK: Watching them

    private func watch() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var asks: [(observer: AXObserver, element: AXUIElement)] = []
        for pane in panes {
            if observers[pane.pid] == nil {
                var created: AXObserver?
                guard AXObserverCreate(pane.pid, { _, element, notification, refcon in
                    guard let refcon else { return }
                    let session = Unmanaged<LockInSession>.fromOpaque(refcon).takeUnretainedValue()
                    let name = notification as String
                    MainActor.assumeIsolated { session.windowChanged(element, name) }
                }, &created) == .success, let observer = created else { continue }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                observers[pane.pid] = observer
            }
            guard let observer = observers[pane.pid] else { continue }
            asks.append((observer, pane.element))
        }
        // Each app is asked to say when its window changes off the main thread, like everything
        // else asked of them: an app that's busy (minimizing another of its windows, say) answers
        // only once it's done. The notes still arrive on the main thread.
        let address = UInt(bitPattern: refcon)
        Self.paneQueue.async {
            for (observer, element) in asks {
                for name in Self.windowNotifications {
                    AXObserverAddNotification(observer, element, name as CFString, UnsafeMutableRawPointer(bitPattern: address))
                }
            }
        }
    }

    private func windowChanged(_ element: AXUIElement, _ notification: String) {
        guard !ended else { return }
        if notification == kAXUIElementDestroyedNotification {
            // One of the two closed: lock-in is over here.
            if panes.contains(where: { CFEqual($0.element, element) }) {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onEnd() } }
            }
            return
        }
        // One of the two was minimized: nothing to draw round, or fit, until it's back.
        if let pane = panes.first(where: { CFEqual($0.element, element) }) {
            if notification == kAXWindowMiniaturizedNotification {
                minimized.insert(pane.id)
                return hideDecorations()
            }
            if notification == kAXWindowDeminiaturizedNotification { minimized.remove(pane.id) }
        }
        // The moves Clear Dock is making as you drag the edge between them need nothing more.
        if dragging { return }
        // Mission Control shrinking them into its overview (and growing them back) isn't you
        // moving them: nothing to put right, and resizing apps then would only make it stutter.
        if LockIn.missionControlOpen { return }
        // You're moving or resizing one yourself: the glow and the edge step aside until you let go,
        // rather than asking the app where its window is at every step.
        if NSEvent.pressedMouseButtons != 0 { hideDecorations() }
        scheduleSettle()
    }

    /// Settles them shortly, once the mouse button is up, so it never fights a drag you're in the middle of.
    private func scheduleSettle() {
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ended, !self.dragging else { return }
                if NSEvent.pressedMouseButtons != 0 { return self.scheduleSettle() }
                self.settle()
            }
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: The glowing edges and the edge between them

    /// Draws the glow round both windows and puts the edge between them, while the desktop is
    /// showing: where the windows are given as `frames` (in the system's window coordinates), or
    /// else where they are now.
    func updateDecorations(_ frames: [CGRect]? = nil) {
        if dragging, frames == nil { return }
        guard !ended, showing, !LockIn.missionControlOpen, minimized.isEmpty else { return hideDecorations() }
        guard let frames else {
            // Where they are, once their apps have said.
            return look { [weak self] found in
                // A drag of the edge may have begun meanwhile; it draws its own.
                guard let self, !self.dragging, let frames = self.frames(from: found) else { return }
                self.updateDecorations(frames)
            }
        }
        guard frames.count == panes.count else { return hideDecorations() }
        drawnFrames = frames
        knownFrames = frames
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func flipped(_ rect: CGRect) -> NSRect { NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height) }
        if BarSettings.lockInBorder {
            // Softer against the calm backdrop, which already sets the windows apart.
            let colour = backdrop != nil ? accent().withAlphaComponent(0.6) : accent()
            for (glow, frame) in zip(glows, frames) { glow.show(around: flipped(frame), color: colour) }
        } else {
            glows.forEach { $0.hide() }
        }
        // With just one window there's no edge between.
        guard panes.count > 1 else {
            divider.orderOut(nil)
            return rowDivider.orderOut(nil)
        }
        // The edges, a little over each window, so they're easy to take hold of. Beside a window
        // that won't fill its place, the edge goes where the places meet.
        let overlap = DividerPanel.overlap
        let places = targets
        let edges = places.count == frames.count
            ? zip(panes, zip(frames, places)).map { pane, both in largestSizes[pane.id] == nil ? both.0 : both.1 }
            : frames
        // Upright: between the left and the right, or between the stack and the big one.
        let left = stacked ? edges[0].union(edges[1]) : edges[0], right = edges[stacked ? 2 : 1]
        let top = max(left.minY, right.minY), bottom = min(left.maxY, right.maxY)
        if right.minX >= left.maxX - 1, bottom - top > 60 {
            divider.show(at: flipped(CGRect(x: left.maxX - overlap, y: top, width: right.minX - left.maxX + overlap * 2, height: bottom - top)))
        } else {
            divider.orderOut(nil)
        }
        // Across: between the two stacked ones.
        guard stacked else { return rowDivider.orderOut(nil) }
        let upper = edges[0], lower = edges[1]
        let start = max(upper.minX, lower.minX), end = min(upper.maxX, lower.maxX)
        if lower.minY >= upper.maxY - 1, end - start > 60 {
            rowDivider.show(at: flipped(CGRect(x: start, y: upper.maxY - overlap, width: end - start, height: lower.minY - upper.maxY + overlap * 2)))
        } else {
            rowDivider.orderOut(nil)
        }
    }

    /// After switching desktops or leaving Mission Control: put the glow and the edge back where
    /// the windows were (busy apps can be slow to say where they are, which would hold things up).
    func showDecorationsAgain() {
        // Not under an edge being dragged: the drag draws its own, and puts these back when it ends.
        guard !dragging else { return }
        updateBackdrop()
        updateDecorations(knownFrames)
    }

    private func hideDecorations() {
        drawnFrames = nil
        divider.orderOut(nil)
        rowDivider.orderOut(nil)
        glows.forEach { $0.hide() }
    }

    private func currentFrames() -> [CGRect]? {
        guard minimized.isEmpty else { return nil }
        let frames = panes.compactMap { LockIn.frame(of: $0.element) }
        return frames.count == panes.count ? frames : nil
    }

    /// The windows' frames in `panes`' order, from `found` (by window), if every one is there.
    private func frames(from found: [CGWindowID: CGRect]) -> [CGRect]? {
        guard minimized.isEmpty else { return nil }
        let frames = panes.compactMap { found[$0.id] }
        return frames.count == panes.count ? frames : nil
    }

    /// Where lock-in asks the apps where the windows are, and moves them, in turn: off the main
    /// thread, as an app busy redrawing at a new size (or minimizing another of its windows)
    /// answers only once it's done. One for every desktop, so unlocking and locking in again
    /// straight away can't overlap.
    nonisolated private static let paneQueue = DispatchQueue(label: "Clear Dock lock-in", qos: .userInteractive)
    /// Counts the times the windows were sent somewhere, so a look asked for before the latest
    /// move (and maybe answered before it was made) isn't taken for where they are now.
    private var movesAsked = 0

    /// Where the windows are now, by window, handed to `then` on the main thread. With
    /// `unlessMissionControl`, not while Mission Control is open (it may have opened before the
    /// bar's check noticed): where it shows the windows isn't where they are.
    private func look(unlessMissionControl: Bool = false, _ then: @escaping @MainActor ([CGWindowID: CGRect]) -> Void) {
        let panes = self.panes.map { (id: $0.id, element: $0.element) }
        let asked = movesAsked
        Self.paneQueue.async { [weak self] in
            if unlessMissionControl, MissionControl.isShowing { return }
            var found: [CGWindowID: CGRect] = [:]
            for pane in panes { found[pane.id] = LockIn.frame(of: pane.element) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.ended else { return }
                    // Sent somewhere since this was asked: ask again, once they've gone there.
                    guard self.movesAsked == asked else { return self.look(unlessMissionControl: unlessMissionControl, then) }
                    then(found)
                }
            }
        }
    }

    // MARK: Helpers

    /// In place, allowing for apps like Terminal that round their size to whole lines of text.
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }

    nonisolated private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    nonisolated private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
    }
}

/// Moves and sizes one window through Accessibility on a queue of its own, always to the latest
/// frame asked for. While the app is still busy with one change, newer ones replace each other, so
/// it never works through old ones, and Clear Dock never waits on it.
final class WindowMover: @unchecked Sendable {
    private let element: AXUIElement
    private let queue = DispatchQueue(label: "ClearDock.WindowMover", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: CGRect?
    private var draining = false
    /// The frame last given to the window (only used on the queue).
    private var applied: CGRect?

    init(_ element: AXUIElement) {
        self.element = element
    }

    /// Moves the window to `frame`, in the system's window coordinates, as soon as the app is ready.
    func move(to frame: CGRect) {
        lock.lock()
        pending = frame
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Returns once the window has been moved to the last frame asked for.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// Something else may have moved the window since; don't count on where it was put last.
    func forget() {
        queue.async { self.applied = nil }
    }

    /// Calls `body` on the main queue once every mover has done all it was asked to.
    static func whenIdle(_ movers: [WindowMover], _ body: @escaping @MainActor () -> Void) {
        let group = DispatchGroup()
        for mover in movers {
            group.enter()
            mover.queue.async { group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated(body) }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            apply(frame)
        }
    }

    private func apply(_ frame: CGRect) {
        let previous = applied
        applied = frame
        let moves = previous?.origin != frame.origin
        let resizes = previous?.size != frame.size
        // In whichever order keeps the step in between off the edge of the screen, rather than
        // over the other window: growing to the left, it grows first and then moves; otherwise
        // it moves first.
        if moves && resizes, let previous, frame.minX < previous.minX {
            setSize(frame.size)
            setPosition(frame.origin)
        } else {
            if moves { setPosition(frame.origin) }
            if resizes { setSize(frame.size) }
        }
    }

    private func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    private func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }
}

/// Behind a locked-in desktop's windows: a still, softly blurred and dimmed picture of the
/// wallpaper, over the wallpaper itself and the desktop's icons, so a moving wallpaper doesn't
/// pull the eye (and macOS needn't keep drawing what's under it). It stays on the locked-in
/// desktop only, out of Mission Control, takes no clicks, and goes when the desktop is unlocked.
@MainActor
final class CalmBackdrop {
    private let panel: NSPanel
    private let picture = CALayer()
    private var gone = false

    init(covering screen: NSScreen) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = NSColor(white: 0.06, alpha: 1)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        // Just above the desktop's icons, below every app's windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        // On the desktop it's shown on only, and left out of Mission Control.
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        picture.frame = view.bounds
        picture.contentsGravity = .resizeAspectFill
        picture.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(picture)
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let displayID = screen.displayID
        let size = CGSize(width: (screen.frame.width / 3).rounded(), height: (screen.frame.height / 3).rounded())
        Task { @MainActor [weak self] in
            let image = await Self.calmPicture(display: displayID, size: size)
            guard let self, !self.gone else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.picture.contents = image
            CATransaction.commit()
            let panel = self.panel
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                panel.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    /// Follows the screen if it changes size.
    func cover(_ screen: NSScreen) {
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
    }

    func finish() {
        gone = true
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.close() }
        }
    }

    /// The wallpaper as it looks (a live one included, as it is right now), small, blurred and dimmed.
    nonisolated static func calmPicture(display: CGDirectDisplayID?, size: CGSize) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first else { return nil }
        // Only the wallpaper: everything above it (the desktop's icons, every window) is left out.
        let wallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowLayer > wallpaperLevel })
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        guard let still = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let calm = soften(still)
        if let calm { DebugSnapshot.save(calm, name: "calm") }
        return calm
    }

    /// Blurred, a little greyer and much darker. Done on the processor: for a picture this small
    /// that takes a few milliseconds, where setting up the graphics card for it took over a
    /// hundred megabytes for a moment.
    nonisolated private static func soften(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowBytes = context.bytesPerRow
        guard let spare = malloc(rowBytes * height) else { return nil }
        defer { free(spare) }
        var picture = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var other = vImage_Buffer(data: spare, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        // Three box blurs in a row come close to a Gaussian blur, of about 14 pixels.
        let edges = vImage_Flags(kvImageEdgeExtend)
        vImageBoxConvolve_ARGB8888(&picture, &other, nil, 0, 0, 29, 29, nil, edges)
        vImageBoxConvolve_ARGB8888(&other, &picture, nil, 0, 0, 29, 29, nil, edges)
        vImageBoxConvolve_ARGB8888(&picture, &other, nil, 0, 0, 29, 29, nil, edges)
        // Greyer and darker in one step: the colours keep 80% of their saturation, lose 18% of
        // their brightness, and are then taken 1.1 stops down.
        let saturation = 0.8, exposure = pow(2, -1.1), lift = -0.18
        // In memory the channels go blue, green, red, then alpha; these are their shares of brightness.
        let shares = [0.0722, 0.7152, 0.2126]
        let divisor: Int32 = 256
        var matrix = [Int16](repeating: 0, count: 16)
        for input in 0..<3 {
            for output in 0..<3 {
                let share = shares[input] * (1 - saturation) + (input == output ? saturation : 0)
                matrix[input * 4 + output] = Int16((share * exposure * Double(divisor)).rounded())
            }
        }
        matrix[15] = Int16(divisor)
        let bias = Int32((lift * 255 * exposure * Double(divisor)).rounded())
        let postBias: [Int32] = [bias, bias, bias, 0]
        vImageMatrixMultiply_ARGB8888(&other, &picture, matrix, divisor, nil, postBias, vImage_Flags(kvImageNoFlags))
        return context.makeImage()
    }
}

/// An edge between two windows: a thin strip of Clear Dock's own over the gap, a little over
/// each window, so dragging it is handled here, straight away, instead of by the apps (which can
/// be slow to resize themselves). It shows a small grip, like a split view's. An upright one is
/// dragged sideways; one `across` (between two stacked windows) up and down.
@MainActor
final class DividerPanel: NSPanel {
    /// How far it reaches over each window.
    static let overlap: CGFloat = 4

    let across: Bool
    /// Where on the edge it was taken hold of: from its left side, or from its top when across.
    var onBegin: (CGFloat) -> Void = { _ in }
    /// The edge's new left side (or top), as you drag it.
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    init(across: Bool) {
        self.across = across
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        level = .floating
        // On the desktop it's shown on, and left out of Mission Control.
        collectionBehavior = [.transient, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = DividerView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `frame` in the usual bottom-up screen coordinates.
    func show(at frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: true) }
        (contentView as? DividerView)?.gripHidden = false
        if !isVisible { orderFrontRegardless() }
    }
}

private final class DividerView: NSView {
    /// From taking hold of it until it's put where the windows ended up: the covers draw the grip
    /// meanwhile, where the pointer is.
    var gripHidden = false { didSet { if gripHidden != oldValue { needsDisplay = true } } }
    private var grabbedAt: CGFloat = 0
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }

    private var panel: DividerPanel? { window as? DividerPanel }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private var across: Bool { panel?.across == true }
    private var cursor: NSCursor { across ? .resizeUpDown : .resizeLeftRight }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseMoved(with event: NSEvent) { cursor.set() }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        gripHidden = true
        // Where on the edge you took hold of it, so it doesn't jump to the pointer.
        let mouse = NSEvent.mouseLocation
        grabbedAt = across ? (window?.frame.maxY ?? 0) - mouse.y : mouse.x - (window?.frame.minX ?? 0)
        panel?.onBegin(grabbedAt)
    }

    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        let mouse = NSEvent.mouseLocation
        panel?.onDrag(across ? mouse.y + grabbedAt : mouse.x - grabbedAt)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        panel?.onEnd()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Very nearly clear: a window that's fully clear somewhere lets clicks through there.
        NSColor.white.withAlphaComponent(0.004).setFill()
        bounds.fill()
        guard !gripHidden else { return }
        let grip = across ? NSRect(x: bounds.midX - 22, y: bounds.midY - 2, width: 44, height: 4)
            : NSRect(x: bounds.midX - 2, y: bounds.midY - 22, width: 4, height: 44)
        NSColor.white.withAlphaComponent(hovering ? 0.7 : 0.35).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }
}

/// A glowing rounded edge just outside a window, drawn as four thin strips (one along each side)
/// rather than one see-through window the size of the window, which keeps its memory and drawing
/// small. It never takes clicks, and sits on the lock-in desktop only.
@MainActor
final class GlowFrame {
    static let margin: CGFloat = 10
    static let lineWidth: CGFloat = 3
    /// Close to the corners of macOS windows.
    static let cornerRadius: CGFloat = 14
    /// How deep each strip is: the margin outside the window, and a little way in for the glow.
    private static let depth: CGFloat = 22

    private let strips = (0..<4).map { _ in GlowStrip() }

    func hide() {
        strips.forEach { $0.orderOut(nil) }
    }

    func bringForward() {
        for strip in strips where strip.isVisible { strip.orderFrontRegardless() }
    }

    /// `window` is the window's frame in the usual bottom-up screen coordinates.
    func show(around window: NSRect, color: NSColor) {
        let outer = window.insetBy(dx: -Self.margin, dy: -Self.margin)
        let inset = Self.margin - Self.lineWidth / 2 - 1
        let edge = outer.insetBy(dx: inset, dy: inset)
        let radius = Self.cornerRadius + Self.lineWidth / 2 + 1
        let depth = min(Self.depth, outer.width / 2, outer.height / 2)
        let frames = [
            NSRect(x: outer.minX, y: outer.maxY - depth, width: outer.width, height: depth),
            NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: depth),
            NSRect(x: outer.minX, y: outer.minY + depth, width: depth, height: outer.height - depth * 2),
            NSRect(x: outer.maxX - depth, y: outer.minY + depth, width: depth, height: outer.height - depth * 2),
        ]
        for (strip, frame) in zip(strips, frames) {
            strip.show(frame, edge: edge, radius: radius, lineWidth: Self.lineWidth, color: color)
        }
    }
}

/// One side of a `GlowFrame`.
private final class GlowStrip: NSPanel {
    private let outline = CAShapeLayer()
    private var shown: (frame: NSRect, edge: NSRect, color: NSColor)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = .floating
        // On the desktop it's shown on, and left out of Mission Control.
        collectionBehavior = [.transient, .ignoresCycle]
        isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        outline.fillColor = nil
        outline.shadowOpacity = 0.9
        outline.shadowRadius = 6
        outline.shadowOffset = .zero
        view.layer?.addSublayer(outline)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Draws its own part of the whole `edge` (both in bottom-up screen coordinates).
    func show(_ frame: NSRect, edge: NSRect, radius: CGFloat, lineWidth: CGFloat, color: NSColor) {
        if let shown, shown.frame == frame, shown.edge == edge, shown.color == color {
            if !isVisible { orderFrontRegardless() }
            return
        }
        shown = (frame, edge, color)
        setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = NSRect(origin: .zero, size: frame.size)
        let path = CGPath(roundedRect: edge.offsetBy(dx: -frame.minX, dy: -frame.minY), cornerWidth: radius, cornerHeight: radius, transform: nil)
        outline.path = path
        outline.lineWidth = lineWidth
        // Telling it the glow's shape spares it working that out from the drawing, which is slow.
        outline.shadowPath = path.copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        outline.strokeColor = color.cgColor
        outline.shadowColor = color.cgColor
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }
}

/// What you see while you drag the edge between the two windows: one see-through window over the
/// lock-in space holding a cover over each window (with its app's icon), their glow and the grip.
/// Covers are plain (a tinted shape, next to no work to resize) or frosted (a live blur of what's
/// behind, which macOS has to work out again at every size). Everything in it moves together, once per screen refresh, to wherever the pointer has got
/// to, so the pieces never drift apart, and nothing in it asks the apps anything. Made when you
/// take hold of the edge and let go of when you let go, so it uses no memory the rest of the time.
@MainActor
final class DragOverlay: NSObject {
    /// How far past the windows it reaches, for the glow.
    private static let reach: CGFloat = GlowFrame.margin + 8

    private let panel: NSPanel
    private let origin: NSPoint
    /// Holds the covers, so they fade in and out together.
    private let coverHost = NSView()
    private var frosted: [NSVisualEffectView] = []
    private var iconViews: [NSImageView] = []
    private var plain: [CALayer] = []
    private var iconLayers: [CALayer] = []
    private var glows: [CAShapeLayer] = []
    private let grip = CALayer()
    /// Where the windows go right now, asked at each refresh of the screen.
    private let follow: () -> [NSRect]?
    /// Where the grip goes, among the covers.
    private let gripFrame: ([NSRect]) -> NSRect?
    private var shown: [NSRect] = []
    private var link: CADisplayLink?

    /// `area` is the lock-in space, in the usual bottom-up screen coordinates.
    init(over area: NSRect, icons: [NSImage?], color: NSColor, glow: Bool, frostedCovers: Bool,
         grip gripFrame: @escaping ([NSRect]) -> NSRect?, follow: @escaping () -> [NSRect]?) {
        let frame = area.insetBy(dx: -Self.reach, dy: -Self.reach)
        origin = frame.origin
        self.follow = follow
        self.gripFrame = gripFrame
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        coverHost.frame = root.bounds
        coverHost.alphaValue = 0
        if frostedCovers {
            for icon in icons {
                let cover = NSVisualEffectView()
                cover.material = .fullScreenUI
                cover.blendingMode = .behindWindow
                cover.state = .active
                cover.maskImage = Self.mask
                let iconView = NSImageView()
                iconView.image = icon
                iconView.imageScaling = .scaleProportionallyUpOrDown
                cover.addSubview(iconView)
                coverHost.addSubview(cover)
                frosted.append(cover)
                iconViews.append(iconView)
            }
        } else {
            coverHost.layer = CALayer()
            coverHost.wantsLayer = true
            // Nearly black, with the faintest hint of the highlight colour, like the glow round it.
            let tint = (NSColor(white: 0.05, alpha: 1).blended(withFraction: 0.07, of: color) ?? .black).withAlphaComponent(0.96)
            let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
            for icon in icons {
                let cover = CALayer()
                cover.backgroundColor = tint.cgColor
                cover.cornerRadius = GlowFrame.cornerRadius
                cover.cornerCurve = .continuous
                cover.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
                cover.borderWidth = 1
                let iconLayer = CALayer()
                iconLayer.contents = icon
                iconLayer.contentsGravity = .resizeAspect
                iconLayer.contentsScale = scale
                iconLayer.opacity = 0.8
                cover.addSublayer(iconLayer)
                coverHost.layer?.addSublayer(cover)
                plain.append(cover)
                iconLayers.append(iconLayer)
            }
        }
        root.addSubview(coverHost)
        // The glow and the grip, above the covers.
        let top = NSView(frame: root.bounds)
        top.layer = CALayer()
        top.wantsLayer = true
        if glow {
            for _ in icons {
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineWidth = GlowFrame.lineWidth
                layer.strokeColor = color.cgColor
                layer.shadowColor = color.cgColor
                layer.shadowOpacity = 0.9
                layer.shadowRadius = 6
                layer.shadowOffset = .zero
                top.layer?.addSublayer(layer)
                glows.append(layer)
            }
        }
        grip.backgroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        grip.cornerRadius = 2
        top.layer?.addSublayer(grip)
        root.addSubview(top)
        panel.contentView = root
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            coverHost.animator().alphaValue = 1
        }
        // In step with the screen's refreshes.
        let link = root.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Puts the windows' covers at `frames`, in the usual bottom-up screen coordinates.
    func move(_ frames: [NSRect]) {
        guard frames != shown else { return }
        shown = frames
        apply(frames)
    }

    /// Lifts the covers, then goes away.
    func finish() {
        link?.invalidate()
        link = nil
        glows.forEach { $0.removeFromSuperlayer() }
        grip.removeFromSuperlayer()
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            coverHost.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.close() }
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        if let frames = follow() { move(frames) }
    }

    private func apply(_ frames: [NSRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let local = frames.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        for (index, frame) in local.enumerated() {
            let side = min(84, frame.width * 0.4, frame.height * 0.4)
            let icon = NSRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
            if index < frosted.count {
                frosted[index].frame = frame
                iconViews[index].frame = icon
            }
            if index < plain.count {
                plain[index].frame = frame
                iconLayers[index].frame = icon
            }
            if index < glows.count {
                let outset = GlowFrame.lineWidth / 2 + 1
                let radius = GlowFrame.cornerRadius + outset
                let path = CGPath(roundedRect: frame.insetBy(dx: -outset, dy: -outset), cornerWidth: radius, cornerHeight: radius, transform: nil)
                glows[index].path = path
                glows[index].shadowPath = path.copy(strokingWithWidth: GlowFrame.lineWidth, lineCap: .butt, lineJoin: .round, miterLimit: 10)
            }
        }
        if let rect = gripFrame(local) { grip.frame = rect }
        CATransaction.commit()
    }

    /// Rounded like a window's corners, stretching to any size.
    private static let mask: NSImage = {
        let radius = GlowFrame.cornerRadius
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}
