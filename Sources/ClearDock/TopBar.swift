import AppKit
import SwiftUI

/// How the top bar looks right now, worked out from its settings and the wallpaper.
struct BarLook: Equatable {
    var style = BarStyle.wallpaper
    var fill = NSColor.black
    var opacity = 0.62
    var accent = NSColor.systemBlue
    var size = BarSize.medium
    var font = BarFont.rounded
    var cornerRadius: CGFloat = 9
    var showDate = true
    var use24Hour = false
    var desktopStyle = DesktopStyle.separate
    var numberPerScreen = false
    var peekDesktops = true
    var albumColours = true
    var miniPlayer = true
    /// A colour the glass is tinted with, for a desktop's or an album's colour.
    var glassTint: NSColor?

    /// The look shifted towards a colour: the highlight becomes it, and the bar's own colour leans
    /// towards a dark shade of it (or of `base`, when given), so the text stays readable.
    func tinted(_ colour: NSColor, base: NSColor? = nil) -> BarLook {
        var look = self
        look.accent = colour
        let dark = (base ?? colour).blended(withFraction: base == nil ? 0.72 : 0.45, of: .black) ?? colour
        look.fill = fill.blended(withFraction: 0.6, of: dark) ?? fill
        look.glassTint = colour
        return look
    }

    /// Dark text on a light bar, light text otherwise.
    var text: Color {
        let lightBar = (style == .color || style == .wallpaper) && opacity > 0.45 && fill.lightness > 0.6
        return lightBar ? Color.black.opacity(0.82) : Color.white.opacity(0.94)
    }
    var onAccent: Color { accent.lightness > 0.5 ? Color.black.opacity(0.8) : .white }

    func font(_ weight: Font.Weight, size points: CGFloat? = nil) -> Font {
        let points = points ?? size.fontSize
        switch font {
        case .rounded: return .system(size: points, weight: weight, design: .rounded)
        case .standard: return .system(size: points, weight: weight)
        case .mono: return .system(size: points - 0.5, weight: weight, design: .monospaced)
        }
    }
}

/// Where a screen's bar puts things: its width, and the room left in the middle for the camera
/// notch or another app's island (like Vorssaint's).
struct BarLayout: Equatable {
    var width: CGFloat = 0
    var middleGap: CGFloat = 0
    /// Which display's desktops this bar shows.
    var desktopsKey = "Main"
}

/// Colours taken from an album cover.
struct ArtColours: Equatable {
    let base: NSColor
    let accent: NSColor
}

/// Everything the bar views draw from. Shared by the bars on every screen.
@MainActor
final class TopBarModel: ObservableObject {
    @Published var items: [BarItem] = []
    @Published var look = BarLook()
    @Published var layouts: [String: BarLayout] = [:]
    @Published var desktops: [String: [Desktop]] = [:]
    @Published var desktopNames: [String: String] = [:]
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var track: NowPlaying.Track?
    @Published var volume: Float?
    @Published var muted = false
    @Published var battery: Int?
    @Published var charging = false
    @Published var pluggedIn = false
    @Published var now = Date()
    @Published var desktopColours: [String: DesktopColour] = [:]
    @Published var artwork: NSImage?
    @Published var artColours: ArtColours?
    /// Screens whose bar is a thin line while a game is in front.
    @Published var thinScreens = Set<String>()
    /// Screens whose bar is filled in behind its pieces while the pointer is at the top, so the
    /// macOS menu bar sliding down underneath doesn't show through.
    @Published var backdropScreens = Set<String>()

