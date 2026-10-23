import AppKit
import os

/// Why the dock showed or hid, readable with: log show --predicate 'subsystem == "local.cleardock" && category == "dock"'
let dockLog = Logger(subsystem: "local.cleardock", category: "dock")

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
    /// True while the desktop showing on the dock's screen is locked in; the dock then tucks away too.
    private var lockedIn = false
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
    /// Sliding in or out right now. Changes meanwhile (a badge, an app opening) wait until it's
    /// done, so the slide isn't cut short by the window jumping to its new size.
    private var sliding = false
    private var changedWhileSliding = false
    /// For checking badge drawing: launch with `-previewBadges 5` to put that count on every app.
    private let previewBadge = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["previewBadges"] as? String

    init() {
        view = DockView(model: model)
        // Draw icons for the main screen from the start, so they aren't drawn twice at launch.
        view.scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        container = DockContainerView(dock: view)
        panel.contentView = container
        applyBackground()
        view.onEnter = { [weak self] in self?.cancelHide() }
        view.onExit = { [weak self] in self?.scheduleHide() }
        view.onHover = { [weak self] index in self?.hoverChanged(index) }
        view.onPress = { [weak self] in self?.previews.close() }
        view.onMagnifiedSpan = { [weak self] span in
            guard let self else { return }
            self.container.barRect = self.model.layout.barRect(from: span?.lowerBound, to: span?.upperBound)
        }
        previews.onExit = { [weak self] in self?.scheduleHide() }
        previews.pointerOnDock = { [weak self] in
            guard let self, self.shown else { return false }
            return self.panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        }
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
                self?.applyBackground()
                self?.view.update(animated: false)
            }
        }

        // Notice when an app goes into or out of full screen.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        self?.refreshWallpaperColors()
                        self?.checkLockIn()
                    }
                    self?.checkFullScreen()
                    // Going full screen animates for a moment; look again once it has settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        MainActor.assumeIsolated { self?.checkFullScreen() }
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: LockIn.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLockIn() }
        }

        // Nothing to show while the displays sleep: no badge reading then.
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopBadgeUpdates() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shown else { return }
                self.startBadgeUpdates()
            }
        }

        // After sleep, and when an app quits (a full-screen one, say), look again at whether the dock
        // should be tucked away, and that it's on screen if it shouldn't: macOS can take windows off
        // the screen around sleep without saying so.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkFullScreen()
                    self.checkLockIn()
                    self.keepOnScreen(because: name == NSWorkspace.didTerminateApplicationNotification ? "an app quit" : "waking up")
                }
            }
        }

        // When matching the top bar, its look changing (its settings, the wallpaper, the desktop's
        // colour) changes the dock's too.
        NotificationCenter.default.addObserver(forName: BarLookShare.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Appearance.matchesBar else { return }
                let hadBackground = self.model.layout.hasBackground
                self.applyBackground()
                // A background needs a little room round the icons; without one, they sit closer.
                if Appearance.hasBackground != hadBackground { self.model.reload() } else { self.view.update(animated: false) }
            }
        }

        model.reload()
        applyMode()
        refreshWallpaperColors()
        view.applyPreviewHover()
    }

    /// Draws the background, in the dock's own look or, when matching, the top bar's.
    private func applyBackground() {
        let look = Appearance.matchesBar ? BarLookShare.look(for: currentScreen) : nil
        container.background.barLook = look
        DockView.barAccent = look?.accent
        container.background.apply()
    }

    private func checkLockIn() {
        let now = !LockIn.lockedSpaces.isEmpty
            && currentScreen.flatMap(WindowSpaces.currentSpaceID(on:)).map(LockIn.lockedSpaces.contains) == true
        guard now != lockedIn else { return keepOnScreen(because: "desktop changed") }
        lockedIn = now
        dockLog.notice("Dock: lock-in desktop showing: \(now)")
        applyMode()
    }

    /// While the dock should stay on screen, makes sure it is, putting it back if macOS took it off.
    private func keepOnScreen(because reason: String) {
        guard !autoHides, !shown || !panel.isVisible else { return }
        dockLog.notice("Dock: wasn't on screen though it should be (\(reason, privacy: .public)); showing it again")
        removeTriggers()
        show(on: currentScreen ?? NSScreen.screens.first, animated: false, because: reason)
        updateReservedSpace()
    }

    private func refreshWallpaperColors(unlessRecent: Bool = false) {
        guard Appearance.usesWallpaper else { return }
        // There's one set of wallpaper colours, shared with the top bar: always from the main
        // screen, so the two never pull it between screens with different wallpapers.
        WallpaperPalette.shared.refresh(for: NSScreen.screens.first, unlessRecent: unlessRecent)
    }

    /// Whether the dock's screen is showing a full-screen app, as macOS records it for each screen:
    /// asking the app in front instead could wait on it while it's busy, and say nothing about
    /// which screen it's on.
    private func checkFullScreen() {
        let displays = DesktopReader.fullScreenDisplays()
        let now = displays.contains("Main") || (currentScreen?.displayUUID).map(displays.contains) == true
        guard now != fullScreenFront else { return keepOnScreen(because: "checking for full screen") }
        fullScreenFront = now
        dockLog.notice("Dock: full-screen app showing: \(now)")
        applyMode()
    }

    func settingsChanged() {
        if let screen, !NSScreen.screens.contains(screen) { self.screen = nil }
        Appearance.reload()
        applyBackground()
        refreshWallpaperColors(unlessRecent: true)
        model.reload()
        applyMode()
        // Badges only need starting or stopping when that's what changed.
        let wantsBadges = Settings.showBadges && (BadgeReader.hasPermission || previewBadge != nil)
        if shown && (badgeTimer != nil) != wantsBadges { startBadgeUpdates() }
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
        guard !keepVisible, Settings.autoHide || fullScreenFront || lockedIn else { return false }
        return NSScreen.screens.allSatisfy { appleDockInset(on: $0) == 0 }
    }

    private func applyMode() {
        trashTimer?.invalidate()
        trashTimer = nil
        dockLog.notice("Dock: \(self.autoHides ? "hides itself" : "stays on screen", privacy: .public) (hiding: \(Settings.autoHide), full screen: \(self.fullScreenFront), lock-in: \(self.lockedIn), settings open: \(self.keepVisible))")
        if autoHides {
            // If hiding was just turned on from the dock itself, slide away once the pointer leaves.
            if shown { scheduleHide() } else { hide(animated: false, because: "hiding is on") }
        } else {
            removeTriggers()
            show(on: NSScreen.screens.first, animated: false, because: "staying on screen")
            // A visible dock checks whether the Trash has filled every 15 seconds (and that it's still
            // on screen); the system may batch this with other work.
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.refreshTrash()
                    self?.keepOnScreen(because: "regular check")
                }
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
        if sliding {
            changedWhileSliding = true
            return
        }
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
            // The bar is shifted along with them meanwhile, so it stays centred under them.
            let bar = model.layout.barRect()
            container.barRect = vertical ? bar.offsetBy(dx: 0, dy: half) : bar.offsetBy(dx: half, dy: 0)
            view.update(animated: true, offset: half)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let screen = self.currentScreen else { return }
                    self.panel.setFrame(self.frame(on: screen, visible: self.shown), display: false)
                    self.container.barRect = self.model.layout.barRect()
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

    private func show(on screen: NSScreen?, animated: Bool, because reason: String = "pointer at the edge") {
        guard let screen else { return }
        if !shown { dockLog.notice("Dock: showing (\(reason, privacy: .public))") }
        cancelHide()
        let movedScreen = self.screen != screen
        if !shown || movedScreen {
            self.screen = screen
            view.scale = screen.backingScaleFactor
            // Matching the bar: the bar on this screen (it may have its own desktop's colour).
            if movedScreen && Appearance.matchesBar { applyBackground() }
            // From just off the edge, unless it's still on its way out: then it turns round from there.
            if !panel.isVisible || movedScreen {
                panel.setFrame(frame(on: screen, visible: false), display: false)
                panel.alphaValue = 0
            }
        }
        shown = true
        model.refreshTrash()
        startBadgeUpdates()
        triggers.forEach { $0.orderOut(nil) }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        let target = frame(on: screen, visible: true)
        if animated {
            beginSlide()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: {
                MainActor.assumeIsolated { self.slideFinished() }
            })
        } else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
        }
    }

    private func hide(animated: Bool, because reason: String = "pointer left") {
        if shown { dockLog.notice("Dock: hiding (\(reason, privacy: .public))") }
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
            beginSlide()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    self.slideFinished()
                    finish()
                }
            })
        } else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            finish()
        }
    }

    private func beginSlide() {
        sliding = true
        // In case macOS never says the slide finished, catch up shortly after it should have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { if self?.sliding == true { self?.slideFinished() } }
        }
    }

    /// Catches up on whatever changed while the dock was sliding.
    private func slideFinished() {
        sliding = false
        guard changedWhileSliding else { return }
        changedWhileSliding = false
        modelChanged()
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
        var anchor = NSRect(x: settled.minX + icon.minX, y: settled.maxY - icon.maxY, width: icon.width, height: icon.height)
        // Out past the dock's own window, which has room for a magnified or lifted icon: a preview
        // over the icon would take the pointer off the dock, and the icon would shrink and grow again.
        switch edge {
        case .bottom: anchor.origin.y = max(anchor.origin.y, settled.maxY - 4 - anchor.height)
        case .left: anchor.origin.x = max(anchor.origin.x, settled.maxX - 4 - anchor.width)
        case .right: anchor.origin.x = min(anchor.origin.x, settled.minX + 4)
        }
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
        // Reading them goes through every item in the macOS Dock, so not too often.
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
        timer.tolerance = 1.5
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
        // Reading them asks the Dock, which can take a while: away from the main thread, so the
        // dock's own animations never wait on it.
        guard !readingBadges else { return }
        readingBadges = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let badges = BadgeReader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.readingBadges = false
                    if self.badgeTimer != nil { self.model.setBadges(badges) }
                }
            }
        }
    }

    private var readingBadges = false

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
