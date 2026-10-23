import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

/// Notes about preview clicks, readable with: log show --predicate 'subsystem == "local.cleardock"'
let previewLog = Logger(subsystem: "local.cleardock", category: "previews")

/// A small picture of one window.
struct WindowShot {
    let windowID: CGWindowID
    let image: CGImage
    /// Size to show it at, in points.
    let size: CGSize
}

/// Takes thumbnails of an app's windows. macOS only allows this with Screen Recording permission.
/// Nothing is captured until you hover over an icon, and the pictures are dropped when the preview closes.
enum WindowCapture {
    static let maxHeight: CGFloat = 120
    static let maxWidth: CGFloat = 210

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt; macOS only shows it the first time.
    static func askForPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Thumbnails of the app's normal windows, front-most first.
    static func shots(of pid: pid_t, scale: CGFloat) async -> [WindowShot] {
        guard hasPermission,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [] }

        // Only real windows: on screen now, listed by the app itself (which keeps minimized
        // ones), or placed on one of your desktops. Hidden background "ghost" windows are skipped.
        let listedByApp = AppWindowList.windowIDs(of: pid)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
                && $0.frame.width >= 120 && $0.frame.height >= 80
                && ($0.isOnScreen || listedByApp.contains($0.windowID) || WindowSpaces.isPlaced($0.windowID))
        }
        // Order them as they're stacked on screen; windows elsewhere (other Spaces) go last.
        let stacked = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(stacked.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = windows.sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }.prefix(6)

        var results: [(Int, WindowShot)] = []
        await withTaskGroup(of: (Int, WindowShot)?.self) { group in
            for (i, window) in ordered.enumerated() {
                group.addTask { await capture(window, scale: scale).map { (i, $0) } }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func capture(_ window: SCWindow, scale: CGFloat) async -> WindowShot? {
        let aspect = window.frame.width / window.frame.height
        var height = min(maxHeight, window.frame.height)
        var width = height * aspect
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        let config = SCStreamConfiguration()
        config.width = Int((width * scale).rounded())
        config.height = Int((height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return WindowShot(windowID: window.windowID, image: image, size: CGSize(width: width.rounded(), height: height.rounded()))
    }
}

/// Brings one particular window to the front. Picking the exact window needs Accessibility
/// permission; without it the whole app comes forward instead.
@MainActor
enum WindowFocus {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Matches an accessibility window to its window number (a long-standing private call).
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static func raise(_ windowID: CGWindowID, of pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // The click landed on Clear Dock, so it may become active for a moment and hand focus on.
        NSApp.activate()
        NSApp.yieldActivation(to: app)

        // Put the chosen window on top of the app's others first, so it's the one that comes forward.
        let window = element(for: windowID, of: pid)
        var activated = false
        if let window {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            activated = app.activate()
        } else if AXIsProcessTrusted(), bringForward(windowID, of: pid) {
            // Most apps only list the windows on the desktop you're on, so one on another desktop
            // can't be found that way: the window server is asked to bring it forward, going to its
            // desktop. macOS doesn't always allow that, so the app is brought forward as well, which
            // is harmless if the window already came.
            activated = app.activate()
        } else {
            if !AXIsProcessTrusted() { showAccessibilitySettingsOnce() }
            activated = app.activate()
        }
        previewLog.notice("Preview click: window \(windowID) of \(app.localizedName ?? "?", privacy: .public); found window: \(window != nil); accessibility: \(AXIsProcessTrusted()); activated: \(activated)")

        // If macOS didn't let the app come forward, open it the way a Dock click does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Whether it was the window you clicked that came forward, for checking with `log show`.
            let front = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? CGWindowID
            previewLog.notice("Preview click: the clicked window is in front: \(front == windowID)")
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, let url = app.bundleURL else { return }
            previewLog.notice("Preview click: app wasn't in front yet, opening it instead")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }

    private typealias GetProcess = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private static let anywhere = UnsafeMutableRawPointer(bitPattern: -2)
    private static let getProcess: GetProcess? = dlsym(anywhere, "GetProcessForPID").map { unsafeBitCast($0, to: GetProcess.self) }
    private static let setFrontProcess: SetFrontProcess? = dlsym(anywhere, "_SLPSSetFrontProcessWithOptions")
        .map { unsafeBitCast($0, to: SetFrontProcess.self) }
    private static let postEventRecord: PostEventRecord? = dlsym(anywhere, "SLPSPostEventRecordTo")
        .map { unsafeBitCast($0, to: PostEventRecord.self) }

    /// Brings one window forward through the window server, as window managers (like yabai) do,
    /// even when it's on another desktop: its app comes to the front with that window, and macOS
    /// goes to the window's desktop. Returns false if that isn't available.
    private static func bringForward(_ windowID: CGWindowID, of pid: pid_t) -> Bool {
        guard let getProcess, let setFrontProcess, let postEventRecord else { return false }
        var process = ProcessSerialNumber()
        guard getProcess(pid, &process) == noErr,
              setFrontProcess(&process, windowID, 0x200) == 0 else { return false }  // 0x200: as if you did it
        // Then make it the app's key window: the same two records a click on the window would send.
        for kind: UInt8 in [1, 2] {
            var record = [UInt8](repeating: 0, count: 0xF8)
            record[0x04] = 0xF8
            record[0x08] = kind
            record[0x3A] = 0x10
            for i in 0x20..<0x30 { record[i] = 0xFF }
            withUnsafeBytes(of: windowID.littleEndian) { bytes in
                for (i, byte) in bytes.enumerated() { record[0x3C + i] = byte }
            }
            _ = record.withUnsafeMutableBufferPointer { postEventRecord(&process, $0.baseAddress!) }
        }
        return true
    }

    /// Choosing one particular window needs Accessibility permission. If it's missing,
    /// open that settings page once so it's easy to switch on.
    private static func showAccessibilitySettingsOnce() {
        let key = "shownAccessibilitySettingsForPreviews"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Presses the window's own close button, so the app can still ask about unsaved changes.
    @discardableResult
    static func close(_ windowID: CGWindowID, of pid: pid_t) -> Bool {
        guard let window = element(for: windowID, of: pid) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    private static func element(for windowID: CGWindowID, of pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), let getWindow else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var id: CGWindowID = 0
            return getWindow(window, &id) == .success && id == windowID
        }
    }

    static var canClose: Bool { AXIsProcessTrusted() }
}

/// The floating row of thumbnails. No background, just the pictures, like the rest of the dock.
@MainActor
final class PreviewPanel: OverlayPanel {
    private let previewView = PreviewView()

    var onPick: ((CGWindowID) -> Void)? {
        get { previewView.onPick }
        set { previewView.onPick = newValue }
    }
    var onClose: ((CGWindowID) -> Void)? {
        get { previewView.onClose }
        set { previewView.onClose = newValue }
    }
    var onEnter: (() -> Void)? {
        get { previewView.onEnter }
        set { previewView.onEnter = newValue }
    }
    var onExit: (() -> Void)? {
        get { previewView.onExit }
        set { previewView.onExit = newValue }
    }

    override init() {
        super.init()
        ignoresMouseEvents = false
        contentView = previewView
    }

    /// Places the thumbnails just beyond `anchor` (the icon, in screen coordinates), away from the
    /// dock's screen edge, and keeps them on screen.
    func show(_ shots: [WindowShot], beside anchor: NSRect, edge: DockEdge, on screen: NSScreen, scale: CGFloat, fadeIn: Bool) {
        let size = previewView.set(shots, scale: scale)
        let s = screen.frame
        var origin: CGPoint = switch edge {
        case .bottom: CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
        case .left: CGPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
        case .right: CGPoint(x: anchor.minX - 10 - size.width, y: anchor.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, s.minX + 8), s.maxX - size.width - 8).rounded()
        origin.y = min(max(origin.y, s.minY + 8), s.maxY - size.height - 8).rounded()
        setFrame(NSRect(origin: origin, size: size), display: true)
        if fadeIn {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }
    }

    func dismiss() {
        orderOut(nil)
        previewView.clear()
    }
}

@MainActor
private final class PreviewView: NSView {
    private static let gap: CGFloat = 10
    private static let padding: CGFloat = 8

    var onPick: ((CGWindowID) -> Void)?
    var onClose: ((CGWindowID) -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private static let closeSize: CGFloat = 18
    /// A small round × shown in the corner of the thumbnail under the pointer.
    private let closeButton: CALayer = {
        let button = CALayer()
        button.bounds = CGRect(x: 0, y: 0, width: closeSize, height: closeSize)
        button.cornerRadius = closeSize / 2
        button.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
        button.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        button.borderWidth = 0.5
        let cross = CAShapeLayer()
        cross.frame = button.bounds
        let path = CGMutablePath()
        let inset: CGFloat = 6
        path.move(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: closeSize - inset, y: closeSize - inset))
        path.move(to: CGPoint(x: closeSize - inset, y: inset))
        path.addLine(to: CGPoint(x: inset, y: closeSize - inset))
        cross.path = path
        cross.strokeColor = NSColor.white.cgColor
        cross.lineWidth = 1.5
        cross.lineCap = .round
        button.addSublayer(cross)
        button.zPosition = 2
        button.isHidden = true
        return button
    }()

    private var shots: [WindowShot] = []
    private var frames: [CGRect] = []
    private var layers: [CALayer] = []
    private var hovered: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lays out the thumbnails and returns the size they need.
    func set(_ shots: [WindowShot], scale: CGFloat) -> CGSize {
        clear()
        self.shots = shots
        if closeButton.superlayer == nil { layer?.addSublayer(closeButton) }
        let height = (shots.map(\.size.height).max() ?? 0) + Self.padding * 2
        var x = Self.padding
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shot in shots {
            let frame = CGRect(x: x, y: height - Self.padding - shot.size.height, width: shot.size.width, height: shot.size.height)
            frames.append(frame)
            // The outer layer carries the shadow; the inner one clips the picture's corners.
            let holder = CALayer()
            holder.frame = frame
            holder.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: 8, cornerHeight: 8, transform: nil)
            holder.shadowColor = NSColor.black.cgColor
            holder.shadowOpacity = 0.35
            holder.shadowRadius = 6
            holder.shadowOffset = CGSize(width: 0, height: 2)
            let picture = CALayer()
            picture.frame = CGRect(origin: .zero, size: frame.size)
            picture.contents = shot.image
            picture.contentsGravity = .resizeAspect
            picture.contentsScale = scale
            picture.cornerRadius = 8
            picture.masksToBounds = true
            picture.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
            picture.borderWidth = 0.5
            holder.addSublayer(picture)
            layer?.addSublayer(holder)
            layers.append(holder)
            x += shot.size.width + Self.gap
        }
        CATransaction.commit()
        return CGSize(width: x - Self.gap + Self.padding, height: height)
    }

    func clear() {
        closeButton.isHidden = true
        layers.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
        frames.removeAll()
        shots.removeAll()
        hovered = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        onExit?()
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(index(at: convert(event.locationInWindow, from: nil)))
    }

    // Taking the press here makes sure the release comes back to this view too.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        previewLog.notice("Preview released at \(Int(point.x)), \(Int(point.y)); thumbnail: \(self.index(at: point) ?? -1)")
        guard let i = index(at: point) else { return }
        if !closeButton.isHidden, hovered == i, closeRect(for: i).insetBy(dx: -4, dy: -4).contains(point) {
            onClose?(shots[i].windowID)
        } else {
            onPick?(shots[i].windowID)
        }
    }

    private func closeRect(for index: Int) -> CGRect {
        let frame = frames[index]
        return CGRect(x: frame.minX + 6, y: frame.minY + 6, width: Self.closeSize, height: Self.closeSize)
    }

    private func index(at point: CGPoint) -> Int? {
        frames.firstIndex { $0.insetBy(dx: -Self.gap / 2, dy: -Self.padding).contains(point) }
    }

    /// The thumbnail under the pointer grows slightly.
    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        for (i, layer) in layers.enumerated() {
            layer.setAffineTransform(i == index ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity)
        }
        CATransaction.commit()
        // Closing a window needs Accessibility permission, so only offer it when that's allowed.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let index, WindowFocus.canClose {
            let rect = closeRect(for: index)
            closeButton.position = CGPoint(x: rect.midX, y: rect.midY)
            closeButton.isHidden = false
        } else {
            closeButton.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Decides when previews open, switch and close as the pointer moves along the dock.
@MainActor
final class WindowPreviewController {
    private let panel = PreviewPanel()
    private var openTimer: DispatchWorkItem?
    private var closeTimer: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    private var shownAppID: String?
    private var pointerInPanel = false

    /// Called when the pointer leaves the preview, so the dock can decide whether to hide too.
    var onExit: (() -> Void)?

    init() {
        panel.onPick = { [weak self] windowID in self?.pick(windowID) }
        panel.onClose = { [weak self] windowID in self?.closeWindow(windowID) }
        panel.onEnter = { [weak self] in
            self?.pointerInPanel = true
            self?.cancelClose()
        }
        panel.onExit = { [weak self] in
            self?.pointerInPanel = false
            self?.scheduleClose()
            self?.onExit?()
        }
    }

    private var pid: pid_t?

    /// Whether the pointer is on (or right next to) an open preview.
    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -12, dy: -12).contains(point)
    }

    /// The pointer moved onto an app's icon (or off them, with `nil`).
    func hover(over item: DockItem?, pid: pid_t?, anchor: NSRect, screen: NSScreen, scale: CGFloat, edge: DockEdge) {
        openTimer?.cancel()
        guard Settings.showPreviews, WindowCapture.hasPermission,
              let item, item.kind == .app, item.isRunning, let pid else {
            scheduleClose()
            return
        }
        cancelClose()
        if shownAppID == item.id && panel.isVisible { return }
        // Wait a moment before the first preview; once one is open, switching is quick.
        let delay = panel.isVisible ? 0.06 : 0.4
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.open(item.id, pid: pid, anchor: anchor, screen: screen, scale: scale, edge: edge) }
        }
        openTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func close() {
        openTimer?.cancel()
        cancelClose()
        captureTask?.cancel()
        shownAppID = nil
        pid = nil
        pointerInPanel = false
        if panel.isVisible { MemoryRelief.soon() }
        panel.dismiss()
    }

    private func open(_ appID: String, pid: pid_t, anchor: NSRect, screen: NSScreen, scale: CGFloat, edge: DockEdge) {
        captureTask?.cancel()
        let wasVisible = panel.isVisible
        captureTask = Task { @MainActor [weak self] in
            let shots = await WindowCapture.shots(of: pid, scale: scale)
            guard let self, !Task.isCancelled else { return }
            guard !shots.isEmpty else {
                self.close()
                return
            }
            self.shownAppID = appID
            self.pid = pid
            self.lastPlacement = (appID, anchor, screen, scale, edge)
            self.panel.show(shots, beside: anchor, edge: edge, on: screen, scale: scale, fadeIn: !wasVisible)
        }
    }

    /// Where the open preview is anchored, so it can be refreshed after a window closes.
    private var lastPlacement: (appID: String, anchor: NSRect, screen: NSScreen, scale: CGFloat, edge: DockEdge)?

    private func closeWindow(_ windowID: CGWindowID) {
        guard let pid, WindowFocus.close(windowID, of: pid), let placement = lastPlacement else { return }
        // Give the app a moment to close it (or to ask about unsaved changes), then refresh.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownAppID == placement.appID else { return }
                self.open(placement.appID, pid: pid, anchor: placement.anchor, screen: placement.screen,
                          scale: placement.scale, edge: placement.edge)
            }
        }
    }

    private func pick(_ windowID: CGWindowID) {
        guard let pid else { return }
        close()
        WindowFocus.raise(windowID, of: pid)
    }

    private func scheduleClose() {
        guard closeTimer == nil, !pointerInPanel else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeTimer = nil
                if !self.pointerInPanel { self.close() }
            }
        }
        closeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelClose() {
        closeTimer?.cancel()
        closeTimer = nil
    }
}
