import AppKit
import ApplicationServices

/// Lock-in mode: the desktop you're on, given over to two windows side by side, with the wallpaper
/// showing around them and a glowing edge round both. With two apps on the desktop it's
/// those two, straight away; with more, you choose which two, and the rest are tucked away
/// (minimized) until you unlock. It never takes you to another desktop, and each desktop can be
/// locked in on its own.
///
/// The two stay stuck together: drag the edge between them to share the screen differently, or drag
/// one onto the other's side to swap them; anything else snaps back. The dock keeps out of the way
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
    var accent: (NSScreen) -> NSColor = { _ in .systemPurple }
    /// Asks you to choose two of the windows, and calls back with them, left then right, or with
    /// nil if you don't.
    var choose: (_ choices: [Choice], _ screen: NSScreen, _ done: @escaping ([Choice]?) -> Void) -> Void = { _, _, done in done(nil) }
    /// Closes the chooser if it's open.
    var dismissChooser: () -> Void = {}

    /// Locked-in desktops, by the window server's id for them.
    private var sessions: [UInt64: LockInSession] = [:]
    /// The desktop whose two windows you're choosing right now.
    private(set) var choosing: UInt64?
    /// Getting a desktop's windows ready, which takes a moment.
    private(set) var starting = false
    /// Windows tucked away on desktops whose lock-in ended while you were elsewhere. They come back
    /// when you next go there, so they reappear on their own desktop.
    private var waiting: [UInt64: [AXUIElement]] = [:]
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
    func toggle() {
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
                self.lock(desktop, on: screen)
                self.onChange()
            }
        }
    }

    /// Unlocks every desktop and puts back all the windows tucked away: the bar is going away, or
    /// Clear Dock is quitting.
    func endAll() {
        starting = false
        dismissChooser()
        for session in Array(sessions.values) { end(session, now: true) }
        for windows in waiting.values { Self.unminimize(windows) }
        waiting.removeAll()
        updateWatching()
        saveLeftovers()
    }

    private func lock(_ desktop: Desktop, on screen: NSScreen) {
        guard AXIsProcessTrusted() else {
            Self.explain("Lock-in needs Accessibility permission",
                         "Turn on Clear Dock in Privacy & Security > Accessibility, then click Lock In again.")
            return SystemSettings.open("com.apple.preference.security?Privacy_Accessibility")
        }
        let (windows, apart) = Self.windows(on: desktop)
        var apps: [pid_t] = []
        for window in windows where !apps.contains(window.pid) { apps.append(window.pid) }
        switch (windows.count, apps.count) {
        case (..<2, _):
            Self.explain("Lock-in needs two windows on this desktop", "Open the two apps you want side by side here, then click Lock In.")
        case (2, _):
            // Each stays on the side it's on now.
            start(windows.sorted { $0.frame.midX < $1.frame.midX }, of: windows, hiding: apart, on: desktop.id, screen: screen)
        case (_, 2):
            // The front window of each app, each on the side it's on now.
            let fronts = apps.compactMap { pid in windows.first { $0.pid == pid } }
            start(fronts.sorted { $0.frame.midX < $1.frame.midX }, of: windows, hiding: apart, on: desktop.id, screen: screen)
        default:
            choosing = desktop.id
            onChange()
            choose(windows, screen) { [weak self] picked in
                guard let self, self.choosing == desktop.id else { return }
                self.choosing = nil
                self.onChange()
                // Only if you're still on that desktop.
                guard let picked, Self.currentDesktop(on: screen)?.id == desktop.id else { return }
                self.start(picked, of: windows, hiding: apart, on: desktop.id, screen: screen)
            }
        }
    }

    /// Locks in two of the desktop's windows; the rest of `all` are tucked away, and the apps in
    /// `apart` hidden, if that's on.
    private func start(_ picked: [Choice], of all: [Choice], hiding apart: Set<pid_t>, on space: UInt64, screen: NSScreen) {
        guard picked.count == 2, picked[0].id != picked[1].id, let display = screen.displayID, sessions[space] == nil else { return }
        restoreWaiting(on: space)
        let session = LockInSession(space: space, display: display,
                                    panes: picked.map { LockInSession.Pane(pid: $0.pid, element: $0.element, id: $0.id) })
        session.accent = { [weak self, weak session] in
            guard let self, let screen = session?.screen else { return .systemPurple }
            return self.accent(screen)
        }
        session.onEnd = { [weak self, weak session] in
            guard let self, let session else { return }
            self.end(session)
        }
        session.onPutAway = { [weak self] in self?.saveLeftovers() }
        sessions[space] = session
        if BarSettings.lockInHideOthers {
            let kept = Set(picked.map(\.id))
            session.tuck(all.filter { !kept.contains($0.id) }.map(\.element))
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

    /// The gap or the glowing edge setting changed.
    func settingsChanged() {
        for session in sessions.values { session.refit() }
    }

    private func publish() {
        Self.lockedSpaces = Set(sessions.keys)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        onChange()
    }

    /// Unlocks a desktop. Its tucked-away windows come back now if it's showing (or `now` says so),
    /// or else when you next go there, since macOS brings a window back on the desktop you're on.
    private func end(_ session: LockInSession, now: Bool = false) {
        guard sessions[session.space] === session else { return }
        sessions[session.space] = nil
        session.finish()
        // Hidden apps come back on their own desktops, wherever you are.
        session.hiddenApps.forEach { NSRunningApplication(processIdentifier: $0)?.unhide() }
        if now || WindowSpaces.currentSpaceIDs().contains(session.space) {
            Self.unminimize(session.tucked)
        } else if !session.tucked.isEmpty {
            waiting[session.space, default: []] += session.tucked
        }
        updateWatching()
        publish()
        saveLeftovers()
    }

    // MARK: Keeping up with your desktops and apps

    /// Listens to the system only while a desktop is locked in or has windows waiting to come back.
    private func updateWatching() {
        let needed = !sessions.isEmpty || !waiting.isEmpty
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
                center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
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
    }

    private func screensChanged() {
        for session in Array(sessions.values) {
            if session.screen == nil {
                // Its windows have moved to another screen, onto whatever desktop shows there.
                end(session, now: true)
            } else {
                session.refit()
            }
        }
    }

    private func moveNewcomers() {
        for session in sessions.values where session.showing { session.moveNewcomers() }
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
        for window in sessions.values.flatMap(\.tucked) + waiting.values.flatMap({ $0 }) {
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
            if Games.isGame(window.app) {
                apart.insert(window.app)
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
                if elements[window.app]?.isEmpty == true { apart.insert(window.app) }
                continue
            }
            let app = NSRunningApplication(processIdentifier: window.app)
            choices.append(Choice(id: window.id, pid: window.app, element: element, frame: window.frame,
                                  app: app?.localizedName ?? "App", icon: app?.icon,
                                  title: attribute(element, kAXTitleAttribute) as? String))
        }
        // Titles are only needed to tell apart windows of the same app.
        for index in choices.indices where choices.filter({ $0.pid == choices[index].pid }).count < 2 {
            choices[index].title = nil
        }
        return (choices, apart.subtracting(choices.map(\.pid)))
    }

    // MARK: Helpers

    private static func unminimize(_ windows: [AXUIElement]) {
        for window in windows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    private static func explain(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    fileprivate static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    fileprivate static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

}

/// One locked-in desktop: its two windows, kept side by side, and the windows tucked away meanwhile.
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

    /// Left, then right, each with what moves it.
    private var panes: [Pane]
    private var movers: [WindowMover]
    private var ended = false
    /// While you drag the edge between them, and until both apps have caught up afterwards.
    private var dragging = false
    private var draggedWidth: CGFloat?
    /// Where on the edge you took hold of it, from its left side.
    private var grabOffset: CGFloat = 0
    private var dividerMoved = false
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingSettle: DispatchWorkItem?
    private let divider = DividerPanel()
    private let glows = [GlowFrame(), GlowFrame()]
    /// What you see while you drag the edge between them.
    private var overlay: DragOverlay?
    /// Where the two were last drawn round, in the system's window coordinates.
    private var drawnFrames: [CGRect]?
    /// Where the two were last known to be, kept while the glow is put away (on another desktop, or
    /// in Mission Control), so it can come back without asking the apps where they are.
    private var knownFrames: [CGRect]?
    /// How narrow each app has shown it will go, by window, for those that won't go as narrow as asked.
    private var minimumWidths: [CGWindowID: CGFloat] = [:]

    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]

    init(space: UInt64, display: CGDirectDisplayID, panes: [Pane]) {
        self.space = space
        self.display = display
        self.panes = panes
        movers = panes.map { WindowMover($0.element) }
        divider.onBegin = { [weak self] offset in self?.dividerGrabbed(at: offset) }
        divider.onDrag = { [weak self] _ in self?.dividerMoved = true }
        divider.onEnd = { [weak self] in self?.dividerReleased() }
    }

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == display } }

    func involves(_ pid: pid_t) -> Bool { panes.contains { $0.pid == pid } }

    func begin() {
        watch()
        fit()
        // Then make room for an app that wouldn't go as narrow as its share.
        scheduleSettle()
        // Bring one of the two forward, unless you're already using one.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, !involves(front) {
            WindowFocus.raise(panes[0].id, of: panes[0].pid)
        }
    }

    func finish() {
        ended = true
        pendingSettle?.cancel()
        overlay?.finish()
        overlay = nil
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
        for window in windows where AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
            tucked.append(window)
        }
    }

    func refit() {
        guard !ended, !dragging else { return }
        fit()
    }

    // MARK: Keeping them side by side

    /// The space the two windows share: what's free on the screen (under the bar, beside Clear
    /// Dock), with a gap all round showing the wallpaper.
    private var area: CGRect? {
        guard let screen else { return nil }
        let gap = CGFloat(BarSettings.lockInGap)
        let area = DockSpaceKeeper.shared.freeArea(on: screen).insetBy(dx: gap, dy: gap)
        return area.width > 240 && area.height > 120 ? area : nil
    }

    /// Where each window goes, left then right, in the system's window coordinates.
    private var targets: [CGRect] {
        guard let area else { return [] }
        let gap = CGFloat(BarSettings.lockInGap)
        let left = ((area.width - gap) * CGFloat(BarSettings.lockInSplit)).rounded()
        return [
            CGRect(x: area.minX, y: area.minY, width: left, height: area.height),
            CGRect(x: area.minX + left + gap, y: area.minY, width: area.width - left - gap, height: area.height),
        ]
    }

    private func fit() {
        for (pane, target) in zip(panes, targets) {
            guard let frame = LockIn.frame(of: pane.element), !Self.close(frame, target) else { continue }
            // Size, place, and size again: some apps only accept a size that fits where they are.
            Self.setSize(pane.element, target.size)
            Self.setPosition(pane.element, target.origin)
            Self.setSize(pane.element, target.size)
        }
        updateDecorations()
    }

    /// After you've moved or resized one of them yourself: an inner edge dragged sets how they
    /// share the screen, a window dragged over the other's side swaps them, and everything else
    /// snaps back. Also makes room for an app that won't go as narrow as its share.
    private func settle() {
        guard panes.count == 2, let area, let frames = currentFrames() else { return }
        let goals = targets
        let left = frames[0], right = frames[1]
        let gap = CGFloat(BarSettings.lockInGap)
        let usable = area.width - gap
        if left.midX > right.midX {
            panes.swapAt(0, 1)
            movers.swapAt(0, 1)
        } else {
            // Some apps have a smallest size; remember it, so dragging the edge stops there.
            if left.width > goals[0].width + 16 { minimumWidths[panes[0].id] = left.width }
            if right.width > goals[1].width + 16 { minimumWidths[panes[1].id] = right.width }
            if abs(left.minX - goals[0].minX) < 3 && abs(left.maxX - goals[0].maxX) > 3 && abs(left.width - goals[0].width) > 3 {
                BarSettings.lockInSplit = Self.clampSplit((left.maxX - area.minX) / usable)
            } else if abs(right.maxX - goals[1].maxX) < 3 && abs(right.minX - goals[1].minX) > 3 && abs(right.width - goals[1].width) > 3 {
                BarSettings.lockInSplit = Self.clampSplit((right.minX - gap - area.minX) / usable)
            } else if abs(right.minX - goals[1].minX) < 3 && right.width > goals[1].width + 16 {
                // The right one would reach off the screen: give it the room it needs.
                BarSettings.lockInSplit = Self.clampSplit((area.width - gap - right.width) / usable)
            }
        }
        fit()
    }

    private static func clampSplit(_ value: CGFloat) -> Double { Double(min(0.8, max(0.2, value))) }

    // MARK: Dragging the edge between them

    // While you drag the edge, each window is covered by a frosted panel with its app's icon, and
    // the covers, the glow and the grip follow the pointer as freely as any window you drag. The
    // apps themselves are resized once, when you let go: apps built on web pages (TradingView,
    // Discord, Spotify) can't redraw at every width quickly enough to keep up.

    private func dividerGrabbed(at offset: CGFloat) {
        guard !ended, let area, let frames = drawnFrames ?? currentFrames() else { return }
        movers.forEach { $0.forget() }
        dragging = true
        dividerMoved = false
        grabOffset = offset
        // At each refresh of the screen it looks where the pointer is right then, rather than
        // where the last mouse event said: mice and screens update at different rates, and
        // going by the events makes it lag a frame now and then and catch up.
        let overlay = DragOverlay(over: Self.flipped(area), icons: panes.map { NSRunningApplication(processIdentifier: $0.pid)?.icon },
                                  color: accent(), glow: BarSettings.lockInBorder,
                                  frostedCovers: BarSettings.lockInFrostedCovers) { [weak self] in
            guard let self, self.dividerMoved else { return nil }
            return self.split(at: NSEvent.mouseLocation.x - self.grabOffset)?.map(Self.flipped)
        }
        overlay.move(frames.map(Self.flipped))
        self.overlay = overlay
        // It draws the glow while you drag; the usual one steps aside.
        glows.forEach { $0.hide() }
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
        let overlay = self.overlay
        self.overlay = nil
        // Where you let go.
        if dividerMoved { _ = split(at: NSEvent.mouseLocation.x - grabOffset) }
        guard dividerMoved, let width = draggedWidth, let area, panes.count == 2 else {
            // Taken hold of without being moved.
            overlay?.finish()
            dragging = false
            updateDecorations()
            return
        }
        draggedWidth = nil
        let gap = CGFloat(BarSettings.lockInGap)
        BarSettings.lockInSplit = Self.clampSplit(width / (area.width - gap))
        // Now the apps resize, once each, out of sight under the covers.
        let goals = [CGRect(x: area.minX, y: area.minY, width: width, height: area.height),
                     CGRect(x: area.minX + width + gap, y: area.minY, width: area.width - width - gap, height: area.height)]
        for (mover, goal) in zip(movers, goals) { mover.move(to: goal) }
        WindowMover.whenIdle(movers) { [weak self] in
            // A moment for the apps to draw at their new size before the covers lift.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.ended else { overlay?.finish(); return }
                    self.dragging = false
                    // Puts the glow and the edge back, where the windows now are.
                    self.settle()
                    overlay?.finish()
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

    /// Windows of other apps that open on the desktop while it's locked in go elsewhere: onto the
    /// desktop showing on another screen when there is one (macOS lets apps move windows between
    /// screens, though not between desktops), or else they're tucked away with the rest.
    func moveNewcomers() {
        guard !ended, !dragging, showing else { return }
        let mine = Set(panes.map(\.pid))
        let me = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var found: [pid_t: Set<CGWindowID>] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me, !mine.contains(pid),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 80, rect.height >= 60,
                  WindowSpaces.spaceIDs(of: id) == [space] else { continue }
            found[pid, default: []].insert(id)
        }
        guard !found.isEmpty else { return }
        let elsewhere = NSScreen.screens.first { $0.displayID != display }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var tuckedAny = false
        for (pid, ids) in found {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            let windows = (LockIn.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            // A game starting up is left alone (it may be a match you're joining); apps that can't
            // be moved one window at a time are hidden instead.
            if Games.isGame(pid) { continue }
            if windows.isEmpty {
                if BarSettings.lockInHideOthers { hide([pid]) }
                continue
            }
            for window in windows {
                guard (LockIn.attribute(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                      let id = AppWindowList.windowID(of: window), ids.contains(id) else { continue }
                if let elsewhere {
                    let room = elsewhere.visibleFrame.insetBy(dx: 40, dy: 40)
                    if let frame = LockIn.frame(of: window), frame.width > room.width || frame.height > room.height {
                        Self.setSize(window, CGSize(width: min(frame.width, room.width), height: min(frame.height, room.height)))
                    }
                    Self.setPosition(window, CGPoint(x: room.minX, y: mainHeight - room.maxY))
                } else if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                    tucked.append(window)
                    tuckedAny = true
                }
            }
        }
        // An app whose window was just tucked away is still the one in front: go back to the two.
        if tuckedAny { WindowFocus.raise(panes[0].id, of: panes[0].pid) }
        onPutAway()
    }

    // MARK: Watching them

    private func watch() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pane in panes {
            // Never wait long on an app that's busy.
            AXUIElementSetMessagingTimeout(pane.element, 0.25)
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
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, pane.element, name as CFString, refcon)
            }
        }
    }

    private func windowChanged(_ element: AXUIElement, _ notification: String) {
        guard !ended else { return }
        if notification == kAXUIElementDestroyedNotification {
            // One of the two closed: lock-in is over here.
            if panes.contains(where: { CFEqual($0.element, element) }) { onEnd() }
            return
        }
        // The moves Clear Dock is making as you drag the edge between them need nothing more.
        if dragging { return }
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
        guard !ended, showing, !LockIn.missionControlOpen, panes.count == 2,
              let frames = frames ?? currentFrames() else { return hideDecorations() }
        drawnFrames = frames
        knownFrames = frames
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func flipped(_ rect: CGRect) -> NSRect { NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height) }
        if BarSettings.lockInBorder {
            let colour = accent()
            for (glow, frame) in zip(glows, frames) { glow.show(around: flipped(frame), color: colour) }
        } else {
            glows.forEach { $0.hide() }
        }
        let left = frames[0], right = frames[1]
        let top = max(left.minY, right.minY), bottom = min(left.maxY, right.maxY)
        guard right.minX >= left.maxX - 1, bottom - top > 60 else { return divider.orderOut(nil) }
        // A little over each window, so it's easy to take hold of.
        let overlap = DividerPanel.overlap
        divider.show(at: flipped(CGRect(x: left.maxX - overlap, y: top, width: right.minX - left.maxX + overlap * 2, height: bottom - top)))
    }

    /// After switching desktops or leaving Mission Control: put the glow and the edge back where
    /// the windows were (busy apps can be slow to say where they are, which would hold things up).
    func showDecorationsAgain() {
        updateDecorations(knownFrames)
    }

    private func hideDecorations() {
        drawnFrames = nil
        divider.orderOut(nil)
        glows.forEach { $0.hide() }
    }

    private func currentFrames() -> [CGRect]? {
        let frames = panes.compactMap { LockIn.frame(of: $0.element) }
        return frames.count == 2 ? frames : nil
    }

    // MARK: Helpers

    /// In place, allowing for apps like Terminal that round their size to whole lines of text.
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
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

