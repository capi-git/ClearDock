import AppKit
import ScreenCaptureKit
import SwiftUI

/// A small panel that pops up under the bar while the pointer is on a desktop or the song: a
/// picture of that desktop, or a little player. It stays open while the pointer is on it.
@MainActor
final class BarPopover {
    private let panel = PopoverPanel()
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// What's showing, such as "song" or "desktop-…".
    private(set) var showing: String?
    /// What's about to show, after its short pause.
    private var pending: String?
    /// What's showing, or about to.
    var wanted: String? { pending ?? showing }
    /// Checks where the pointer is while a pop-up is open, so it closes even if the system never
    /// said the pointer left (which can happen moving quickly off the bar).
    private var watch: Timer?
    private var misses = 0
    /// The bottom of the bar the pop-up hangs from, and its screen.
    private var bar: (bottom: CGFloat, screen: NSScreen)?

    init() {
        panel.onEnter = { [weak self] in self?.hideWork?.cancel() }
        panel.onExit = { [weak self] in self?.scheduleHide() }
    }

    /// Shows what `content` makes, under the bar, after a short pause. Moving from one desktop to
    /// the next while a pop-up is open switches straight away.
    func request(_ id: String, below barBottom: CGFloat, on screen: NSScreen, content: @escaping @MainActor () -> AnyView) {
        hideWork?.cancel()
        guard showing != id else { return pending = nil }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.show(id, content(), below: barBottom, on: screen)
            }
        }
        showWork = work
        pending = id
        DispatchQueue.main.asyncAfter(deadline: .now() + (showing == nil ? 0.35 : 0.05), execute: work)
    }

    /// The pointer left what the pop-up is for.
    func release() {
        showWork?.cancel()
        pending = nil
        scheduleHide()
    }

    func hide() {
        showWork?.cancel()
        pending = nil
        hideWork?.cancel()
        watch?.invalidate()
        watch = nil
        guard showing != nil else { return }
        showing = nil
        panel.orderOut(nil)
        panel.setContent(nil)
        PeekShots.forgetSoon()
        MemoryRelief.soon()
    }

    private func show(_ id: String, _ content: AnyView, below barBottom: CGFloat, on screen: NSScreen) {
        panel.setContent(content)
        let size = panel.fittingSize
        // Centred under the pointer, kept on the screen, just below the bar.
        let mouse = NSEvent.mouseLocation
        let x = min(max((mouse.x - size.width / 2).rounded(), screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: barBottom - 6 - size.height, width: size.width, height: size.height), display: true)
        if showing == nil {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Each time: a window put away leaves the layer, and would slide with desktop switches.
            BarSpace.add(panel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        showing = id
        bar = (barBottom, screen)
        startWatching()
    }

    private func startWatching() {
        guard watch == nil else { return }
        misses = 0
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// Closes the pop-up after the pointer has been away from both it and the bar for a moment.
    private func checkPointer() {
        guard showing != nil, let bar else { return hide() }
        let mouse = NSEvent.mouseLocation
        let onPopUp = panel.frame.insetBy(dx: -12, dy: -12).contains(mouse)
        let onBar = NSMouseInRect(mouse, bar.screen.frame, false) && mouse.y >= bar.bottom - 2
        if onPopUp || onBar {
            misses = 0
        } else {
            misses += 1
            if misses >= 2 { hide() }
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.panel.isVisible && self.panel.frame.contains(NSEvent.mouseLocation) { return }
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// The pop-up's window: see-through, above the bar, never taking focus from your app.
@MainActor
final class PopoverPanel: OverlayPanel {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    private let container = TrackingView()
    private var host: NSHostingView<AnyView>?

    override init() {
        super.init()
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        contentView = container
        container.onEnter = { [weak self] in self?.onEnter() }
        container.onExit = { [weak self] in self?.onExit() }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func setContent(_ content: AnyView?) {
        host?.removeFromSuperview()
        host = nil
        guard let content else { return }
        let view = FirstClickHostingView(rootView: content)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        host = view
    }

    var fittingSize: NSSize { host?.fittingSize ?? .zero }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        host?.frame = container.bounds
    }
}

private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TrackingView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}

/// The pop-up's background: the bar's colour, solid, rounded.
private struct PopoverBackground: View {
    let look: BarLook

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape.fill(Color(nsColor: look.fill))
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

// MARK: - Peeking at a desktop

/// A small picture of a desktop: its wallpaper with its windows laid out on it, as they are.
/// Click a window to bring it forward, or anywhere else to go to that desktop.
struct DesktopPeekView: View {
    let model: TopBarModel
    let desktop: Desktop
    let screen: NSScreen
    let look: BarLook
    let done: () -> Void
    @StateObject private var shots: PeekShots

    init(model: TopBarModel, desktop: Desktop, screen: NSScreen, look: BarLook, done: @escaping () -> Void) {
        self.model = model
        self.desktop = desktop
        self.screen = screen
        self.look = look
        self.done = done
        // Whatever was taken moments ago shows straight away, rather than after a first frame without it.
        _shots = StateObject(wrappedValue: PeekShots(screen: screen, windows: desktop.windows))
    }

    private static let width: CGFloat = 380

    var body: some View {
        let area = Self.topDown(screen.frame)
        let scale = Self.width / area.width
        let height = (area.height * scale).rounded()
        let name = model.desktopNames[desktop.key] ?? "Desktop \(desktop.number)"
        let apps = desktop.apps.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let colour = model.desktopColours[desktop.key] {
                    Circle().fill(Color(nsColor: colour.color)).frame(width: 8, height: 8)
                }
                Text(name).font(.system(size: 13, weight: .bold, design: .rounded))
                Text(apps.isEmpty ? "Empty" : apps.joined(separator: ", "))
                    .font(.system(size: 12, design: .rounded)).opacity(0.65).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            ZStack(alignment: .topLeading) {
                Wallpaper(screen: screen, captured: shots.wallpaper).frame(width: Self.width, height: height)
                // Back to front, so the front window is drawn last.
                ForEach(desktop.windows.reversed()) { window in
                    let frame = CGRect(x: (window.frame.minX - area.minX) * scale, y: (window.frame.minY - area.minY) * scale,
                                       width: max(6, window.frame.width * scale), height: max(6, window.frame.height * scale))
                    WindowThumbnail(image: shots.images[window.id], icon: model.icon(for: window.app))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .onTapGesture {
                            done()
                            WindowFocus.raise(window.id, of: window.app)
                        }
                }
            }
            .frame(width: Self.width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                done()
                DesktopSwitcher.go(to: desktop)
            }
        }
        .padding(10)
        .background(PopoverBackground(look: look))
        .task {
            await shots.loadWallpaper(of: screen, size: CGSize(width: Self.width, height: height))
            await shots.load(desktop.windows, scale: scale * screen.backingScaleFactor)
        }
    }

    private static func topDown(_ rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct WindowThumbnail: View {
    let image: CGImage?
    let icon: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable()
            } else {
                // Until the picture arrives (or without Screen Recording permission): the app's icon.
                shape.fill(Color.white.opacity(0.22))
                    .overlay {
                        if let icon { Image(nsImage: icon).resizable().scaledToFit().padding(4).frame(maxWidth: 28, maxHeight: 28) }
                    }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// The screen's wallpaper: as it actually looks (which also works with live wallpapers), or
/// else its picture file, or else its colours.
private struct Wallpaper: View {
    let screen: NSScreen
    let captured: CGImage?
    @MainActor private static var cache: [URL: NSImage] = [:]

    var body: some View {
        if let captured {
            Image(decorative: captured, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else if let image = Self.image(for: screen) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(nsColor: WallpaperPalette.shared.top), Color(nsColor: WallpaperPalette.shared.base)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @MainActor private static func image(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let image = cache[url] { return image }
        // A small copy is plenty for the picture, and keeps memory down.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 900,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        cache = [url: image]
        return image
    }
}

/// Pictures of a desktop's windows, taken when the peek opens (Screen Recording permission is
/// needed). They're kept while you move between desktops, and dropped a little after the peek closes.
@MainActor
final class PeekShots: ObservableObject {
    @Published var images: [CGWindowID: CGImage] = [:]
    @Published var wallpaper: CGImage?

    /// The desktop picture as it looks, kept for a minute per screen so moving between desktops
    /// doesn't take it again each time.
    private static var wallpapers: [CGDirectDisplayID: (image: CGImage, taken: Date)] = [:]
    /// Windows' pictures, kept for a few seconds: moving back to a desktop shows them at once.
    private static var kept: [CGWindowID: (image: CGImage, taken: Date)] = [:]
    private static var forgetting: DispatchWorkItem?

    init(screen: NSScreen, windows: [DesktopWindow]) {
        Self.forgetting?.cancel()
        if let id = screen.displayID, let kept = Self.wallpapers[id], Date().timeIntervalSince(kept.taken) < 60 {
            wallpaper = kept.image
        }
        for window in windows {
            if let kept = Self.kept[window.id], Date().timeIntervalSince(kept.taken) < 5 { images[window.id] = kept.image }
        }
    }

    /// Lets go of every picture once no peek has been open for a little while.
    static func forgetSoon() {
        forgetting?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                wallpapers.removeAll()
                kept.removeAll()
                shareable = nil
            }
        }
        forgetting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func loadWallpaper(of screen: NSScreen, size: CGSize) async {
        guard let id = screen.displayID else { return }
        if let kept = Self.wallpapers[id], Date().timeIntervalSince(kept.taken) < 60 {
            if wallpaper !== kept.image { wallpaper = kept.image }
            return
        }
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return }
        // Everything at the ordinary window level and above is left out, leaving the wallpaper.
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowLayer >= 0 })
        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2)
        config.height = Int(size.height * 2)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
        Self.wallpapers[id] = (image, Date())
        wallpaper = image
    }

    /// The system's list of windows to take pictures of, kept for a few seconds: pointing along
    /// the desktops one after another needn't ask for it each time.
    private static var shareable: (content: SCShareableContent, taken: Date)?

    func load(_ windows: [DesktopWindow], scale: CGFloat) async {
        guard CGPreflightScreenCaptureAccess(), !windows.isEmpty else { return }
        let content: SCShareableContent
        if let kept = Self.shareable, Date().timeIntervalSince(kept.taken) < 4 {
            content = kept.content
        } else {
            guard let fresh = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            Self.shareable = (fresh, Date())
            content = fresh
        }
        // All at once, and shown together, rather than one after another with a redraw for each.
        let wanted = windows.prefix(8).filter { images[$0.id] == nil }
        let taken = await withTaskGroup(of: (CGWindowID, CGImage)?.self) { group -> [CGWindowID: CGImage] in
            for window in wanted {
                guard let match = content.windows.first(where: { $0.windowID == window.id }) else { continue }
                let config = SCStreamConfiguration()
                config.width = max(16, Int((window.frame.width * scale).rounded()))
                config.height = max(16, Int((window.frame.height * scale).rounded()))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: match)
                group.addTask {
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
                    return (window.id, image)
                }
            }
            var taken: [CGWindowID: CGImage] = [:]
            for await result in group { if let (id, image) = result { taken[id] = image } }
            return taken
        }
        guard !Task.isCancelled, !taken.isEmpty else { return }
        let now = Date()
        for (id, image) in taken { Self.kept[id] = (image, now) }
        images.merge(taken) { _, new in new }
    }
}

// MARK: - The mini player

/// The album cover, the song, a progress bar you can click to jump, and the player's buttons.
struct MiniPlayerView: View {
    let model: TopBarModel

    var body: some View {
        if let track = model.track {
            let look = model.songLook(model.look)
            HStack(spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.system(size: 13.5, weight: .bold, design: .rounded)).lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12, design: .rounded)).opacity(0.7).lineLimit(1)
                    Progress(track: track, accent: Color(nsColor: look.accent), seek: model.seek)
                    HStack(spacing: 22) {
                        PlayerButton(symbol: "backward.fill", action: model.previousSong)
                        PlayerButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 18, action: model.playPause)
                        PlayerButton(symbol: "forward.fill", action: model.nextSong)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(width: 340)
            .background(PopoverBackground(look: look))
        }
    }

    @ViewBuilder private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.white.opacity(0.12)).overlay(Image(systemName: "music.note").font(.system(size: 26)).opacity(0.6))
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

private struct Progress: View {
    let track: NowPlaying.Track
    let accent: Color
    let seek: (Double) -> Void

    var body: some View {
        // Moves along each second while the song plays.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = track.elapsed ?? 0
            let total = track.duration ?? 0
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(accent).frame(width: total > 0 ? geometry.size.width * min(1, elapsed / total) : 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        if total > 0 { seek(total * min(1, max(0, location.x / geometry.size.width))) }
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Self.time(elapsed))
                    Spacer()
                    Text(total > 0 ? Self.time(total) : "")
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                .opacity(0.6)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

private struct PlayerButton: View {
    let symbol: String
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .bold))
            .frame(width: 30, height: 26)
            .contentShape(Rectangle())
            .opacity(hovering ? 1 : 0.85)
            .scaleEffect(hovering ? 1.12 : 1)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

// MARK: - Choosing two windows to lock in

/// A small panel under the bar for choosing how to lock in: the layout, and which window goes
/// where. It stays until you lock in, press Escape, or click somewhere else.
@MainActor
final class LockInPicker {
    private let panel = PopoverPanel()
    private var monitors: [Any] = []
    private var finish: (([LockIn.Choice]?) -> Void)?

    /// The window it's in, for checking how it looks.
    var windowNumber: Int { panel.windowNumber }

    func show(_ choices: [LockIn.Choice], title: String, look: BarLook, below barBottom: CGFloat, on screen: NSScreen,
              done: @escaping ([LockIn.Choice]?) -> Void) {
        close()
        finish = done
        panel.hasShadow = true
        let view = LockInPickerView(choices: Array(choices.prefix(10)), look: look, title: title, screen: screen) { [weak self] picked in
            // After the click that chose them has finished.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close(with: picked) } }
        }
        panel.setContent(AnyView(view))
        let size = panel.fittingSize
        let mouse = NSEvent.mouseLocation
        let x = min(max((mouse.x - size.width / 2).rounded(), screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: barBottom - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let cancel: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in cancel() },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in if event.keyCode == 53 { cancel() } },
            // Clicks on the bar are left to it: clicking Lock In again closes this.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window !== self.panel, !(event.window is BarPanel) { cancel() }
                return event
            },
        ].compactMap { $0 }
    }

    /// Closes it, with the two windows chosen, or nil if you didn't choose.
    func close(with picked: [LockIn.Choice]? = nil) {
        guard let finish else { return }
        self.finish = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        panel.setContent(nil)
        finish(picked)
        MemoryRelief.soon()
    }
}

/// A short note under the bar, gone again after a few seconds: lock-in saying where a window
/// that opened on a locked-in desktop went. It takes no clicks.
@MainActor
final class BarNote {
    private let panel = PopoverPanel()
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, icon: NSImage?, look: BarLook, below barBottom: CGFloat, on screen: NSScreen) {
        panel.ignoresMouseEvents = true
        panel.setContent(AnyView(BarNoteView(text: text, icon: icon, look: look)))
        let size = panel.fittingSize
        let x = (screen.frame.midX - size.width / 2).rounded()
        panel.setFrame(NSRect(x: x, y: barBottom - 8 - size.height, width: size.width, height: size.height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            BarSpace.add(panel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fade() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func fade() {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.setContent(nil)
            }
        })
    }
}

private struct BarNoteView: View {
    let text: String
    let icon: NSImage?
    let look: BarLook

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
            Text(text).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(Color(nsColor: look.fill.blended(withFraction: 0.62, of: .black) ?? .black))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .padding(2)
    }
}

