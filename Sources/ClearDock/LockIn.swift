import AppKit
import ApplicationServices

/// Lock-in mode: two apps of your choosing side by side on a desktop of their own, with the
/// wallpaper showing around them and a glowing edge on the one you're using. They stay stuck
/// together: drag the edge between them to share the screen differently, or drag one over the
/// other's side to swap them; anything else snaps back. Only that desktop is locked in: other
/// windows on it are tucked away (minimized) meanwhile and come back afterwards, and your other
/// desktops are left as they are.
///
/// macOS doesn't let apps move a window to another desktop, so an app with no window on the
/// lock-in desktop is asked for a new one (its own "New Window" command). macOS puts new windows on
/// the screen you last worked on, so one that appears on your other screen is moved across, which
/// macOS does allow; so is an app's existing window when it's on the desktop showing on another screen.
@MainActor
final class LockIn {
    private(set) var isOn = false
    private(set) var isStarting = false
    private(set) var started: Date?
    var onChange: () -> Void = {}
    /// The bottom of the top bar on a screen (a y in the usual bottom-up screen coordinates), so
    /// the windows go just under it.
    var barBottom: (NSScreen) -> CGFloat = { $0.frame.maxY }
    /// The colour of the edge around the window you're using, for the screen it's on.
    var accent: (NSScreen?) -> NSColor = { _ in .systemPurple }

    private struct Pane {
        let pid: pid_t
        let element: AXUIElement
        let id: CGWindowID
    }