    /// Things the views ask the controller to do.
    var toggleMute: () -> Void = {}
    var changeVolume: (Float) -> Void = { _ in }
    var rename: (Desktop) -> Void = { _ in }
    var forget: (Desktop) -> Void = { _ in }
    var setColour: (Desktop, DesktopColour?) -> Void = { _, _ in }
    var hide: (BarItemKind) -> Void = { _ in }
    var playPause: () -> Void = {}
    var nextSong: () -> Void = {}
    var previousSong: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
    /// The pointer moved onto (or, with nil, off) a desktop or the song, for their pop-ups.
    var hoverDesktop: (Desktop?) -> Void = { _ in }
    var hoverSong: (Bool) -> Void = { _ in }

    /// The song's look: tinted with the album cover's colours, when that's on.
    func songLook(_ base: BarLook) -> BarLook {
        guard base.albumColours, let art = artColours else { return base }
        return base.tinted(art.accent, base: art.base)
    }

    /// The look for one screen's bar: tinted with its current desktop's colour, if it has one.
    func look(for desktopsKey: String) -> BarLook {
        guard let current = desktops[desktopsKey]?.first(where: \.isCurrent),
              let colour = desktopColours[current.key] else { return look }
        return look.tinted(colour.color)
    }

    private var icons: [pid_t: NSImage] = [:]

    func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    /// Forget icons of apps that have quit.
    func pruneIcons() {
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        icons = icons.filter { running.contains($0.key) }
    }
}

/// A see-through strip along the top of a screen: above the macOS menu bar, so it stays in front
/// when that slides down until you hold the pointer at the top, and below notch apps like
/// Vorssaint, so their islands draw over it. It isn't shown over full-screen apps.
@MainActor
final class BarPanel: OverlayPanel {
    override init() {
        super.init()
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
    }

    /// macOS keeps windows below the menu bar's spot even while the menu bar is hidden; the
    /// bar goes exactly where it's put, so it can take that spot.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts a bar's view, and notices when the pointer reaches the very top of the screen, where
/// the macOS menu bar slides down.
@MainActor
final class BarHostingView: NSHostingView<TopBarView> {
    var onTopEdge: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let window, let screen = window.screen else { return }
        if NSEvent.mouseLocation.y >= screen.frame.maxY - 1.5 { onTopEdge() }
    }
}

/// Puts a bar along the top of each screen and keeps what it shows up to date. Everything is
/// driven by system events, apart from a light check of each desktop's windows every few seconds
/// (macOS doesn't announce windows opening and closing).
@MainActor
final class TopBarController {
    private let model = TopBarModel()
    private var panels: [CGDirectDisplayID: (panel: BarPanel, view: BarHostingView)] = [:]
    private let nowPlaying = NowPlaying()
    private let volume = SystemVolume()
    private let battery = BatteryStatus()
    private var running = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var clockTimer: Timer?
    private var desktopTimer: Timer?
    private var revealTimer: Timer?
    private var revealStarted = Date.distantPast
    /// Watches the pointer while it's at the top of a screen, before the macOS menu bar shows.
    private var holdTimer: Timer?
    private var holdScreen: CGDirectDisplayID?
    private var heldSince: Date?
    private var leftTopSince: Date?
    private var pendingLayout: DispatchWorkItem?
    /// Screens where a game or another full-screen window is in front; the bar steps aside there.
    private var coveredScreens = Set<CGDirectDisplayID>()
    /// Bars sliding away from a game right now.
    private var leaving = Set<CGDirectDisplayID>()
    private let popover = BarPopover()

