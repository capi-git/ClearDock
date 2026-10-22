import AppKit

/// A borderless, see-through panel that floats at Dock level on every Space
/// and never takes focus from the app you are using.
class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        canHide = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A one-point strip along the bottom edge of a screen, under where the icons sit.
/// It wakes the app only when the pointer (or a dragged file) touches it, so a hidden dock
/// uses no processor time at all.
@MainActor
final class TriggerPanel: OverlayPanel {
    init(onReveal: @escaping @MainActor () -> Void) {
        super.init()
        // Catch the pointer even though the strip is effectively invisible.
        backgroundColor = NSColor(white: 0, alpha: 0.01)
        ignoresMouseEvents = false
        contentView = TriggerView(onReveal: onReveal)
    }
}

@MainActor
private final class TriggerView: NSView {
    private let onReveal: @MainActor () -> Void

    init(onReveal: @escaping @MainActor () -> Void) {
        self.onReveal = onReveal
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onReveal() }
    override func mouseDown(with event: NSEvent) { onReveal() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onReveal()
        return []
    }
}

/// Places the dock, shows and hides it, and keeps the edge triggers in step.
/// Everything is driven by events; there is no polling.
@MainActor
final class DockController {
    private let model = DockModel()
    private let panel = OverlayPanel()
    private let view: DockView
    private let container: DockContainerView
    private let previews = WindowPreviewController()
    private let spaceKeeper = DockSpaceKeeper.shared
    /// True while the app in front is in full screen; the dock then tucks away like the macOS Dock.
    private var fullScreenFront = false
    /// Kept on screen while the settings window is open, so changes can be seen as they happen.
    var keepVisible = false {
        didSet { if keepVisible != oldValue { settingsChanged() } }
    }
    private var triggers: [TriggerPanel] = []
    private var screen: NSScreen?
    private var shown = false
    private var hideTimer: Timer?
    private var trashTimer: Timer?
    private var pendingResize: DispatchWorkItem?
    private var badgeTimer: Timer?
    /// For checking badge drawing: launch with `-previewBadges 5` to put that count on every app.
    private let previewBadge = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["previewBadges"] as? String

    init() {
        view = DockView(model: model)
        // Draw icons for the main screen from the start, so they aren't drawn twice at launch.
        view.scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        container = DockContainerView(dock: view)
        panel.contentView = container
        container.background.apply()
        view.onEnter = { [weak self] in self?.cancelHide() }
        view.onExit = { [weak self] in self?.scheduleHide() }
        view.onHover = { [weak self] index in self?.hoverChanged(index) }
        view.onPress = { [weak self] in self?.previews.close() }
        view.onMagnifiedSpan = { [weak self] span in
            guard let self else { return }
            self.container.barRect = self.model.layout.barRect(from: span?.lowerBound, to: span?.upperBound)
        }
        previews.onExit = { [weak self] in self?.scheduleHide() }
        view.settingsMenu = { [weak self] in
            let menu = NSMenu()
            SettingsMenu.add(to: menu) { self?.settingsChanged() }
            return menu
        }
        model.onChange = { [weak self] in self?.modelChanged() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }

        // Redraw when the wallpaper's colours change (only checked when a setting uses them).
        NotificationCenter.default.addObserver(forName: WallpaperPalette.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.container.background.apply()
                self?.view.update(animated: false)
            }
        }

