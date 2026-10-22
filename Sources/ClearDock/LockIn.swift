import AppKit
import ApplicationServices

/// Lock-in mode: the desktop you're on, given over to two windows side by side, with the wallpaper
/// showing around them and a glowing edge on the one you're using. With two apps on the desktop it's
/// those two, straight away; with more, you choose which two, and the rest are tucked away
/// (minimized) until you unlock. It never takes you to another desktop, and each desktop can be
/// locked in on its own.
///
/// The two stay stuck together: drag the edge between them to share the screen differently, or drag
/// one onto the other's side to swap them; anything else snaps back.
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

    var onChange: () -> Void = {}
    /// The colour of the edge around the window you're using, for the screen it's on.
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
        session.begin()
        updateWatching()
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
        onChange()
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
                center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateBorders() }
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
        updateBorders()
    }

    /// One of the two apps quit, so that desktop's lock-in is over.
    private func appQuit(_ pid: pid_t) {
        for session in sessions.values where session.involves(pid) { end(session) }
    }

    private func updateBorders() {
        let current = WindowSpaces.currentSpaceIDs()
        for session in sessions.values {
            session.showing = current.contains(session.space)
            session.updateBorder()
        }
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

    fileprivate static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    fileprivate static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
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

    /// Left, then right.
    private var panes: [Pane]
    private var ended = false
    /// The window being resized by you right now, which the other follows as you drag.
    private var driving: AXUIElement?
    private var lastStep: CFTimeInterval = 0
    /// Where the window following yours was last put, while you drag.
    private var followedX: CGFloat?
    /// The one of the two you're using, with the glowing edge round it; nil while neither is.
    private var lit: Pane?
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingFit: DispatchWorkItem?
    private var border: BorderPanel?

    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]

    init(space: UInt64, display: CGDirectDisplayID, panes: [Pane]) {
        self.space = space
        self.display = display
        self.panes = panes
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
        updateBorder()
    }

    func finish() {
        ended = true
        pendingFit?.cancel()
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        border?.orderOut(nil)
        border = nil
    }

    /// Minimizes the desktop's other windows, so just the two and the wallpaper show.
    func tuck(_ windows: [AXUIElement]) {
        for window in windows where AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
            tucked.append(window)
        }
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
            LockIn.setSize(pane.element, target.size)
            LockIn.setPosition(pane.element, target.origin)
            LockIn.setSize(pane.element, target.size)
        }
        updateBorder()
    }

    /// After you've moved or resized one of them: an inner edge dragged sets how they share the
    /// screen, a window dragged over the other's side swaps them, and everything else snaps back.
    private func settle() {
        guard panes.count == 2, let area else { return }
        let goals = targets
        let frames = panes.map { LockIn.frame(of: $0.element) }
        guard let left = frames[0], let right = frames[1] else { return }
        let gap = CGFloat(BarSettings.lockInGap)
        let usable = area.width - gap
        if left.midX > right.midX {
            panes.swapAt(0, 1)
        } else if abs(left.minX - goals[0].minX) < 3 && abs(left.maxX - goals[0].maxX) > 3 && abs(left.width - goals[0].width) > 3 {
            BarSettings.lockInSplit = Self.clampSplit((left.maxX - area.minX) / usable)
        } else if abs(right.maxX - goals[1].maxX) < 3 && abs(right.minX - goals[1].minX) > 3 && abs(right.width - goals[1].width) > 3 {
            BarSettings.lockInSplit = Self.clampSplit((right.minX - gap - area.minX) / usable)
        } else if abs(right.minX - goals[1].minX) < 3 && right.width > goals[1].width + 16 {
            // The right one won't go as narrow as its share (some apps have a smallest size),
            // so it would reach off the screen: give it the room it needs.
            BarSettings.lockInSplit = Self.clampSplit((area.width - gap - right.width) / usable)
        }
        fit()
    }

    private static func clampSplit(_ value: CGFloat) -> Double { Double(min(0.8, max(0.2, value))) }

    /// Resizes the other window to fill the rest of the space as you drag one's inner edge.
    /// Returns whether it did.
    private func follow(_ element: AXUIElement) -> Bool {
        guard panes.count == 2, let area, let index = panes.firstIndex(where: { CFEqual($0.element, element) }),
              let moved = LockIn.frame(of: element) else { return false }
        let goals = targets
        let gap = CGFloat(BarSettings.lockInGap)
        let other = panes[1 - index]
        let target: CGRect
        if index == 0 {
            // The left window's right edge is the divider, while its left edge stays put.
            guard abs(moved.minX - goals[0].minX) < 3 else { return false }
            let x = moved.maxX + gap
            guard area.maxX - x > 120 else { return false }
            target = CGRect(x: x, y: goals[1].minY, width: area.maxX - x, height: goals[1].height)
            // In whichever order keeps the in-between step off the edge of the screen, so it doesn't flicker.
            if x >= (followedX ?? goals[1].minX) {
                LockIn.setPosition(other.element, target.origin)
                LockIn.setSize(other.element, target.size)
            } else {
                LockIn.setSize(other.element, target.size)
                LockIn.setPosition(other.element, target.origin)
            }
            followedX = x
        } else {
            // The right window's left edge is the divider, while its right edge stays put.
            guard abs(moved.maxX - goals[1].maxX) < 3 else { return false }
            let width = moved.minX - gap - area.minX
            guard width > 120 else { return false }
            target = CGRect(x: goals[0].minX, y: goals[0].minY, width: width, height: goals[0].height)
            LockIn.setSize(other.element, target.size)
        }
        driving = element
        // The edge goes with whichever of the two it's around, without asking the apps where they are.
        if lit?.id == other.id { moveBorder(to: target) } else if lit?.id == panes[index].id { moveBorder(to: moved) }
        return true
    }

    private func watch() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pane in panes {
            // Never wait long on an app that's busy, so dragging stays smooth.
            AXUIElementSetMessagingTimeout(pane.element, 0.1)
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
                // Which of its windows you're using, for the glowing edge.
                AXObserverAddNotification(observer, AXUIElementCreateApplication(pane.pid), kAXFocusedWindowChangedNotification as CFString, refcon)
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
        if notification == kAXFocusedWindowChangedNotification { return updateBorder() }
        scheduleSettle()
        // While you drag one's inner edge, the other's own resizing (from following it) needs nothing more.
        if let driving, !CFEqual(driving, element) { return }
        // At most about sixty steps a second, so each is done before the next comes in.
        let now = CACurrentMediaTime()
        guard now - lastStep >= 1.0 / 60 else { return }
        lastStep = now
        // While you drag one window's inner edge, the other follows it straight away.
        if notification == kAXWindowResizedNotification, NSEvent.pressedMouseButtons != 0, follow(element) { return }
        if let lit, CFEqual(lit.element, element) { moveBorder() }
    }

    /// Settles them shortly, once the mouse button is up, so it never fights a drag you're in the middle of.
    private func scheduleSettle() {
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                if NSEvent.pressedMouseButtons != 0 { return self.scheduleSettle() }
                self.driving = nil
                self.followedX = nil
                self.settle()
            }
        }
        pendingFit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: The glowing edge

    /// Works out which of the two you're using, and puts the edge around it while its desktop is
    /// showing; none otherwise.
    func updateBorder() {
        guard !ended, showing, BarSettings.lockInBorder,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let pane = focusedPane(of: front) else {
            lit = nil
            border?.orderOut(nil)
            return
        }
        lit = pane
        moveBorder()
    }

    /// Puts the edge around the window you're using: at `frame` (in the system's window
    /// coordinates) when that's known already, or else where the window is.
    private func moveBorder(to frame: CGRect? = nil) {
        guard let lit, let frame = frame ?? LockIn.frame(of: lit.element) else { return }
        let border = self.border ?? BorderPanel()
        self.border = border
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        border.show(around: rect, color: accent())
    }

    /// The one of the two that's the app's window in use, if either is.
    private func focusedPane(of pid: pid_t) -> Pane? {
        let mine = panes.filter { $0.pid == pid }
        guard !mine.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = LockIn.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return mine.first { CFEqual($0.element, focused) }
    }

    /// In place, allowing for apps like Terminal that round their size to whole lines of text.
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }
}