/// Pictures for the lock-in chooser: each window as it looks, and the calm backdrop the windows
/// will sit on, taken once when it opens (Screen Recording permission is needed; without it the
/// app icons stand in).
@MainActor
final class LockInPictures: ObservableObject {
    @Published var windows: [CGWindowID: CGImage] = [:]
    @Published var backdrop: CGImage?

    func load(_ choices: [LockIn.Choice], display: CGDirectDisplayID?, screen: CGSize) async {
        guard CGPreflightScreenCaptureAccess() else { return }
        async let backdrop = CalmBackdrop.calmPicture(display: display, size: CGSize(width: (screen.width / 4).rounded(), height: (screen.height / 4).rounded()))
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            self.backdrop = await backdrop
            return
        }
        let shots = await withTaskGroup(of: (CGWindowID, CGImage)?.self) { group -> [CGWindowID: CGImage] in
            for choice in choices {
                guard let window = content.windows.first(where: { $0.windowID == choice.id }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1, 520 / max(window.frame.width, 1))
                config.width = max(16, Int(window.frame.width * scale))
                config.height = max(16, Int(window.frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                group.addTask {
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
                    return (choice.id, image)
                }
            }
            var shots: [CGWindowID: CGImage] = [:]
            for await shot in group { if let (id, image) = shot { shots[id] = image } }
            return shots
        }
        // Shown together, rather than one after another.
        self.backdrop = await backdrop
        self.windows = shots
    }
}

/// The lock-in chooser. The screen as it will look, with the windows in their places over the calm
/// backdrop, is the heart of it; above, the layout (one app, two side by side, three with two
/// stacked); below, the desktop's other windows. It starts with a guess at which window goes where.
/// Click a window below to put it in the highlighted place, or drag one place onto another to swap.
private struct LockInPickerView: View {
    let choices: [LockIn.Choice]
    let look: BarLook
    let title: String
    let screenSize: CGSize
    let display: CGDirectDisplayID?
    let done: ([LockIn.Choice]) -> Void
    @StateObject private var pictures = LockInPictures()
    @State private var layout: Int
    @State private var slots: [CGWindowID?]
    @State private var selected: Int
    @State private var tuck = BarSettings.lockInHideOthers
    @State private var dragging: Int?
    @State private var dragOffset: CGSize = .zero