/// The edge between the two windows: a thin strip of Clear Dock's own over the gap, a little over
/// each window, so dragging it is handled here, straight away, instead of by the apps (which can
/// be slow to resize themselves). It shows a small grip, like a split view's.
@MainActor
final class DividerPanel: NSPanel {
    /// How far it reaches over each window.
    static let overlap: CGFloat = 4

    /// Where on the edge it was taken hold of, from its left side.
    var onBegin: (CGFloat) -> Void = { _ in }
    /// The edge's new left side, as you drag it.
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    init() {
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

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        gripHidden = true
        // Where on the edge you took hold of it, so it doesn't jump to the pointer.
        grabbedAt = NSEvent.mouseLocation.x - (window?.frame.minX ?? 0)
        panel?.onBegin(grabbedAt)
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        panel?.onDrag(NSEvent.mouseLocation.x - grabbedAt)
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
        let grip = NSRect(x: bounds.midX - 2, y: bounds.midY - 22, width: 4, height: 44)
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
    /// Where the two windows go right now, asked at each refresh of the screen.
    private let follow: () -> [NSRect]?
    private var shown: [NSRect] = []
    private var link: CADisplayLink?

    /// `area` is the lock-in space, in the usual bottom-up screen coordinates.
    init(over area: NSRect, icons: [NSImage?], color: NSColor, glow: Bool, frostedCovers: Bool, follow: @escaping () -> [NSRect]?) {
        let frame = area.insetBy(dx: -Self.reach, dy: -Self.reach)
        origin = frame.origin
        self.follow = follow
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

    /// Puts the two windows' covers at `frames`, left then right, in the usual bottom-up screen coordinates.
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
        for (index, frame) in local.enumerated() where index < 2 {
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
        if local.count == 2 {
            let left = local[0], right = local[1]
            let midY = (max(left.minY, right.minY) + min(left.maxY, right.maxY)) / 2
            grip.frame = CGRect(x: (left.maxX + right.minX) / 2 - 2, y: midY - 22, width: 4, height: 44)
        }
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
