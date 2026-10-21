import AppKit
import ApplicationServices

/// Keeps windows from going under Clear Dock while it stays on screen, the way the macOS Dock
/// does when it isn't hidden. A window that ends up reaching into the dock's strip (after Fill,
/// maximise, tiling, or when it opens) is shortened to stop just above the dock.
///
/// Works through Accessibility, and only looks at a window after it has moved or changed size,
/// once the mouse button is up, so it never fights a resize you're in the middle of.
@MainActor
final class DockSpaceKeeper {
    /// The inner edge of the space kept free, in the system's window coordinates (measured from
    /// the top-left of the main screen): a y position for a bottom dock, an x position for a side
    /// dock. Nil when nothing is reserved.
    private var reservedLine: CGFloat?
    private var edge = DockEdge.bottom
    /// The screen the dock is on, in the same top-down coordinates.
    private var screenRect: CGRect = .zero

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
        guard let line, let screen, AXIsProcessTrusted() else { return stop() }
        // The system's window coordinates start at the top-left of the main screen and grow downwards.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let converted = edge == .bottom ? mainHeight - line : line
        let rect = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                          width: screen.frame.width, height: screen.frame.height)
        let changed = converted != reservedLine || rect != screenRect || edge != self.edge
        reservedLine = converted
        self.edge = edge
        screenRect = rect
        if observers.isEmpty { start() }
        if changed { fitAllWindows() }
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

    private func stop() {
        reservedLine = nil
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
        guard reservedLine != nil else { return }
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
        guard let line = reservedLine else { return }
        AXUIElementSetMessagingTimeout(window, 0.35)
        // Full-screen windows have their own desktop and can't be resized.
        if (attribute(window, "AXFullScreen") as? Bool) == true { return }
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true { return }
        guard let origin = point(window, kAXPositionAttribute), let size = size(window, kAXSizeAttribute) else { return }
        let frame = CGRect(origin: origin, size: size)

        // Only windows mostly on the dock's screen, reaching into the dock's strip, ending on the
        // screen (not dragged half off it), and still able to stay a sensible size.
        guard frame.intersects(screenRect), screenRect.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
        switch edge {
        case .bottom:
            guard frame.maxY > line + 1, frame.maxY <= screenRect.maxY + 2, frame.minY < line - 150 else { return }
            setSize(window, CGSize(width: size.width, height: (line - frame.minY).rounded(.down)))
        case .left:
            // Move the window's left side out from under the dock, keeping its right side where it is.
            guard frame.minX < line - 1, frame.minX >= screenRect.minX - 2, frame.maxX > line + 250 else { return }
            setPosition(window, CGPoint(x: line.rounded(.up), y: frame.minY))
            setSize(window, CGSize(width: (frame.maxX - line).rounded(.down), height: size.height))
        case .right:
            guard frame.maxX > line + 1, frame.maxX <= screenRect.maxX + 2, frame.minX < line - 250 else { return }
            setSize(window, CGSize(width: (line - frame.minX).rounded(.down), height: size.height))
        }
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