/// A glowing rounded edge drawn just outside a window. It sits on the lock-in desktop only, never
/// takes clicks, and follows the window as it moves.
@MainActor
final class BorderPanel: NSPanel {
    private let outline = CAShapeLayer()
    private static let margin: CGFloat = 10
    private static let lineWidth: CGFloat = 3
    /// Close to the corners of macOS windows.
    private static let cornerRadius: CGFloat = 14

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        // Only on the desktop it's shown on.
        collectionBehavior = [.managed, .ignoresCycle]
        isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = Self.lineWidth
        outline.shadowOpacity = 0.9
        outline.shadowRadius = 6
        outline.shadowOffset = .zero
        view.layer?.addSublayer(outline)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `window` is the window's frame in the usual bottom-up screen coordinates.
    func show(around window: NSRect, color: NSColor) {
        setFrame(window.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = NSRect(origin: .zero, size: frame.size)
        outline.frame = bounds
        let edge = bounds.insetBy(dx: Self.margin - Self.lineWidth / 2 - 1, dy: Self.margin - Self.lineWidth / 2 - 1)
        let radius = Self.cornerRadius + Self.lineWidth / 2 + 1
        outline.path = CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil)
        outline.strokeColor = color.cgColor
        outline.shadowColor = color.cgColor
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }
}