    private static let width: CGFloat = 448
    private static let inset: CGFloat = 16

    init(choices: [LockIn.Choice], look: BarLook, title: String, screen: NSScreen, done: @escaping ([LockIn.Choice]) -> Void) {
        self.choices = choices
        self.look = look
        self.title = title
        self.screenSize = screen.frame.size
        self.display = screen.displayID
        self.done = done
        let layout = min(BarSettings.lockInLayout, max(1, choices.count))
        let guess = Self.guess(layout, from: choices)
        _layout = State(initialValue: layout)
        _slots = State(initialValue: guess)
        _selected = State(initialValue: Self.firstToFill(guess, layout: layout))
    }

    /// The front window of the apps most in front (apps left alone last), each in its place.
    private static func guess(_ count: Int, from choices: [LockIn.Choice]) -> [CGWindowID?] {
        let ordered = LockIn.frontWindowOfEachApp(choices.filter { !$0.leftAlone } + choices.filter(\.leftAlone))
        let picked = LockIn.arranged(Array(ordered.prefix(count)))
        return (0..<count).map { $0 < picked.count ? picked[$0].id : nil }
    }

    /// The place a window chosen below goes: the first empty one, or else the main one.
    private static func firstToFill(_ slots: [CGWindowID?], layout: Int) -> Int {
        slots.firstIndex { $0 == nil } ?? (layout == 3 ? 2 : 0)
    }

