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

/// A small panel under the bar for choosing the windows to lock in: two (the first you click goes
/// on the left, the second on the right) or three (top left, bottom left, then the big one on the
/// right). It stays until you've chosen, press Escape, or click somewhere else.
@MainActor
final class LockInPicker {
    private let panel = PopoverPanel()
    private var monitors: [Any] = []
    private var finish: (([LockIn.Choice]?) -> Void)?

    func show(_ choices: [LockIn.Choice], look: BarLook, below barBottom: CGFloat, on screen: NSScreen,
              done: @escaping ([LockIn.Choice]?) -> Void) {
        close()
        finish = done
        let view = LockInPickerView(choices: Array(choices.prefix(10)), look: look, tucksOthers: BarSettings.lockInHideOthers,
                                    three: BarSettings.lockInThree && choices.count >= 3) { [weak self] picked in
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

private struct LockInPickerView: View {
    let choices: [LockIn.Choice]
    let look: BarLook
    let tucksOthers: Bool
    @State var three: Bool
    let done: ([LockIn.Choice]) -> Void
    /// The ones chosen so far, in order.
    @State private var picked: [CGWindowID] = []

    private var wanted: Int { three ? 3 : 2 }
    /// Where each one chosen goes, in the order they're chosen.
    private var places: [String] { three ? ["Top", "Bottom", "Right"] : ["Left", "Right"] }

    private var instruction: String {
        switch (three, picked.count) {
        case (false, 0): "Choose the one for the left."
        case (false, _): "Now the one for the right."
        case (true, 0): "Choose the one for the top left."
        case (true, 1): "Now the one under it."
        case (true, _): "Now the big one on the right."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(three ? "Lock in three windows" : "Lock in two windows").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(instruction).font(.system(size: 12, design: .rounded)).opacity(0.7)
                }
                Spacer(minLength: 8)
                if choices.count >= 3 {
                    // Two side by side, or two stacked with a big one beside them; remembered for next time.
                    Picker("", selection: $three) {
                        Text("2").tag(false)
                        Text("3").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: three) { _, now in
                        BarSettings.lockInThree = now
                        picked.removeAll()
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(choices) { choice in
                    let place = picked.firstIndex(of: choice.id).map { places[$0] }
                    PickerRow(choice: choice, place: place, look: look) {
                        if let index = picked.firstIndex(of: choice.id) {
                            // Clicking one chosen again takes it (and any chosen after it) back.
                            picked.removeSubrange(index...)
                            return
                        }
                        picked.append(choice.id)
                        guard picked.count == wanted else { return }
                        done(picked.compactMap { id in choices.first { $0.id == id } })
                    }
                }
            }
            if tucksOthers {
                Text("The rest are tucked away until you unlock.")
                    .font(.system(size: 11, design: .rounded)).opacity(0.55)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 300)
        // See-through glass, like the bar's, with a hint of the bar's colour so the words stay clear.
        .glassEffect(.regular.tint(Color(nsColor: look.fill).opacity(0.3)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PickerRow: View {
    let choice: LockIn.Choice
    /// Where it goes, once chosen ("Left", "Top"…).
    let place: String?
    let look: BarLook
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = choice.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(choice.app).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                if let title = choice.title, !title.isEmpty {
                    Text(title).font(.system(size: 11, design: .rounded)).opacity(0.65).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let place {
                Text(place)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(look.onAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: look.accent)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(place != nil ? 0.16 : hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
