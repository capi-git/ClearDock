import AppKit
@preconcurrency import ApplicationServices

/// Keeps windows from going under Clear Dock while it stays on screen, the way the macOS Dock
/// does when it isn't hidden, and out from under the top bar. A window that ends up reaching into
/// one of those strips (after Fill, maximise, tiling, or when it opens) is shortened to stop at it.
///
/// Works through Accessibility, on a thread of its own (`WindowWatcher`): asking an app about its
/// windows waits for that app, and a busy one would otherwise hold up the dock, the bar and
/// lock-in. It only looks at a window after it has moved or changed size, once the mouse button
/// is up, so it never fights a resize you're in the middle of.
@MainActor
final class DockSpaceKeeper {
    /// Shared by the dock and the top bar, so each window is only watched once.
    static let shared = DockSpaceKeeper()
    /// Posted when the room kept for the dock or the bar changes.
    static let didChange = Notification.Name("ClearDockKeptRoomChanged")

    /// The strips each part of Clear Dock has asked for ("dock" and "bar").
    private var slots: [String: [KeptStrip]] = [:]
    /// Top strips first, so a window is moved down before its bottom is trimmed.
    private var strips: [KeptStrip] { slots.values.flatMap { $0 }.sorted { $0.edge == .top && $1.edge != .top } }

    private let watcher = WindowWatcher()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pendingStop: DispatchWorkItem?

    /// Keep the strip between the dock's screen edge and `line` free of windows. `line` is the
    /// dock's inner edge in the usual bottom-up screen coordinates (a y for a bottom dock, an x
    /// for a side dock). Pass nil to stop.
    func reserve(edge: DockEdge, line: CGFloat?, on screen: NSScreen?) {
        guard let line, let screen else { return set("dock", []) }
        let converted = edge == .bottom ? Self.mainHeight - line : line
        let kept: KeptStrip.Edge = switch edge {
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        }
        set("dock", [KeptStrip(edge: kept, line: converted, screen: Self.topDown(screen))])
    }

    /// Keep the top of each screen, down to `bottom` (a y in the usual bottom-up screen
    /// coordinates), free of windows. Pass an empty list to stop.
    func reserveTop(_ bars: [(bottom: CGFloat, screen: NSScreen)]) {
        set("bar", bars.map { KeptStrip(edge: .top, line: Self.mainHeight - $0.bottom, screen: Self.topDown($0.screen)) })
    }

    private func set(_ slot: String, _ new: [KeptStrip]) {
        let changed = (slots[slot] ?? []) != new
        slots[slot] = new.isEmpty ? nil : new
        let strips = strips
        if changed {
            watcher.use(strips)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        guard AXIsProcessTrusted() else { return stop() }
        guard !strips.isEmpty else {
            // Often only for a while (a full-screen app or game in front): the apps stay watched,
            // so coming back doesn't mean asking every one of them about its windows again.
            return scheduleStop()
        }
        pendingStop?.cancel()
        pendingStop = nil
        let wasIdle = workspaceTokens.isEmpty
        if wasIdle { start() }
        if changed || wasIdle { watcher.fitAll() }
    }

    /// The part of a screen windows are kept to, in the system's window coordinates: what macOS
    /// leaves free (below its menu bar, beside its Dock), less the strips kept for Clear Dock and
    /// the top bar.
    func freeArea(on screen: NSScreen) -> CGRect {
        let whole = Self.topDown(screen)
        let visible = screen.visibleFrame
        var minX = visible.minX, maxX = visible.maxX
        var minY = Self.mainHeight - visible.maxY, maxY = Self.mainHeight - visible.minY
        // While Clear Dock keeps Apple's Dock hidden, room macOS still keeps for it is left over
        // from before; only the menu bar's room along the top counts.
        if Settings.hideSystemDock {
            minX = whole.minX
            maxX = whole.maxX
            maxY = whole.maxY
        }
        for strip in strips where strip.screen == whole {
            switch strip.edge {
            case .top: minY = max(minY, strip.line)
            case .bottom: maxY = min(maxY, strip.line)
            case .left: minX = max(minX, strip.line)
            case .right: maxX = min(maxX, strip.line)
            }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The system's window coordinates start at the top-left of the main screen and grow downwards.
    private static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func topDown(_ screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    private func start() {
        watcher.watch(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular else { return }
                // An app that has only just opened often doesn't answer yet.
                MainActor.assumeIsolated { self?.watcher.watch([app.processIdentifier], after: 1) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.watcher.unwatch(app.processIdentifier) }
            },
        ]
    }

    private func scheduleStop() {
        guard pendingStop == nil, !workspaceTokens.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.slots.isEmpty else { return }
                self.stop()
            }
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func stop() {
        pendingStop?.cancel()
        pendingStop = nil
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        watcher.stopAll()
    }
}

/// A strip along one edge of a screen to keep windows out of. `line` is the strip's inner edge
/// and `screen` the screen, both in the system's window coordinates (measured from the top-left
/// of the main screen, growing downwards).
struct KeptStrip: Equatable, Sendable {
    enum Edge: Sendable { case top, bottom, left, right }
    let edge: Edge
    let line: CGFloat
    let screen: CGRect
}

/// The keeper's Accessibility work, on a thread of its own with its own run loop, which the apps'
/// notifications arrive on. Everything it keeps is only touched on that thread; the main thread
/// only hands it work.
private final class WindowWatcher: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    // Only touched on the watcher's thread.
    private var strips: [KeptStrip] = []
    private var observers: [pid_t: AXObserver] = [:]
    /// Windows listened to directly, with their app, so they're forgotten when it quits.
    private var watchedWindows: [CFHashCode: pid_t] = [:]
    /// Windows that moved or changed size while a mouse button was down, looked at once it's up.
    private var dragged: [CFHashCode: AXUIElement] = [:]
    private var dragCheckPending = false
    /// The latest fit asked for each window; an earlier one still waiting is dropped.
    private var pending: [CFHashCode: Int] = [:]
    private var asked = 0

    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                           kAXWindowMovedNotification, kAXWindowResizedNotification]
    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                              kAXUIElementDestroyedNotification]