        // Notice when an app goes into or out of full screen.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.refreshWallpaperColors() }
                    self?.checkFullScreen()
                    // Going full screen animates for a moment; look again once it has settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        MainActor.assumeIsolated { self?.checkFullScreen() }
                    }
                }
            }
        }

        model.reload()
        applyMode()
        refreshWallpaperColors()
        view.applyPreviewHover()
    }

    private func refreshWallpaperColors() {
        guard Appearance.usesWallpaper else { return }
        WallpaperPalette.shared.refresh(for: currentScreen)
    }

    private func checkFullScreen() {
        let now = FullScreenCheck.frontAppIsFullScreen()
        guard now != fullScreenFront else { return }
        fullScreenFront = now
        applyMode()
    }

    func settingsChanged() {
        if let screen, !NSScreen.screens.contains(screen) { self.screen = nil }
        Appearance.reload()
        container.background.apply()
        refreshWallpaperColors()
        model.reload()
        applyMode()
        if shown { startBadgeUpdates() }
    }

    private var currentScreen: NSScreen? { screen ?? NSScreen.screens.first }

    private var edge: DockEdge { model.layout.edge }

    /// How much of the dock's screen edge Apple's Dock is taking up, when it is set to stay
    /// visible there (for example after "Hide the macOS Dock" is turned off). Zero otherwise.
    private func appleDockInset(on screen: NSScreen) -> CGFloat {
        // While Clear Dock keeps Apple's Dock hidden, any room macOS still keeps for it is left over
        // from before: when the Dock is put back and hidden again (Clear Dock quitting and opening),
        // macOS can go on keeping the room the visible Dock had.
        if Settings.hideSystemDock { return 0 }
        let reserved: CGFloat = switch edge {
        case .bottom: screen.visibleFrame.minY - screen.frame.minY
        case .left: screen.visibleFrame.minX - screen.frame.minX
        case .right: screen.frame.maxX - screen.visibleFrame.maxX
        }
        // A hidden Dock can still reserve a few points; only a visible one takes more.
        return reserved > 10 ? reserved : 0
    }

    /// Clear Dock sits beside a visible Apple Dock instead of on top of it. Sliding in from
    /// the screen edge would mean passing through Apple's Dock, so it stays put in that case.
    private var autoHides: Bool {
        guard !keepVisible, Settings.autoHide || fullScreenFront else { return false }
        return NSScreen.screens.allSatisfy { appleDockInset(on: $0) == 0 }
    }

    private func applyMode() {
        trashTimer?.invalidate()
        trashTimer = nil
        if autoHides {
            // If hiding was just turned on from the dock itself, slide away once the pointer leaves.
            if shown { scheduleHide() } else { hide(animated: false) }
        } else {
            removeTriggers()
            show(on: NSScreen.screens.first, animated: false)
            // A visible dock checks whether the Trash has filled every 15 seconds; the system
            // may batch this with other work.
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refreshTrash() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .default)
            trashTimer = timer
        }
        updateReservedSpace()
    }

    /// While the dock stays on screen, keep windows from going underneath it.
    private func updateReservedSpace() {
        guard !autoHides, shown, let screen = currentScreen else {
            spaceKeeper.reserve(edge: edge, line: nil, on: nil)
            return
        }
        let settled = frame(on: screen, visible: true)
        let line: CGFloat = switch edge {
        case .bottom: settled.maxY
        case .left: settled.maxX
        case .right: settled.minX
        }
        spaceKeeper.reserve(edge: edge, line: line, on: screen)
    }

    private func modelChanged() {
        container.barRect = model.layout.barRect()
        pendingResize?.cancel()
        pendingResize = nil
        guard let screen = currentScreen else { return view.update(animated: false) }
        let target = frame(on: screen, visible: shown)
        let current = panel.frame

        // Only animate what you can see, and not when the icon size or the edge changed.
        let vertical = edge.isVertical
        let sameDepth = vertical ? current.width == target.width : current.height == target.height
        guard shown, panel.isVisible, current.width > 0, sameDepth else {
            panel.setFrame(target, display: false)
            view.update(animated: false)
            if autoHides && !shown { placeTriggers() }
            return
        }

        // The window stays centred, so when its length changes the icons have to be shifted
        // to stay put on screen while they glide.
        let half = vertical ? (current.height - target.height) / 2 : (current.width - target.width) / 2
        if half <= 0 {
            // An app opened: widen the window first, then glide the icons apart.
            view.shift(by: -half)
            panel.setFrame(target, display: false)
            view.update(animated: true)
        } else {
            // An app quit: glide the icons together inside the old width, then narrow the window.
            view.update(animated: true, offset: half)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let screen = self.currentScreen else { return }
                    self.panel.setFrame(self.frame(on: screen, visible: self.shown), display: false)
                    self.view.update(animated: false)
                }
            }
            pendingResize = work
            DispatchQueue.main.asyncAfter(deadline: .now() + DockView.animationDuration + 0.02, execute: work)
        }
    }

    /// Where the dock window goes: centred along its edge, either showing or tucked just off screen.
    private func frame(on screen: NSScreen, visible: Bool) -> NSRect {
        let size = model.layout.size
        let s = screen.frame
        let away = appleDockInset(on: screen) + CGFloat(Appearance.edgeGap)
        switch edge {
        case .bottom:
            let x = (s.midX - size.width / 2).rounded()
            return NSRect(x: x, y: visible ? s.minY + away : s.minY - size.height, width: size.width, height: size.height)
        case .left:
            let y = (s.midY - size.height / 2).rounded()
            return NSRect(x: visible ? s.minX + away : s.minX - size.width, y: y, width: size.width, height: size.height)
        case .right:
            let y = (s.midY - size.height / 2).rounded()
            return NSRect(x: visible ? s.maxX - size.width - away : s.maxX, y: y, width: size.width, height: size.height)
        }
    }

    // MARK: Showing and hiding

    private func show(on screen: NSScreen?, animated: Bool) {
        guard let screen else { return }
        cancelHide()
        if !shown || self.screen != screen {
            self.screen = screen
            view.scale = screen.backingScaleFactor
            panel.setFrame(frame(on: screen, visible: false), display: false)
            panel.alphaValue = 0
        }
        shown = true
        model.refreshTrash()
        startBadgeUpdates()
        triggers.forEach { $0.orderOut(nil) }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        let target = frame(on: screen, visible: true)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
        }
    }

    private func hide(animated: Bool) {
        shown = false
        cancelHide()
        stopBadgeUpdates()
        previews.close()
        panel.ignoresMouseEvents = true
        if autoHides { placeTriggers() }
        guard let screen = currentScreen else { return }

        let target = frame(on: screen, visible: false)
        let finish = { [weak self] in
            // Take the hidden dock off screen entirely so the system has nothing to draw.
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { finish() }
            })
        } else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            finish()
        }
    }

    /// After the pointer leaves the icons, wait a moment, then hide unless it came back
    /// or is still hovering just around the dock.
    private func scheduleHide() {
        guard autoHides, shown else { return }
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHide() }
        }
        // Default mode only, so the dock stays put while a right-click menu is open.
        RunLoop.main.add(timer, forMode: .default)
        hideTimer = timer
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func checkHide() {
        hideTimer = nil
        guard autoHides, shown, let screen = currentScreen else { return }
        let settled = frame(on: screen, visible: true)
        let mouse = NSEvent.mouseLocation
        // Once the system knows the pointer is over the dock, it reports when it leaves.
        if settled.contains(mouse) && view.isPointerInside { return }
        // Stay up while the pointer is on a window preview.
        if previews.contains(mouse) { return scheduleHide() }
        let nearby = settled.insetBy(dx: -20, dy: -20)
        if nearby.contains(mouse) || view.isBusy {
            scheduleHide()
        } else {
            hide(animated: true)
        }
    }

    // MARK: Window previews

    private func hoverChanged(_ index: Int?) {
        guard shown, let screen = currentScreen else { return }
        guard let index, index < model.items.count else {
            previews.hover(over: nil, pid: nil, anchor: .zero, screen: screen, scale: screen.backingScaleFactor, edge: edge)
            return
        }
        let settled = frame(on: screen, visible: true)
        let icon = model.layout.frames[index]
        // The icon's place on screen (the view measures from the top, the screen from the bottom).
        let anchor = NSRect(x: settled.minX + icon.minX, y: settled.maxY - icon.maxY, width: icon.width, height: icon.height)
        previews.hover(over: model.items[index], pid: model.processID(at: index), anchor: anchor,
                       screen: screen, scale: screen.backingScaleFactor, edge: edge)
    }

    // MARK: Notification badges

    /// Notification counts are only checked while the dock is on screen: once straight away,
    /// then every couple of seconds. A hidden dock never asks.
    private func startBadgeUpdates() {
        stopBadgeUpdates()
        guard Settings.showBadges, BadgeReader.hasPermission || previewBadge != nil else {
            model.setBadges([:])
            return
        }
        refreshBadges()
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .default)
        badgeTimer = timer
    }

    private func stopBadgeUpdates() {
        badgeTimer?.invalidate()
        badgeTimer = nil
    }

    private func refreshBadges() {
        if let previewBadge {
            var all: [String: String] = [:]
            for item in model.items where item.kind == .app {
                if let url = item.url { all[url.standardizedFileURL.path] = previewBadge }
            }
            model.setBadges(all)
            return
        }
        model.setBadges(BadgeReader.read())
    }

    // MARK: Edge triggers

    private func placeTriggers() {
        let screens = NSScreen.screens
        while triggers.count < screens.count {
            triggers.append(TriggerPanel { [weak self] in self?.reveal() })
        }
        while triggers.count > screens.count {
            triggers.removeLast().orderOut(nil)
        }
        // A one-point strip along the dock's edge of each screen, as long as the dock.
        let length = (edge.isVertical ? model.layout.size.height : model.layout.size.width) + 32
        for (trigger, screen) in zip(triggers, screens) {
            let s = screen.frame
            let rect: NSRect = switch edge {
            case .bottom: NSRect(x: (s.midX - length / 2).rounded(), y: s.minY, width: length, height: 1)
            case .left: NSRect(x: s.minX, y: (s.midY - length / 2).rounded(), width: 1, height: length)
            case .right: NSRect(x: s.maxX - 1, y: (s.midY - length / 2).rounded(), width: 1, height: length)
            }
            trigger.setFrame(rect, display: false)
            if !shown { trigger.orderFrontRegardless() }
        }
    }

    private func removeTriggers() {
        triggers.forEach { $0.orderOut(nil) }
        triggers.removeAll()
    }

    private func reveal() {
        guard autoHides, !shown else { return }
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
        show(on: target, animated: true)
        // Hide again if the pointer moves away without ever reaching the icons.
        scheduleHide()
    }
}