    init() {
        nowPlaying.onChange = { [weak self] in
            guard let self else { return }
            let songChanged = !(self.nowPlaying.track?.isSameSong(as: self.model.track) ?? (self.model.track == nil))
            self.model.track = self.nowPlaying.track
            if self.model.artwork !== self.nowPlaying.artwork {
                self.model.artwork = self.nowPlaying.artwork
                self.model.artColours = self.nowPlaying.artwork.flatMap(Self.colours(of:))
            }
            if self.model.track == nil, self.popover.showing == "song" { self.popover.hide() }
            // A notch app's island often grows while music plays; make room once it has.
            if songChanged { self.scheduleLayout(after: 1) }
        }
        volume.onChange = { [weak self] in
            guard let self else { return }
            if self.model.volume != self.volume.level { self.model.volume = self.volume.level }
            if self.model.muted != self.volume.muted { self.model.muted = self.volume.muted }
        }
        battery.onChange = { [weak self] in
            guard let self else { return }
            self.model.battery = self.battery.percent
            self.model.charging = self.battery.charging
            self.model.pluggedIn = self.battery.pluggedIn
        }
        model.toggleMute = { [weak self] in self?.volume.toggleMute() }
        model.changeVolume = { [weak self] change in
            guard let self, let level = self.volume.level else { return }
            self.volume.set(level + change)
        }
        model.rename = { [weak self] desktop in self?.rename(desktop) }
        model.forget = { desktop in
            var names = BarSettings.desktopNames
            names[desktop.key] = nil
            BarSettings.desktopNames = names
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }
        model.setColour = { desktop, colour in
            var colours = BarSettings.desktopColours
            colours[desktop.key] = colour
            BarSettings.desktopColours = colours
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }
        model.playPause = { [weak self] in self?.nowPlaying.playPause() }
        model.nextSong = { [weak self] in self?.nowPlaying.next() }
        model.previousSong = { [weak self] in self?.nowPlaying.previous() }
        model.seek = { [weak self] seconds in self?.nowPlaying.seek(to: seconds) }
        model.hoverDesktop = { [weak self] desktop in self?.hoverDesktop(desktop) }
        model.hoverSong = { [weak self] inside in self?.hoverSong(inside) }
        model.hide = { kind in
            BarSettings.items = BarSettings.items.map { $0.kind == kind ? BarItem(kind: $0.kind, side: $0.side, isOn: false) : $0 }
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }

        NotificationCenter.default.addObserver(forName: BarSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    func settingsChanged() {
        applyMenuBarSetting()
        guard BarSettings.enabled else { return stop() }
        start()
        model.items = BarSettings.items
        model.desktopNames = BarSettings.desktopNames
        model.desktopColours = BarSettings.desktopColours
        applyLook()
        refreshWallpaperColors()
        layout()
    }

    /// Hides the macOS menu bar while the bar replaces it, and puts it back otherwise.
    private func applyMenuBarSetting() {
        let wanted = BarSettings.enabled && BarSettings.replaceMenuBar
        if wanted {
            // Only once: other settings changes shouldn't ask System Events again.
            guard !SystemMenuBar.isHiddenByClearDock, SystemMenuBar.hide() else { return }
        } else {
            guard SystemMenuBar.isHiddenByClearDock else { return }
            SystemMenuBar.restore()
        }
        // Move the bar now, and again once the menu bar has finished sliding away or back,
        // since windows and the notch area only settle then.
        layout()
        for delay in [0.4, 1.2, 3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.layout() }
            }
        }
    }

    // MARK: Starting and stopping