    override init() {
        super.init()
        name = "Clear Dock window keeper"
        qualityOfService = .userInitiated
        start()
        ready.wait()
    }

    override func main() {
        let loop = CFRunLoopGetCurrent()
        runLoop = loop
        // Something for the run loop to wait on while there's nothing else.
        let idle = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, idle, .defaultMode)
        ready.signal()
        while true { CFRunLoopRun() }
    }

    /// Runs `work` on the watcher's thread, after `delay` seconds.
    private func perform(after delay: TimeInterval = 0, _ work: @escaping () -> Void) {
        guard let runLoop else { return }
        if delay <= 0 {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
            CFRunLoopWakeUp(runLoop)
        } else {
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { _ in work() }
            CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        }
    }

    // MARK: Asked from the main thread

    func use(_ strips: [KeptStrip]) { perform { self.strips = strips } }
    func watch(_ pids: [pid_t], after delay: TimeInterval = 0) { perform(after: delay) { pids.forEach { self.watchApp($0) } } }
    func unwatch(_ pid: pid_t) { perform { self.unwatchApp(pid) } }
    func fitAll() { perform { self.fitAllWindows() } }

    func stopAll() {
        perform {
            for pid in Array(self.observers.keys) { self.unwatchApp(pid) }
            self.watchedWindows.removeAll()
            self.dragged.removeAll()
            self.pending.removeAll()
        }
    }

    // MARK: Watching apps and windows

    private func watchApp(_ pid: pid_t, attempt: Int = 0) {
        guard observers[pid] == nil, pid != getpid(), let runLoop else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue().changed(element, notification as String)
        }, &created) == .success, let observer = created else { return }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var listening = false
        for name in Self.appNotifications {
            let result = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered { listening = true }
        }
        guard listening else {
            // Not answering yet (it may still be opening): try again in a moment.
            if attempt < 3 { perform(after: 2) { self.watchApp(pid, attempt: attempt + 1) } }
            return
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        for window in Self.windows(of: app) { watchWindow(window, of: pid, observer: observer) }
    }

    private func unwatchApp(_ pid: pid_t) {
        watchedWindows = watchedWindows.filter { $0.value != pid }
        guard let observer = observers.removeValue(forKey: pid), let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Some apps only report moves and resizes on the window itself, so listen there too.
    private func watchWindow(_ window: AXUIElement, of pid: pid_t, observer: AXObserver) {
        let key = CFHash(window)
        guard watchedWindows[key] == nil else { return }
        watchedWindows[key] = pid
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    private func changed(_ element: AXUIElement, _ notification: String) {
        if notification == kAXUIElementDestroyedNotification {
            watchedWindows[CFHash(element)] = nil
            pending[CFHash(element)] = nil
            return
        }
        guard !strips.isEmpty else { return }
        // While a mouse button is down (a window being dragged), only note it: nothing is changed
        // until the button is up anyway.
        if Self.mouseButtonDown {
            dragged[CFHash(element)] = element
            return scheduleDragCheck()
        }
        // The notification may name the app rather than a window; then check its focused window.
        AXUIElementSetMessagingTimeout(element, 0.35)
        let window: AXUIElement
        if Self.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole {
            window = element
        } else if let focused = Self.attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            window = focused as! AXUIElement
        } else {
            return
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success, let observer = observers[pid] {
            watchWindow(window, of: pid, observer: observer)
        }
        scheduleFit(window)
    }

    private static var mouseButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left) || CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    /// Waits until the window has settled and the mouse is up before adjusting it.
    private func scheduleFit(_ window: AXUIElement, delay: TimeInterval = 0.3) {
        let key = CFHash(window)
        asked += 1
        let mine = asked
        pending[key] = mine
        perform(after: delay) {
            guard self.pending[key] == mine else { return }
            self.pending[key] = nil
            if Self.mouseButtonDown { return self.scheduleFit(window) }
            self.fitUnlessGame(window)
        }
    }

    /// Looks at the windows that changed during a drag once the mouse button is up.
    private func scheduleDragCheck() {
        guard !dragCheckPending else { return }
        dragCheckPending = true
        perform(after: 0.3) {
            self.dragCheckPending = false
            if Self.mouseButtonDown { return self.scheduleDragCheck() }
            let elements = Array(self.dragged.values)
            self.dragged.removeAll()
            for element in elements { self.changed(element, kAXWindowMovedNotification) }
        }
    }

    private func fitAllWindows() {
        // Only apps with a window reaching into one of the strips are asked about their windows:
        // asking every app (some of them busy) would take a long while.
        let strips = strips
        guard !strips.isEmpty else { return }
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var reaching = Set<pid_t>()
        for info in onScreen where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, observers[pid] != nil,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            if strips.contains(where: { Self.reaches(frame, into: $0) }) { reaching.insert(pid) }
        }
        for pid in reaching where !Games.isGame(pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.35)
            for window in Self.windows(of: app) { Self.fit(window, into: strips) }
        }
    }

    private func fitUnlessGame(_ window: AXUIElement) {
        // Games are left alone.
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success, Games.isGame(pid) { return }
        Self.fit(window, into: strips)
    }

    /// Whether a window (in the system's window coordinates) reaches into a strip on its screen.
    private static func reaches(_ frame: CGRect, into strip: KeptStrip) -> Bool {
        guard frame.intersects(strip.screen) else { return false }
        switch strip.edge {
        case .top: return frame.minY < strip.line - 1
        case .bottom: return frame.maxY > strip.line + 1
        case .left: return frame.minX < strip.line - 1
        case .right: return frame.maxX > strip.line + 1
        }
    }

    // MARK: Fitting a window

    /// Fits a window out of the strips. It asks the app about its window, which can take a while
    /// when the app is busy.
    private static func fit(_ window: AXUIElement, into strips: [KeptStrip]) {
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 30 { previewLog.notice("Timing: checking a window took \(ms) ms") }
        }
        guard !strips.isEmpty else { return }
        AXUIElementSetMessagingTimeout(window, 0.35)
        // Full-screen windows have their own desktop and can't be resized.
        if (Self.attribute(window, "AXFullScreen") as? Bool) == true { return }
        // Leave anything that isn't an ordinary window alone (like a game's full-screen layer); games
        // themselves were left out before getting here.
        if let id = AppWindowList.windowID(of: window), let layer = AppWindowList.layer(of: id), layer != 0 { return }
        if (Self.attribute(window, kAXMinimizedAttribute) as? Bool) == true { return }
        guard let origin = Self.point(window, kAXPositionAttribute), let size = Self.size(window, kAXSizeAttribute) else { return }
        let original = CGRect(origin: origin, size: size)
        var frame = original

        // Only windows mostly on the strip's screen, reaching into the strip, ending on the
        // screen (not dragged half off it), and still able to stay a sensible size.
        for strip in strips {
            let screenRect = strip.screen, line = strip.line
            guard frame.intersects(screenRect), screenRect.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            switch strip.edge {
            case .top:
                // Move the window's top down out from under the bar, keeping its bottom where it is.
                guard frame.minY < line - 1, frame.minY >= screenRect.minY - 2, frame.maxY > line + 150 else { continue }
                let bottom = frame.maxY
                frame.origin.y = line.rounded(.up)
                frame.size.height = (bottom - frame.origin.y).rounded(.down)
            case .bottom:
                guard frame.maxY > line + 1, frame.maxY <= screenRect.maxY + 2, frame.minY < line - 150 else { continue }
                frame.size.height = (line - frame.minY).rounded(.down)
            case .left:
                // Move the window's left side out from under the dock, keeping its right side where it is.
                guard frame.minX < line - 1, frame.minX >= screenRect.minX - 2, frame.maxX > line + 250 else { continue }
                let right = frame.maxX
                frame.origin.x = line.rounded(.up)
                frame.size.width = (right - frame.origin.x).rounded(.down)
            case .right:
                guard frame.maxX > line + 1, frame.maxX <= screenRect.maxX + 2, frame.minX < line - 250 else { continue }
                frame.size.width = (line - frame.minX).rounded(.down)
            }
        }
        // Shrink first, then move, so the window never has to reach past the screen on the way.
        if frame.size != original.size { Self.setSize(window, frame.size) }
        if frame.origin != original.origin { Self.setPosition(window, frame.origin) }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    // MARK: Accessibility helpers

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = Self.attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = Self.attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