    /// The places in a unit square (measured from the top left), shared as lock-in will share the screen.
    static func places(_ count: Int, gap: CGFloat) -> [CGRect] {
        switch count {
        case 1:
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case 2:
            let split = CGFloat(BarSettings.lockInSplit)
            return [CGRect(x: 0, y: 0, width: split - gap / 2, height: 1),
                    CGRect(x: split + gap / 2, y: 0, width: 1 - split - gap / 2, height: 1)]
        default:
            let column = CGFloat(BarSettings.lockInStackColumn), rows = CGFloat(BarSettings.lockInStackRows)
            return [CGRect(x: 0, y: 0, width: column - gap / 2, height: rows - gap),
                    CGRect(x: 0, y: rows + gap, width: column - gap / 2, height: 1 - rows - gap),
                    CGRect(x: column + gap / 2, y: 0, width: 1 - column - gap / 2, height: 1)]
        }
    }

    private var complete: Bool { slots.count == layout && !slots.contains(nil) }
    private var others: [LockIn.Choice] { choices.filter { !slots.contains($0.id) } }

    var body: some View {
        let accent = Color(nsColor: look.accent)
        let screenWidth = Self.width - Self.inset * 2
        let screenHeight = min(230, max(120, (screenWidth * screenSize.height / max(screenSize.width, 1)).rounded()))
        VStack(alignment: .leading, spacing: 14) {
            header(accent: accent)
            screen(width: screenWidth, height: screenHeight, accent: accent)
            tray(accent: accent)
            footer(accent: accent)
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        .foregroundStyle(.white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            shape.fill(Color(nsColor: look.fill.blended(withFraction: 0.62, of: .black) ?? .black))
                .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        }
        .task { await pictures.load(choices, display: display, screen: screenSize) }
    }

    // MARK: Parts

    private func header(accent: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(look.onAccent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(accent))
            VStack(alignment: .leading, spacing: 1) {
                Text("Lock in").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(title).font(.system(size: 11.5, weight: .medium, design: .rounded)).opacity(0.55)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(1...3, id: \.self) { count in
                    let possible = count <= choices.count
                    LayoutChip(places: Self.places(count, gap: 0.08), selected: layout == count, accent: accent)
                        .opacity(possible ? 1 : 0.3)
                        .onTapGesture { if possible { choose(count) } }
                        .help(count == 1 ? "One app" : count == 2 ? "Two side by side" : "Three: two stacked, one beside them")
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    /// The screen as it will look.
    private func screen(width: CGFloat, height: CGFloat, accent: Color) -> some View {
        let pad: CGFloat = 8
        let places = Self.places(layout, gap: 10 / width)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let areaWidth = width - pad * 2, areaHeight = height - pad * 2
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                .overlay {
                    if let backdrop = pictures.backdrop {
                        Image(decorative: backdrop, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: width, height: height)
                .clipped()
            ForEach(Array(places.enumerated()), id: \.offset) { index, place in
                let frame = CGRect(x: pad + place.minX * areaWidth, y: pad + place.minY * areaHeight,
                                   width: place.width * areaWidth, height: place.height * areaHeight)
                // The highlight shows where a window chosen below goes: only when there's one to choose.
                PlaceView(choice: slots[index].flatMap { id in choices.first { $0.id == id } },
                          picture: slots[index].flatMap { pictures.windows[$0] },
                          selected: index == selected && (!others.isEmpty || slots[index] == nil), accent: accent)
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(dragging == index ? 1.03 : 1)
                    .offset(x: frame.minX + (dragging == index ? dragOffset.width : 0),
                            y: frame.minY + (dragging == index ? dragOffset.height : 0))
                    .zIndex(dragging == index ? 1 : 0)
                    .onTapGesture { selected = index }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            dragging = index
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            let point = CGPoint(x: frame.midX + value.translation.width, y: frame.midY + value.translation.height)
                            if let target = places.indices.first(where: { other in
                                let place = places[other]
                                return CGRect(x: pad + place.minX * areaWidth, y: pad + place.minY * areaHeight,
                                              width: place.width * areaWidth, height: place.height * areaHeight).contains(point)
                            }), target != index {
                                slots.swapAt(index, target)
                                selected = target
                            }
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                dragging = nil
                                dragOffset = .zero
                            }
                        })
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: layout)
        .animation(.spring(response: 0.25, dampingFraction: 0.86), value: slots)
    }

    /// The desktop's other windows, to put in the highlighted place.
    @ViewBuilder private func tray(accent: Color) -> some View {
        let rest = others
        if rest.isEmpty, layout > 1 {
            Text("Drag one window onto another to swap them.")
                .font(.system(size: 11, design: .rounded))
                .opacity(0.5)
        }
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("CLICK A WINDOW TO PUT IT IN THE HIGHLIGHTED PLACE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .kerning(0.6)
                    .opacity(0.45)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(rest) { choice in
                            WindowCard(choice: choice, picture: pictures.windows[choice.id])
                                .onTapGesture { put(choice.id) }
                        }
                    }
                }
            }
        }
    }

