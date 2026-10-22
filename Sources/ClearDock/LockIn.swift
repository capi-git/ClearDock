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

    /// When each locked-in desktop was locked in, by its id.
    var lockedIn: [UInt64: Date] { sessions.mapValues(\.started) }

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
    }

    private func lock(_ desktop: Desktop, on screen: NSScreen) {
        guard AXIsProcessTrusted() else {
            Self.explain("Lock-in needs Accessibility permission",
                         "Turn on Clear Dock in Privacy & Security > Accessibility, then click Lock In again.")
            return SystemSettings.open("com.apple.preference.security?Privacy_Accessibility")
        }
        let windows = Self.windows(on: desktop)
        var apps: [pid_t] = []
        for window in windows where !apps.contains(window.pid) { apps.append(window.pid) }
        switch (windows.count, apps.count) {
        case (..<2, _):
            Self.explain("Lock-in needs two windows on this desktop", "Open the two apps you want side by side here, then click Lock In.")
        case (2, _):
            // Each stays on the side it's on now.
            start(windows.sorted { $0.frame.midX < $1.frame.midX }, of: windows, on: desktop.id, screen: screen)
        case (_, 2):
            // The front window of each app, each on the side it's on now.
            let fronts = apps.compactMap { pid in windows.first { $0.pid == pid } }
            start(fronts.sorted { $0.frame.midX < $1.frame.midX }, of: windows, on: desktop.id, screen: screen)
        default:
            choosing = desktop.id
            onChange()
            choose(windows, screen) { [weak self] picked in
                guard let self, self.choosing == desktop.id else { return }
                self.choosing = nil
                self.onChange()
                // Only if you're still on that desktop.
                guard let picked, Self.currentDesktop(on: screen)?.id == desktop.id else { return }
                self.start(picked, of: windows, on: desktop.id, screen: screen)
            }
        }
    }

    /// Locks in two of the desktop's windows; the rest of `all` are tucked away, if that's on.
    private func start(_ picked: [Choice], of all: [Choice], on space: UInt64, screen: NSScreen) {
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
        sessions[space] = session
        if BarSettings.lockInHideOthers {
            let kept = Set(picked.map(\.id))
            session.tuck(all.filter { !kept.contains($0.id) }.map(\.element))
        }
        // First, so the dock is out of the way before the two are given the room.
        publish()
        session.begin()
        updateWatching()
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
        if now || WindowSpaces.currentSpaceIDs().contains(session.space) {
            Self.unminimize(session.tucked)
        } else if !session.tucked.isEmpty {
            waiting[session.space, default: []] += session.tucked
        }
        updateWatching()
        publish()
    }

    // MARK: Keeping up with your desktops and apps

    /// Listens to the system only while a desktop is locked in or has windows waiting to come back.
    private func updateWatching() {
        let needed = !sessions.isEmpty || !waiting.isEmpty
        if needed && tokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            tokens = [
                center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.spaceChanged() }
                },
                center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                    let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    MainActor.assumeIsolated { if let pid { self?.appQuit(pid) } }
                },
            ]
        } else if !needed && !tokens.isEmpty {
            tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            tokens.removeAll()
        }
    }

    private func spaceChanged() {
        let current = WindowSpaces.currentSpaceIDs()
        for space in waiting.keys where current.contains(space) { restoreWaiting(on: space) }
        for session in sessions.values {
            session.showing = current.contains(session.space)
            session.updateDecorations()
        }
    }

    /// One of the two apps quit, so that desktop's lock-in is over.
    private func appQuit(_ pid: pid_t) {
        for session in sessions.values where session.involves(pid) { end(session) }
    }

    private func restoreWaiting(on space: UInt64) {
        guard let windows = waiting.removeValue(forKey: space) else { return }
        Self.unminimize(windows)
        updateWatching()
    }

    // MARK: Finding the windows

    fileprivate static func currentDesktop(on screen: NSScreen) -> Desktop? {
        let desktops = DesktopReader.read()
        return (desktops[screen.displayUUID ?? "Main"] ?? desktops["Main"])?.first(where: \.isCurrent)
    }

    /// The ordinary windows on a desktop, front-most first.
    private static func windows(on desktop: Desktop) -> [Choice] {
        var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var choices: [Choice] = []
        for window in desktop.windows {
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
            guard let element = elements[window.app]?[window.id] else { continue }
            let app = NSRunningApplication(processIdentifier: window.app)
            choices.append(Choice(id: window.id, pid: window.app, element: element, frame: window.frame,
                                  app: app?.localizedName ?? "App", icon: app?.icon,
                                  title: attribute(element, kAXTitleAttribute) as? String))
        }
        // Titles are only needed to tell apart windows of the same app.
        for index in choices.indices where choices.filter({ $0.pid == choices[index].pid }).count < 2 {
            choices[index].title = nil
        }
        return choices
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
    /// Whether the desktop is the one showing on its display.
    var showing = true
    var accent: () -> NSColor = { .systemPurple }
    /// One of the two windows closed.
    var onEnd: () -> Void = {}

    /// Left, then right, each with what moves it.
    private var panes: [Pane]
    private var movers: [WindowMover]
    private var ended = false
    /// While you drag the edge between them, and until both apps have caught up afterwards.
    private var dragging = false
    private var draggedWidth: CGFloat?
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingSettle: DispatchWorkItem?
    private let divider = DividerPanel()
    private let glows = [GlowFrame(), GlowFrame()]
    /// How narrow each app has shown it will go, by window, for those that won't go as narrow as asked.
    private var minimumWidths: [CGWindowID: CGFloat] = [:]

    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]

    init(space: UInt64, display: CGDirectDisplayID, panes: [Pane]) {
        self.space = space
        self.display = display
        self.panes = panes
        movers = panes.map { WindowMover($0.element) }
        divider.onBegin = { [weak self] in self?.movers.forEach { $0.forget() } }
        divider.onDrag = { [weak self] x in self?.dividerDragged(to: x) }
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
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        hideDecorations()
    }

    /// Minimizes the desktop's other windows, so just the two and the wallpaper show.
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

    /// The edge was dragged so its left side is at `x`: the left window ends there and the right
    /// one starts after the gap. Both are moved on their own queues, never holding anything up.
    private func dividerDragged(to x: CGFloat) {
        guard !ended, panes.count == 2, let area else { return }
        let gap = CGFloat(BarSettings.lockInGap)
        let usable = area.width - gap
        let narrowest = max(120, usable * 0.2, minimumWidths[panes[0].id] ?? 0)
        let widest = max(narrowest, min(usable * 0.8, usable - max(120, minimumWidths[panes[1].id] ?? 0)))
        let width = min(max((x + DividerPanel.overlap - area.minX).rounded(), narrowest), widest)
        let left = CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
        let right = CGRect(x: left.maxX + gap, y: area.minY, width: area.maxX - left.maxX - gap, height: area.height)
        dragging = true
        draggedWidth = width
        movers[0].move(to: left)
        movers[1].move(to: right)
        updateDecorations([left, right])
    }

    private func dividerReleased() {
        guard let width = draggedWidth, let area else { return }
        draggedWidth = nil
        BarSettings.lockInSplit = Self.clampSplit(width / (area.width - CGFloat(BarSettings.lockInGap)))
        // Once both apps have caught up, see where they ended up.
        WindowMover.whenIdle(movers) { [weak self] in
            guard let self, !self.ended else { return }
            self.dragging = false
            self.settle()
        }
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
        guard !ended, showing, panes.count == 2, let frames = frames ?? currentFrames() else { return hideDecorations() }
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

    private func hideDecorations() {
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

    var onBegin: () -> Void = {}
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
        // Only on the desktop it's shown on.
        collectionBehavior = [.managed, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = DividerView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `frame` in the usual bottom-up screen coordinates.
    func show(at frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: true) }
        if !isVisible { orderFrontRegardless() }
    }
}

private final class DividerView: NSView {
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
        // Where on the edge you took hold of it, so it doesn't jump to the pointer.
        grabbedAt = NSEvent.mouseLocation.x - (window?.frame.minX ?? 0)
        panel?.onBegin()
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
        let grip = NSRect(x: bounds.midX - 2, y: bounds.midY - 22, width: 4, height: 44)
        NSColor.white.withAlphaComponent(dragging ? 0.9 : hovering ? 0.7 : 0.35).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }
}

/// A glowing rounded edge just outside a window, drawn as four thin strips (one along each side)
/// rather than one see-through window the size of the window, which keeps its memory and drawing
/// small. It never takes clicks, and sits on the lock-in desktop only.
@MainActor
final class GlowFrame {
    private static let margin: CGFloat = 10
    private static let lineWidth: CGFloat = 3
    /// Close to the corners of macOS windows.
    private static let cornerRadius: CGFloat = 14
    /// How deep each strip is: the margin outside the window, and a little way in for the glow.
    private static let depth: CGFloat = 22

    private let strips = (0..<4).map { _ in GlowStrip() }

    func hide() {
        strips.forEach { $0.orderOut(nil) }
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
        // Only on the desktop it's shown on.
        collectionBehavior = [.managed, .ignoresCycle]
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