    private func start() {
        guard !running else { return }
        running = true
        nowPlaying.start()
        volume.start()
        battery.start()
        model.track = nowPlaying.track

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.refreshDesktops(); $0.refreshWallpaperColors(); $0.scheduleLayout(after: 0.4) }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) {
            $0.refreshFrontApp()
            $0.refreshDesktops()
            $0.checkCovered()
            // Games often go full screen a moment after they come forward.
            $0.scheduleCoverCheck()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(workspace, name) { $0.refreshDesktops(); $0.model.pruneIcons() }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.tick(); $0.refreshDesktops(); $0.layout() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(.default, WallpaperPalette.didChange) { $0.applyLook() }
        observe(.default, .NSSystemTimeZoneDidChange) { $0.tick() }
        // A right-click menu opening closes any pop-up, so the two don't overlap.
        observe(.default, NSMenu.didBeginTrackingNotification) { $0.popover.hide() }
        // Turning "Automatically hide and show the menu bar" on or off moves the bar.
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")) {
            $0.scheduleLayout(after: 0.5)
        }

        let desktops = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDesktops()
                self?.checkCovered()
            }
        }
        desktops.tolerance = 2
        RunLoop.main.add(desktops, forMode: .common)
        desktopTimer = desktops

        tick()
        refreshFrontApp()
        refreshDesktops()
        checkCovered()
    }

    private func stop() {
        guard running else { return }
        running = false
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        nowPlaying.stop()
        volume.stop()
        battery.stop()
        clockTimer?.invalidate()
        clockTimer = nil
        desktopTimer?.invalidate()
        desktopTimer = nil
        revealTimer?.invalidate()
        revealTimer = nil
        endHold()
        pendingLayout?.cancel()
        popover.hide()
        model.thinScreens = []
        leaving.removeAll()
        for (_, entry) in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        DockSpaceKeeper.shared.reserveTop([])
        MemoryRelief.soon()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (TopBarController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    // MARK: Placing the bars

    private func scheduleLayout(after delay: TimeInterval) {
        guard running else { return }
        pendingLayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.layout() }
        }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func layout() {
        guard running else { return }
        let screens = BarSettings.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        let replacesMenuBar = BarSettings.takesMenuBarsPlace
        let islands = Self.islands()
        let sharedDesktops = model.desktops.keys.contains("Main")
        var layouts: [String: BarLayout] = [:]
        var reserved: [(bottom: CGFloat, screen: NSScreen)] = []
        var kept = Set<CGDirectDisplayID>()
        var thin = Set<String>()
        let gameMode = BarSettings.gameMode

        for screen in screens {
            guard let id = screen.displayID else { continue }
            kept.insert(id)
            let frame = barFrame(on: screen, replacesMenuBar: replacesMenuBar)
            let isNew = panels[id] == nil
            let entry = panels[id] ?? makePanel(for: id)
            let panel = entry.panel
            let wasAway = isNew || !panel.isVisible || leaving.contains(id) || model.thinScreens.contains(String(id))

            // Out of the way of a game, keeping no room for the bar on that screen.
            if coveredScreens.contains(id) && gameMode != .stay {
                if gameMode == .line {
                    // A thin line in the highlight colour along the very top.
                    thin.insert(String(id))
                    leaving.remove(id)
                    let line = NSRect(x: frame.minX, y: frame.maxY - 3, width: frame.width, height: 3)
                    panel.ignoresMouseEvents = true
                    if !panel.isVisible {
                        panel.setFrame(line.offsetBy(dx: 0, dy: 3), display: false)
                        panel.orderFrontRegardless()
                    }
                    if panel.frame != line { Self.animate(panel, to: line, alpha: 1) }
                } else if panel.isVisible, !leaving.contains(id) {
                    // Slide up off the top of the screen.
                    leaving.insert(id)
                    Self.animate(panel, to: frame.offsetBy(dx: 0, dy: frame.height), alpha: 0) { [weak self] in
                        guard let self, self.leaving.contains(id) else { return }
                        self.leaving.remove(id)
                        panel.orderOut(nil)
                    }
                }
                continue
            }

            panel.ignoresMouseEvents = revealTimer != nil
            if wasAway {
                // Slide back down from the top.
                leaving.remove(id)
                if !panel.isVisible || isNew {
                    panel.setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: false)
                    panel.alphaValue = 0
                }
                panel.orderFrontRegardless()
                Self.animate(panel, to: frame, alpha: revealTimer == nil ? 1 : 0)
            } else {
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                panel.orderFrontRegardless()
            }

            // Leave the middle clear for the notch, and for any island drawn over the bar.
            var gap: CGFloat = 0
            if frame.maxY >= screen.frame.maxY - 1, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                gap = screen.frame.width - left.width - right.width + 16
            }
            let barRect = Self.topDown(frame)
            for island in islands where island.intersects(barRect) && abs(island.midX - barRect.midX) < 40 {
                gap = max(gap, 2 * max(barRect.midX - island.minX, island.maxX - barRect.midX) + 16)
            }
            let key = sharedDesktops ? "Main" : (screen.displayUUID ?? "Main")
            layouts[String(id)] = BarLayout(width: frame.width, middleGap: gap, desktopsKey: key)
            reserved.append((frame.minY, screen))
        }
        for (id, entry) in panels where !kept.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
        if model.layouts != layouts { model.layouts = layouts }
        if model.thinScreens != thin { model.thinScreens = thin }
        DockSpaceKeeper.shared.reserveTop(reserved)
    }

    private static func animate(_ panel: NSPanel, to frame: NSRect, alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { done?() }
        })
    }

    private func makePanel(for id: CGDirectDisplayID) -> (panel: BarPanel, view: BarHostingView) {
        let panel = BarPanel()
        let view = BarHostingView(rootView: TopBarView(model: model, screenKey: String(id)))
        view.onTopEdge = { [weak self] in self?.pointerAtTop(of: id) }
        panel.contentView = view
        panels[id] = (panel, view)
        return (panel, view)
    }

    /// Along the very top when the macOS menu bar hides itself, otherwise just under it.
    /// On a screen with a camera notch it's as tall as the notch, so everything lines up with it.
    private func barFrame(on screen: NSScreen, replacesMenuBar: Bool) -> NSRect {
        let top = replacesMenuBar ? screen.frame.maxY : min(screen.frame.maxY, screen.visibleFrame.maxY)
        var height = BarSettings.size.pillHeight + 10
        if replacesMenuBar { height = max(height, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: top - height, width: screen.frame.width, height: height)
    }

    /// Other apps' islands along the top of a screen, like Vorssaint's: small windows above the
    /// menu bar, in the system's window coordinates.
    private static func islands() -> [CGRect] {
        let me = getpid()
        let above = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menus = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer > above, layer < menus,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.width <= 900, rect.height >= 10, rect.height <= 80
            else { return nil }
            return rect
        }
    }

    private static func topDown(_ rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: The macOS menu bar

    /// The pointer reached the very top of a screen. macOS starts sliding its menu bar down there,
    /// underneath the bar. The bar fills in so the menu bar doesn't show through, and only steps
    /// aside once the pointer has been held at the top for a moment.
    private func pointerAtTop(of id: CGDirectDisplayID) {
        guard BarSettings.takesMenuBarsPlace, revealTimer == nil, !coveredScreens.contains(id) else { return }
        if holdScreen != id { heldSince = Date() }
        holdScreen = id
        leftTopSince = nil
        model.backdropScreens = [String(id)]
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHold() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func checkHold() {
        guard let id = holdScreen, let screen = NSScreen.screens.first(where: { $0.displayID == id }),
              let bar = panels[id]?.panel else { return endHold() }
        let mouse = NSEvent.mouseLocation
        let onScreen = NSMouseInRect(mouse, screen.frame, false)
        if onScreen && mouse.y >= screen.frame.maxY - 3 {
            // Still at the very top: show the macOS menu bar once it's been held there long enough.
            leftTopSince = nil
            if heldSince == nil { heldSince = Date() }
            if let since = heldSince, Date().timeIntervalSince(since) >= BarSettings.menuBarDelay {
                endHold(keepBackdrop: true)
                menuBarRevealing(on: id)
            }
            return
        }
        // Moved down off the edge: start counting again next time it touches the top.
        heldSince = nil
        // Keep the fill while the pointer is on the bar (the menu bar may still be down underneath),
        // and a moment after it leaves, while the menu bar slides away.
        if onScreen && mouse.y >= bar.frame.minY - 4 { leftTopSince = nil; return }
        if leftTopSince == nil { leftTopSince = Date() }
        if let since = leftTopSince, Date().timeIntervalSince(since) > 0.35 { endHold() }
    }

    private func endHold(keepBackdrop: Bool = false) {
        holdTimer?.invalidate()
        holdTimer = nil
        holdScreen = nil
        heldSince = nil
        leftTopSince = nil
        if !keepBackdrop { model.backdropScreens = [] }
    }

    /// The pointer was held at the top, so step out of the way of the macOS menu bar, and come back
    /// once the pointer leaves the menus.
    private func menuBarRevealing(on id: CGDirectDisplayID) {
        guard revealTimer == nil else { return }
        revealStarted = Date()
        setBarsVisible(false, only: id)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMenuBarGone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func checkMenuBarGone() {
        let mouse = NSEvent.mouseLocation
        // Still up where the menu bar is.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           mouse.y > screen.frame.maxY - 60 { return }
        // The pointer may be down in an open menu, with the menu bar still showing. Stay out of
        // its way, but not for long, in case the menu bar can't be seen in the window list.
        if Date().timeIntervalSince(revealStarted) < 8, Self.menuBarShowing() { return }
        revealTimer?.invalidate()
        revealTimer = nil
        model.backdropScreens = []
        setBarsVisible(true)
    }

    /// Whether a macOS menu bar is down on any screen right now.
    private static func menuBarShowing() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        return windows.contains { info in
            guard info[kCGWindowLayer as String] as? Int == level,
                  info[kCGWindowOwnerName as String] as? String == "Window Server",
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return NSScreen.screens.contains { abs(topDown($0.frame).minY - rect.minY) < 1 && rect.width >= $0.frame.width - 1 }
        }
    }

    private func setBarsVisible(_ visible: Bool, only id: CGDirectDisplayID? = nil) {
        // Bars stepping aside for a game are left as they are.
        let bars = panels.filter { !coveredScreens.contains($0.key) && (id == nil || $0.key == id) }.map(\.value.panel)
        if !visible { popover.hide() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.1
            for panel in bars { panel.animator().alphaValue = visible ? 1 : 0 }
        }
        for panel in bars { panel.ignoresMouseEvents = !visible }
    }

    // MARK: What it shows

    private func refreshDesktops() {
        guard running, BarSettings.items.contains(where: { $0.kind == .desktops && $0.isOn }) else { return }
        let desktops = DesktopReader.read()
        if desktops != model.desktops {
            let sharedBefore = model.desktops.keys.contains("Main")
            model.desktops = desktops
            if desktops.keys.contains("Main") != sharedBefore { layout() }
        }
    }

    /// Notices when the app in front fills a screen with a game or another full-screen window,
    /// so the bar steps aside there, and comes back once it doesn't.
    private func checkCovered() {
        var covered = Set<CGDirectDisplayID>()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let pid = front.processIdentifier
            let game = Games.isGame(pid)
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in windows where info[kCGWindowOwnerPID as String] as? pid_t == pid {
                guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                for screen in NSScreen.screens {
                    guard let id = screen.displayID else { continue }
                    let area = Self.topDown(screen.frame)
                    let overlap = rect.intersection(area)
                    guard !overlap.isNull else { continue }
                    let share = overlap.width * overlap.height / (area.width * area.height)
                    // A game covering most of a screen, or a special window covering all of it.
                    // An ordinary window made as big as the screen still gets room made for the bar.
                    if (game && share > 0.8) || (layer > 0 && share > 0.97) { covered.insert(id) }
                }
            }
        }
        guard covered != coveredScreens else { return }
        coveredScreens = covered
        layout()
    }

    private func scheduleCoverCheck() {
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.checkCovered() }
            }
        }
    }

    private func refreshFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Clear Dock comes forward for a moment when it starts or switches desktops; keep showing
        // the app you're using then. It only counts while its settings window is open.
        if app.processIdentifier == getpid(),
           !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) { return }
        let name = app.localizedName ?? ""
        if model.appName != name { model.appName = name }
        model.appIcon = model.icon(for: app.processIdentifier)
    }

    /// Updates the clock, then waits for the start of the next minute.
    private func tick() {
        model.now = Date()
        clockTimer?.invalidate()
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    // MARK: Colours

    private func refreshWallpaperColors() {
        guard BarSettings.usesWallpaper else { return }
        WallpaperPalette.shared.refresh(for: NSScreen.screens.first)
    }

    private func applyLook() {
        let palette = WallpaperPalette.shared
        var look = BarLook()
        look.style = BarSettings.style
        // Darken the wallpaper's own colour so light text stands out against it, even on a bright wallpaper.
        let darken = max(0.35, 1 - 0.28 / max(palette.top.lightness, 0.01))
        look.fill = BarSettings.style == .color ? BarSettings.color
            : (palette.top.blended(withFraction: darken, of: .black) ?? palette.top)
        look.opacity = BarSettings.opacity
        let index = BarSettings.accentIndex
        look.accent = index >= 0 ? palette.accents[min(index, palette.accents.count - 1)] : BarSettings.accentColor
        look.size = BarSettings.size
        look.font = BarSettings.font
        look.cornerRadius = CGFloat(BarSettings.cornerRadius)
        look.showDate = BarSettings.showDate
        look.use24Hour = BarSettings.use24Hour
        look.desktopStyle = BarSettings.desktopStyle
        look.numberPerScreen = BarSettings.numberPerScreen
        look.peekDesktops = BarSettings.peekDesktops
        look.albumColours = BarSettings.albumColours
        look.miniPlayer = BarSettings.miniPlayer
        if model.look != look { model.look = look }
    }

    /// A calm colour and the strongest colour of an album cover.
    private static func colours(of image: NSImage) -> ArtColours? {
        var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let colours = WallpaperPalette.colors(in: cg) else { return nil }
        let base = colours.base.blended(withFraction: 0.5, of: colours.top) ?? colours.base
        return ArtColours(base: base, accent: colours.accents.first ?? base)
    }

    // MARK: Pop-ups

    /// The screen under the pointer, and the bottom edge of its bar, for placing a pop-up.
    private func barUnderPointer() -> (screen: NSScreen, bottom: CGFloat)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let id = screen.displayID, let panel = panels[id]?.panel, panel.isVisible else { return nil }
        return (screen, panel.frame.minY)
    }

    private func hoverDesktop(_ desktop: Desktop?) {
        guard let desktop, model.look.peekDesktops, !desktop.isCurrent, let bar = barUnderPointer() else {
            return popover.release()
        }
        let look = model.look
        popover.request("desktop-\(desktop.id)", below: bar.bottom, on: bar.screen) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(DesktopPeekView(model: self.model, desktop: desktop, screen: bar.screen, look: look) { [weak self] in
                self?.popover.hide()
            })
        }
    }

    private func hoverSong(_ inside: Bool) {
        guard inside, model.look.miniPlayer, model.track != nil, let bar = barUnderPointer() else {
            return popover.release()
        }
        if popover.showing != "song" { nowPlaying.refreshPosition() }
        popover.request("song", below: bar.bottom, on: bar.screen) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MiniPlayerView(model: self.model))
        }
    }

    // MARK: Naming desktops

    private func rename(_ desktop: Desktop) {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = "Name Desktop \(desktop.number)"
        alert.informativeText = "The name shows in the top bar instead of the number."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = BarSettings.desktopNames[desktop.key] ?? ""
        field.placeholderString = "Desktop \(desktop.number)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let saved = alert.runModal() == .alertFirstButtonReturn
        previous?.activate()
        guard saved else { return }
        var names = BarSettings.desktopNames
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        names[desktop.key] = name.isEmpty ? nil : name
        BarSettings.desktopNames = names
        NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display's UUID, as Mission Control names displays.
    var displayUUID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