    private func footer(accent: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: tuck ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(tuck ? accent : Color.white.opacity(0.5))
                Text("Tuck the rest away").font(.system(size: 12, weight: .medium, design: .rounded)).opacity(0.85)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                tuck.toggle()
                BarSettings.lockInHideOthers = tuck
            }
            .help("Minimize the desktop's other windows until you unlock")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                Text("Lock in").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(look.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(accent))
            .opacity(complete ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture { if complete { done(slots.compactMap { id in choices.first { $0.id == id } }) } }
        }
    }

    // MARK: Choosing

    private func choose(_ count: Int) {
        guard count != layout else { return }
        layout = count
        BarSettings.lockInLayout = count
        slots = Self.guess(count, from: choices)
        selected = Self.firstToFill(slots, layout: count)
    }

    /// Puts a window in the highlighted place (its window, if any, goes back below), then
    /// highlights the next empty place.
    private func put(_ id: CGWindowID) {
        guard slots.indices.contains(selected) else { return }
        slots[selected] = id
        if let empty = slots.firstIndex(where: { $0 == nil }) { selected = empty }
    }
}

/// One place on the picture of the screen: the window that will go there, as it looks, with its
/// app's name; or a gap to fill.
private struct PlaceView: View {
    let choice: LockIn.Choice?
    let picture: CGImage?
    let selected: Bool
    let accent: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            if let choice {
                // Exactly the place's size, with the window's picture filling it from the top (where its
                // title bar is) and cut off at the edges.
                Color(white: 0.2)
                    .overlay(alignment: .top) {
                        if let picture {
                            Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else if let icon = choice.icon {
                            Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipped()
                HStack(spacing: 5) {
                    if let icon = choice.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    Text(choice.app).font(.system(size: 10.5, weight: .semibold, design: .rounded)).lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(6)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text("Choose a window").font(.system(size: 10.5, weight: .medium, design: .rounded))
                }
                .opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(Color.black.opacity(0.25)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? accent : Color.white.opacity(0.14), lineWidth: selected ? 2 : 1))
        .shadow(color: selected ? accent.opacity(0.55) : .black.opacity(0.35), radius: selected ? 8 : 4)
        .contentShape(shape)
    }
}

/// A window waiting below the picture of the screen.
private struct WindowCard: View {
    let choice: LockIn.Choice
    let picture: CGImage?
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            Color(white: 0.2)
                .overlay(alignment: .top) {
                    if let picture {
                        Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else if let icon = choice.icon {
                        Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 96, height: 60)
                .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.5 : 0.12), lineWidth: 1))
            HStack(spacing: 4) {
                if let icon = choice.icon { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
                Text(choice.title ?? choice.app).font(.system(size: 10.5, weight: .medium, design: .rounded)).lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
            .opacity(0.85)
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A small outline picture of a layout, for choosing it.
private struct LayoutChip: View {
    let places: [CGRect]
    let selected: Bool
    let accent: Color

    var body: some View {
        let width: CGFloat = 26, height: CGFloat = 17
        ZStack(alignment: .topLeading) {
            ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.95) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0 : 0.6), lineWidth: 1.2))
                    .frame(width: place.width * width, height: place.height * height)
                    .offset(x: place.minX * width, y: place.minY * height)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? accent : Color.clear))
        .contentShape(Rectangle())
    }
}
