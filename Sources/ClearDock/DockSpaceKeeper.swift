import AppKit
import ApplicationServices

/// Keeps windows from going under Clear Dock while it stays on screen, the way the macOS Dock
/// does when it isn't hidden, and out from under the top bar. A window that ends up reaching into
/// one of those strips (after Fill, maximise, tiling, or when it opens) is shortened to stop at it.
///
/// Works through Accessibility, and only looks at a window after it has moved or changed size,
/// once the mouse button is up, so it never fights a resize you're in the middle of.
@MainActor
final class DockSpaceKeeper {
    /// Shared by the dock and the top bar, so each window is only watched once.
    static let shared = DockSpaceKeeper()

    private enum Edge { case top, bottom, left, right }

    /// A strip along one edge of a screen to keep windows out of. `line` is the strip's inner edge
    /// and `screen` the screen, both in the system's window coordinates (measured from the top-left
    /// of the main screen, growing downwards).
    private struct Strip: Equatable {
        let edge: Edge
        let line: CGFloat
        let screen: CGRect
    }

    /// The strips each part of Clear Dock has asked for ("dock" and "bar").
    private var slots: [String: [Strip]] = [:]
    /// Top strips first, so a window is moved down before its bottom is trimmed.
    private var strips: [Strip] { slots.values.flatMap { $0 }.sorted { $0.edge == .top && $1.edge != .top } }

    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows = Set<CFHashCode>()
    private var pending: [CFHashCode: DispatchWorkItem] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification]
    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                           kAXWindowMovedNotification, kAXWindowResizedNotification]

    /// Keep the strip between the dock's screen edge and `line` free of windows. `line` is the
    /// dock's inner edge in the usual bottom-up screen coordinates (a y for a bottom dock, an x
    /// for a side dock). Pass nil to stop.
    func reserve(edge: DockEdge, line: CGFloat?, on screen: NSScreen?) {
        guard let line, let screen else { return set("dock", []) }
        let converted = edge == .bottom ? Self.mainHeight - line : line
        let kept: Edge = switch edge {
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        }
        set("dock", [Strip(edge: kept, line: converted, screen: Self.topDown(screen))])
    }

    /// Keep the top of each screen, down to `bottom` (a y in the usual bottom-up screen
    /// coordinates), free of windows. Pass an empty list to stop.
    func reserveTop(_ bars: [(bottom: CGFloat, screen: NSScreen)]) {
        set("bar", bars.map { Strip(edge: .top, line: Self.mainHeight - $0.bottom, screen: Self.topDown($0.screen)) })
    }

    private func set(_ slot: String, _ new: [Strip]) {
        let changed = (slots[slot] ?? []) != new
        slots[slot] = new.isEmpty ? nil : new
        guard !slots.isEmpty, AXIsProcessTrusted() else { return stopWatching() }
        let wasIdle = observers.isEmpty
        if wasIdle { start() }
        if changed || wasIdle { fitAllWindows() }
    }

    /// The part of a screen windows are kept to, in the system's window coordinates: what macOS
    /// leaves free (below its menu bar, beside its Dock), less the strips kept for Clear Dock and
    /// the top bar.
    func freeArea(on screen: NSScreen) -> CGRect {
        let whole = Self.topDown(screen)
        let visible = screen.visibleFrame
        var minX = visible.minX, maxX = visible.maxX
        var minY = Self.mainHeight - visible.maxY, maxY = Self.mainHeight - visible.minY
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
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            watch(app.processIdentifier)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular else { return }
                MainActor.assumeIsolated { self?.watch(app.processIdentifier) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.unwatch(app.processIdentifier) }
            },
        ]
    }

    private func stopWatching() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        watchedWindows.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
    }

    // MARK: Watching apps and windows

    private func watch(_ pid: pid_t) {
        guard observers[pid] == nil, pid != getpid() else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let keeper = Unmanaged<DockSpaceKeeper>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { keeper.windowChanged(element) }
        }, &created) == .success, let observer = created else { return }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        for window in windows(of: app) { watchWindow(window, observer: observer) }
    }

    private func unwatch(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Some apps only report moves and resizes on the window itself, so listen there too.
    private func watchWindow(_ window: AXUIElement, observer: AXObserver) {
        let key = CFHash(window)
        guard !watchedWindows.contains(key) else { return }
        watchedWindows.insert(key)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    private func windowChanged(_ element: AXUIElement) {
        guard !slots.isEmpty else { return }
        // The notification may name the app rather than a window; then check its focused window.
        let window: AXUIElement
        if role(of: element) == kAXWindowRole {
            window = element
        } else if let focused = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            window = focused as! AXUIElement
        } else {
            return
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success, let observer = observers[pid] {
            watchWindow(window, observer: observer)
        }
        scheduleFit(window)
    }

    /// Waits until the window has settled and the mouse is up before adjusting it.
    private func scheduleFit(_ window: AXUIElement, delay: TimeInterval = 0.3) {
        let key = CFHash(window)
        pending[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending[key] = nil
                if NSEvent.pressedMouseButtons != 0 {
                    self.scheduleFit(window)
                } else {
                    self.fit(window)
                }
            }
        }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fitAllWindows() {
        for pid in observers.keys {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.35)
            for window in windows(of: app) { fit(window) }
        }
    }

    // MARK: Fitting a window

    private func fit(_ window: AXUIElement) {
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 30 { previewLog.notice("Timing: checking a window took \(ms) ms") }
        }
        let strips = strips
        guard !strips.isEmpty else { return }
        AXUIElementSetMessagingTimeout(window, 0.35)
        // Full-screen windows have their own desktop and can't be resized.
        if (attribute(window, "AXFullScreen") as? Bool) == true { return }
        // Leave games alone, and anything that isn't an ordinary window (like a game's full-screen layer).
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success, Games.isGame(pid) { return }
        if let id = AppWindowList.windowID(of: window), let layer = AppWindowList.layer(of: id), layer != 0 { return }
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true { return }
        guard let origin = point(window, kAXPositionAttribute), let size = size(window, kAXSizeAttribute) else { return }
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
        if frame.size != original.size { setSize(window, frame.size) }
        if frame.origin != original.origin { setPosition(window, frame.origin) }
    }

    private func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    // MARK: Accessibility helpers

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// Whether the app in front is showing a window in true full screen (its own desktop).
@MainActor
enum FullScreenCheck {
    static func frontAppIsFullScreen() -> Bool {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }
}