    /// Left, then right.
    private var panes: [Pane] = []
    private var screen: NSScreen?
    /// Other windows on the lock-in desktop, minimized while you're locked in.
    private var tucked: [AXUIElement] = []
    /// The lock-in desktop's id while locked in.
    private var space: UInt64?
    /// The window being resized by you right now, which the other follows as you drag.
    private var driving: AXUIElement?
    private var lastFollow: CFTimeInterval = 0
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingFit: DispatchWorkItem?
    private var border: BorderPanel?
    private var workspaceTokens: [NSObjectProtocol] = []

    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]

    // MARK: Turning it on and off

    /// Locks in; or, while locked in, goes back to the lock-in desktop if you're elsewhere, and
    /// unlocks if you're on it.
    func toggle() {
        guard isOn else { return enter() }
        if !goToLockInDesktop() { unlock() }
    }

    /// Unlocks, going to the lock-in desktop first if you're elsewhere, so the windows tucked away
    /// there come back on it.
    func unlock() {
        guard isOn else { return }
        if goToLockInDesktop() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.exit() }
            }
        } else {
            exit()
        }
    }

    /// Switches to the lock-in desktop when it isn't the one showing. Returns whether it did.
    private func goToLockInDesktop() -> Bool {
        guard let screen, let key = BarSettings.lockInDesktop else { return false }
        let desktops = DesktopReader.read()
        guard let target = (desktops[screen.displayUUID ?? "Main"] ?? desktops["Main"])?.first(where: { $0.key == key }),
              !target.isCurrent else { return false }
        // The desktop switching shortcuts act on the screen under the pointer.
        if !NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) {
            CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.frame.midY))
        }
        DesktopSwitcher.go(to: target)
        return true
    }

    private func enter() {
        guard !isStarting else { return }
        isStarting = true
        onChange()
        Task { @MainActor in
            defer {
                isStarting = false
                onChange()
            }
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.screens.first else { return }
            self.screen = screen

            // Go to the lock-in desktop (the first time, the one you're on becomes it).
            let key = screen.displayUUID ?? "Main"
            let desktops = DesktopReader.read()
            let mine = desktops[key] ?? desktops["Main"] ?? []
            if let chosen = BarSettings.lockInDesktop, let target = mine.first(where: { $0.key == chosen }), !target.isCurrent {
                DesktopSwitcher.go(to: target)
                guard await Self.wait(seconds: 3, until: { Self.currentDesktop(on: screen)?.key == chosen }) else {
                    return Self.explain("Couldn't get to your lock-in desktop.", "Clicking it in the bar should work too; then try Lock In again.")
                }
                try? await Task.sleep(for: .seconds(0.3))
            } else if BarSettings.lockInDesktop == nil || !mine.contains(where: { $0.key == BarSettings.lockInDesktop }) {
                BarSettings.lockInDesktop = Self.currentDesktop(on: screen)?.key
            }
            guard let space = Self.currentDesktop(on: screen)?.id else { return }
            self.space = space

            // The two apps: chosen in settings, filled in with the ones you're using on this desktop.
            var apps = BarSettings.lockInApps.filter { !$0.isEmpty }
            if apps.count < 2 {
                for app in Self.appsOnCurrentDesktop(of: screen) where !apps.contains(app) && apps.count < 2 { apps.append(app) }
                guard apps.count >= 2 else {
                    Self.explain("Choose two apps for lock-in mode", "Open them on this desktop and click Lock In, or choose them in Clear Dock's settings (Top Bar).")
                    SettingsWindowController.shared.show(tab: .topBar)
                    return
                }
                BarSettings.lockInApps = Array(apps.prefix(2))
            }

            // A window of each, on this desktop.
            var panes: [Pane] = []
            for bundle in apps.prefix(2) {
                guard let pane = await Self.window(of: bundle, on: space, screen: screen) else {
                    let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
                    return Self.explain("Couldn't get a window of \(name) onto your lock-in desktop.",
                                        "Its windows are on desktops that aren't showing, and macOS doesn't let apps move windows between desktops. Open \(name) on the lock-in desktop yourself, or drag its window there in Mission Control, then click Lock In again.")
                }
                panes.append(pane)
            }
            guard panes[0].id != panes[1].id else { return }
            self.panes = panes

            if let path = BarSettings.lockInWallpaper, FileManager.default.fileExists(atPath: path) {
                // Sets the wallpaper of the desktop you're on, which is the lock-in desktop.
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
            }
            if BarSettings.lockInHideOthers { tuckOthers(on: space) }

            isOn = true
            started = Date()
            watch()
            fit()
            WindowFocus.raise(panes[0].id, of: panes[0].pid)
            updateBorder()
        }
    }

    func exit() {
        guard isOn else { return }
        isOn = false
        started = nil
        stopWatching()
        border?.orderOut(nil)
        border = nil
        for window in tucked {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        tucked.removeAll()
        panes.removeAll()
        space = nil
        driving = nil
        onChange()
    }

    /// Minimizes the other windows on the lock-in desktop (only there), so just the two apps and
    /// the wallpaper show.
    private func tuckOthers(on space: UInt64) {
        let keep = Set(panes.map(\.id))
        let me = getpid()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            for window in (Self.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                guard (Self.attribute(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                      (Self.attribute(window, kAXMinimizedAttribute) as? Bool) != true,
                      let id = AppWindowList.windowID(of: window), !keep.contains(id),
                      WindowSpaces.spaceIDs(of: id) == [space] else { continue }
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                    tucked.append(window)
                }
            }
        }
    }

    // MARK: Finding the windows

    private static func currentDesktop(on screen: NSScreen) -> Desktop? {
        let desktops = DesktopReader.read()
        return (desktops[screen.displayUUID ?? "Main"] ?? desktops["Main"])?.first(where: \.isCurrent)
    }

    /// The apps with windows on the desktop showing on a screen, front-most first.
    private static func appsOnCurrentDesktop(of screen: NSScreen) -> [String] {
        let me = getpid()
        return (currentDesktop(on: screen)?.apps ?? []).filter { $0 != me }.compactMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
    }

    /// A window of the app on the given desktop: one already there; else a new one (opening the app
    /// first if it isn't running); else one of its windows from the desktop showing on another screen.
    private static func window(of bundle: String, on space: UInt64, screen: NSScreen) async -> Pane? {
        var app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        if app == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            guard let app else { return nil }
            // Its first window opens on whichever screen you last worked on.
            var pane: Pane?
            _ = await wait(seconds: 10) {
                pane = existingWindow(of: app.processIdentifier, on: visibleSpaces())
                return pane != nil
            }
            if let pane { return await moveOver(pane, to: space, on: screen) }
        }
        guard let pid = app?.processIdentifier else { return nil }
        if let pane = existingWindow(of: pid, on: [space]) { return pane }
        let before = Set(windowIDs(of: pid))
        if pressNewWindow(of: pid) {
            var pane: Pane?
            _ = await wait(seconds: 5) {
                pane = existingWindow(of: pid, on: visibleSpaces(), excluding: before)
                return pane != nil
            }
            if let pane { return await moveOver(pane, to: space, on: screen) }
        }
        // An app that can't open another window: bring over the one showing on another screen.
        if let pane = existingWindow(of: pid, on: visibleSpaces()) { return await moveOver(pane, to: space, on: screen) }
        return nil
    }

    /// The desktops showing on each screen right now.
    private static func visibleSpaces() -> Set<UInt64> {
        Set(DesktopReader.read().values.flatMap { $0 }.filter(\.isCurrent).map(\.id))
    }

    /// Moves a window onto the lock-in screen, where it joins the desktop showing there.
    private static func moveOver(_ pane: Pane, to space: UInt64, on screen: NSScreen) async -> Pane? {
        if WindowSpaces.spaceIDs(of: pane.id).contains(space) { return pane }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        setPosition(pane.element, CGPoint(x: screen.frame.minX + 80, y: mainHeight - screen.frame.maxY + 80))
        let arrived = await wait(seconds: 2) { WindowSpaces.spaceIDs(of: pane.id).contains(space) }
        return arrived ? pane : nil
    }

    private static func windowIDs(of pid: pid_t) -> [CGWindowID] {
        let app = AXUIElementCreateApplication(pid)
        return ((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).compactMap(AppWindowList.windowID(of:))
    }

    /// The app's front-most ordinary window on one of the given desktops.
    private static func existingWindow(of pid: pid_t, on spaces: Set<UInt64>, excluding skipped: Set<CGWindowID> = []) -> Pane? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            guard (attribute(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                  (attribute(window, kAXMinimizedAttribute) as? Bool) != true,
                  let id = AppWindowList.windowID(of: window), !skipped.contains(id),
                  !spaces.isDisjoint(with: WindowSpaces.spaceIDs(of: id))
            else { continue }
            return Pane(pid: pid, element: window, id: id)
        }
        return nil
    }

    /// Presses the app's own "New Window" command (File > New Window and the like), which opens
    /// the window on the desktop you're on.
    private static func pressNewWindow(of pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        for heading in children(bar as! AXUIElement) {
            for menu in children(heading) {
                for item in children(menu) {
                    let title = (attribute(item, kAXTitleAttribute) as? String ?? "").lowercased()
                    guard title.hasPrefix("new"), title.contains("window"), !title.contains("private"), !title.contains("incognito"),
                          (attribute(item, kAXEnabledAttribute) as? Bool) != false else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    // MARK: Keeping them side by side

    /// The space the two windows share: under the bar, with a gap all round showing the wallpaper.
    private var area: CGRect? {
        guard let screen else { return nil }
        let gap = CGFloat(BarSettings.lockInGap)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = mainHeight - barBottom(screen)
        let bottom = mainHeight - screen.frame.minY
        return CGRect(x: screen.frame.minX + gap, y: top + gap, width: screen.frame.width - gap * 2, height: bottom - top - gap * 2)
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
            guard let frame = Self.frame(of: pane.element), !Self.close(frame, target) else { continue }
            // Size, place, and size again: some apps only accept a size that fits where they are.
            Self.setSize(pane.element, target.size)
            Self.setPosition(pane.element, target.origin)
            Self.setSize(pane.element, target.size)
        }
        updateBorder()
    }

    /// After you've moved or resized one of them: an inner edge dragged sets how they share the
    /// screen, a window dragged over the other's side swaps them, and everything else snaps back.
    private func settle() {
        guard panes.count == 2, let area else { return }
        let goals = targets
        let frames = panes.map { Self.frame(of: $0.element) }
        guard let left = frames[0], let right = frames[1] else { return }
        let gap = CGFloat(BarSettings.lockInGap)
        let usable = area.width - gap
        if left.midX > area.midX && right.midX < area.midX {
            panes.swapAt(0, 1)
        } else if abs(left.minX - goals[0].minX) < 3 && abs(left.maxX - goals[0].maxX) > 3 && abs(left.width - goals[0].width) > 3 {
            BarSettings.lockInSplit = Self.clampSplit((left.maxX - area.minX) / usable)
        } else if abs(right.maxX - goals[1].maxX) < 3 && abs(right.minX - goals[1].minX) > 3 && abs(right.width - goals[1].width) > 3 {
            BarSettings.lockInSplit = Self.clampSplit((right.minX - gap - area.minX) / usable)
        }
        fit()
    }

    private static func clampSplit(_ value: CGFloat) -> Double { Double(min(0.8, max(0.2, value))) }

    /// Resizes the other window to fill the rest of the space as you drag one's inner edge,
    /// up to about sixty times a second.
    private func follow(_ element: AXUIElement) {
        guard panes.count == 2, let area, let index = panes.firstIndex(where: { CFEqual($0.element, element) }) else { return }
        // Only the window you're dragging leads; the other's own resizing (from following) doesn't.
        if let driving, !CFEqual(driving, element) { return }
        let now = CACurrentMediaTime()
        guard now - lastFollow > 1.0 / 60 else { return }
        let goals = targets
        guard let moved = Self.frame(of: element) else { return }
        let gap = CGFloat(BarSettings.lockInGap)
        let other = panes[1 - index].element
        if index == 0 {
            // The left window's right edge is the divider, while its left edge stays put.
            guard abs(moved.minX - goals[0].minX) < 3 else { return }
            let x = moved.maxX + gap
            guard area.maxX - x > 120 else { return }
            driving = element
            lastFollow = now
            Self.setPosition(other, CGPoint(x: x, y: goals[1].minY))
            Self.setSize(other, CGSize(width: area.maxX - x, height: goals[1].height))
        } else {
            // The right window's left edge is the divider, while its right edge stays put.
            guard abs(moved.maxX - goals[1].maxX) < 3 else { return }
            let width = moved.minX - gap - area.minX
            guard width > 120 else { return }
            driving = element
            lastFollow = now
            Self.setSize(other, CGSize(width: width, height: goals[0].height))
        }
    }

    private func watch() {
        for pane in panes where observers[pane.pid] == nil {
            var created: AXObserver?
            guard AXObserverCreate(pane.pid, { _, element, notification, refcon in
                guard let refcon else { return }
                let lockIn = Unmanaged<LockIn>.fromOpaque(refcon).takeUnretainedValue()
                let name = notification as String
                MainActor.assumeIsolated { lockIn.windowChanged(element, name) }
            }, &created) == .success, let observer = created else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pane.pid] = observer
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pane in panes {
            guard let observer = observers[pane.pid] else { continue }
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, pane.element, name as CFString, refcon)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBorder() }
            }
        }
    }

    private func stopWatching() {
        pendingFit?.cancel()
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
    }

    private func windowChanged(_ element: AXUIElement, _ notification: String) {
        guard isOn else { return }
        if notification == kAXUIElementDestroyedNotification, panes.contains(where: { CFEqual($0.element, element) }) {
            // One of the two was closed: lock-in is over.
            return exit()
        }
        updateBorder()
        // While you drag one window's inner edge, the other follows it straight away.
        if notification == kAXWindowResizedNotification, NSEvent.pressedMouseButtons != 0 {
            follow(element)
        }
        // Wait until the mouse button is up, so it never fights a drag you're in the middle of.
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                if NSEvent.pressedMouseButtons != 0 { return self.windowChanged(element, notification) }
                self.driving = nil
                self.settle()
            }
        }
        pendingFit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: The glowing edge

    /// Around whichever of the two you're using; none while you're in another app.
    private func updateBorder() {
        guard isOn, BarSettings.lockInBorder,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let pane = panes.first(where: { $0.pid == front }),
              let frame = Self.frame(of: pane.element) else {
            border?.orderOut(nil)
            return
        }
        let border = self.border ?? BorderPanel()
        self.border = border
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        border.show(around: rect, color: accent(screen))
    }

    // MARK: Helpers

    private static func wait(seconds: Double, until done: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return done()
    }

    private static func explain(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    /// In place, allowing for apps like Terminal that round their size to whole lines of text.
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
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
        // Only on the desktop it was made on.
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
        orderFrontRegardless()
    }
}
