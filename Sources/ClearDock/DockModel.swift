import AppKit

enum DockItemKind: Equatable {
    case app
    case separator
    case trash
}

struct DockItem {
    let id: String
    let kind: DockItemKind
    var name = ""
    var url: URL?
    var isRunning = false
    var isHidden = false
    /// The app's notification count, as shown on its icon in the macOS Dock.
    var badge: String?
    /// Asked to quit from the dock and still shutting down.
    var isQuitting = false
}

/// Which edge of the screen the dock sits on.
enum DockEdge: String, CaseIterable, Identifiable {
    case left, bottom, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "Left"
        case .bottom: "Bottom"
        case .right: "Right"
        }
    }
    var isVertical: Bool { self != .bottom }
}

/// Where each item sits inside the dock window (origin top-left). "Along" means along the row of
/// icons; "across" means from the screen edge out. The window is only as big as the row of icons
/// (plus room for magnification), so it never blocks clicks elsewhere.
struct DockLayout {
    static let dotHeight: CGFloat = 8

    var edge = DockEdge.bottom
    var iconSize: CGFloat
    /// A background bar needs a little room around the icons.
    var hasBackground = false
    /// Whether open apps get a mark beside them, which needs a strip of its own.
    var showsMarks = true
    /// Space between icons, as a multiple of the normal gap.
    var spacing: CGFloat = 1
    /// Room on the far side of the icons (away from the screen edge) for hover effects to move into.
    var hoverRoom: CGFloat = 0
    /// Room at each end of the row for magnified icons to spread into.
    var endRoom: CGFloat = 0
    var frames: [CGRect] = []
    var size: CGSize = .zero

    /// Room on the far side of the icons, where notification badges overhang.
    var farInset: CGFloat { (hasBackground ? 10 : 5) + hoverRoom }
    /// Room on the screen-edge side, below the running-app marks. Without marks, as much as on the
    /// far side, so the icons sit in the middle of a background (and where they always have without one).
    var edgeInset: CGFloat {
        if showsMarks { return hasBackground ? 7 : 4 }
        return hasBackground ? 10 : 4 + Self.dotHeight
    }
    /// The strip beside the icons for the running-app marks; none when they're off.
    var markRoom: CGFloat { showsMarks ? Self.dotHeight : 0 }
    var endPadding: CGFloat { hasBackground ? 14 : 6 }
    var gap: CGFloat { max(2, (iconSize * 0.12 * spacing).rounded()) }
    var separatorWidth: CGFloat { max(9, (iconSize * 0.25).rounded()) }
    /// The dock's depth, from the screen edge outwards.
    var thickness: CGFloat { farInset + iconSize + markRoom + edgeInset }

    /// Position along the row.
    func along(_ point: CGPoint) -> CGFloat { edge.isVertical ? point.y : point.x }
    func along(_ rect: CGRect) -> ClosedRange<CGFloat> { edge.isVertical ? rect.minY...rect.maxY : rect.minX...rect.maxX }

    /// An item's frame, given where it starts along the row and how long it is.
    func frame(at position: CGFloat, length: CGFloat) -> CGRect {
        switch edge {
        case .bottom: CGRect(x: position, y: farInset, width: length, height: iconSize)
        case .left: CGRect(x: edgeInset + markRoom, y: position, width: iconSize, height: length)
        case .right: CGRect(x: farInset, y: position, width: iconSize, height: length)
        }
    }

    /// Centre of the running-app mark for an item, on the screen-edge side of it.
    func markerCenter(for frame: CGRect) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY + Self.dotHeight / 2)
        case .left: CGPoint(x: frame.minX - Self.dotHeight / 2, y: frame.midY)
        case .right: CGPoint(x: frame.maxX + Self.dotHeight / 2, y: frame.midY)
        }
    }

    /// The direction away from the screen edge, in the window's top-down coordinates.
    var outward: CGVector {
        switch edge {
        case .bottom: CGVector(dx: 0, dy: -1)
        case .left: CGVector(dx: 1, dy: 0)
        case .right: CGVector(dx: -1, dy: 0)
        }
    }

    /// The background bar: around the icons from end to end, and from just past the icons to near the screen edge.
    func barRect(from start: CGFloat? = nil, to end: CGFloat? = nil) -> CGRect {
        guard let first = frames.first, let last = frames.last else { return .zero }
        let pad = endPadding - 2
        let low = (start ?? (edge.isVertical ? first.minY : first.minX)) - pad
        let high = (end ?? (edge.isVertical ? last.maxY : last.maxX)) + pad
        let depth = thickness - hoverRoom - 6
        switch edge {
        case .bottom: return CGRect(x: low, y: hoverRoom + 3, width: high - low, height: depth)
        case .left: return CGRect(x: 3, y: low, width: depth, height: high - low)
        case .right: return CGRect(x: hoverRoom + 3, y: low, width: depth, height: high - low)
        }
    }
}

@MainActor
final class DockModel {
    private(set) var items: [DockItem] = []
    private(set) var layout = DockLayout(iconSize: 48)
    private(set) var isTrashFull = false

    /// Called after the items or their layout change.
    var onChange: (() -> Void)?

    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    static let trashURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")

    /// Open apps in the order they were launched, so new apps join at the end like the macOS Dock.
    private var launchOrder: [String] = []
    /// Notification counts by app bundle path.
    private var badges: [String: String] = [:]
    /// Apps asked to quit from the dock that haven't finished yet.
    private var quitting = Set<String>()

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func reload() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            // Apps macOS has no launch time for go last, as in the macOS Dock.
            .sorted { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
        var runningByKey: [String: NSRunningApplication] = [:]
        for app in running {
            let key = Self.key(for: app)
            if runningByKey[key] == nil { runningByKey[key] = app }
            if !launchOrder.contains(key) { launchOrder.append(key) }
        }
        launchOrder.removeAll { runningByKey[$0] == nil }
        quitting = quitting.filter { runningByKey[$0] != nil }

        var result: [DockItem] = []
        var used = Set<String>()
        func addApp(key: String, url: URL?) {
            guard !used.contains(key) else { return }
            used.insert(key)
            result.append(appItem(key: key, url: url, running: runningByKey[key]))
        }

        addApp(key: "com.apple.finder", url: Self.finderURL)
        if Settings.showPinned {
            for url in SystemDock.pinnedApps() {
                addApp(key: Bundle(url: url)?.bundleIdentifier ?? url.path, url: url)
            }
        }
        let others = Self.applyingSavedOrder(to: launchOrder.filter { !used.contains($0) })
        if Settings.showPinned && !others.isEmpty && result.count > 1 {
            result.append(DockItem(id: "separator-apps", kind: .separator))
        }
        for key in others {
            addApp(key: key, url: runningByKey[key]?.bundleURL)
        }
        // The divider stays even with the Trash hidden, so its right-click settings are always reachable.
        result.append(DockItem(id: "separator-trash", kind: .separator))
        if Settings.showTrash {
            isTrashFull = SystemDock.bool("trash-full") ?? false
            result.append(DockItem(id: "trash", kind: .trash, name: "Trash", url: Self.trashURL))
        }

        items = result
        relayout()
        onChange?()
    }

    func refreshTrash() {
        guard Settings.showTrash else { return }
        let full = SystemDock.bool("trash-full") ?? false
        guard full != isTrashFull else { return }
        isTrashFull = full
        onChange?()
    }

    /// Takes new notification counts (by app bundle path) and redraws only if one changed.
    func setBadges(_ new: [String: String]) {
        guard new != badges else { return }
        badges = new
        var changed = false
        for i in items.indices where items[i].kind == .app {
            let badge = items[i].url.flatMap { new[$0.standardizedFileURL.path] }
            if items[i].badge != badge {
                items[i].badge = badge
                changed = true
            }
        }
        if changed { onChange?() }
    }

    private func relayout() {
        let iconSize = CGFloat(Settings.iconSize)
        let effect = Appearance.hoverEffect
        let grow = CGFloat(Appearance.magnifyScale) - 1
        let hoverRoom: CGFloat = switch effect {
        case .none: 0
        case .grow, .lift: (iconSize * 0.18).rounded()
        case .magnify: (iconSize * grow).rounded()
        }
        var layout = DockLayout(
            edge: Settings.position, iconSize: iconSize, hasBackground: Appearance.hasBackground,
            showsMarks: Appearance.markerStyle != .none,
            spacing: CGFloat(Appearance.spacing), hoverRoom: hoverRoom,
            endRoom: effect == .magnify ? (iconSize * grow * 1.8).rounded() : 0)
        var position = layout.endPadding + layout.endRoom
        for item in items {
            let length = item.kind == .separator ? layout.separatorWidth : layout.iconSize
            layout.frames.append(layout.frame(at: position, length: length))
            position += length + layout.gap
        }
        if !items.isEmpty { position -= layout.gap }
        let rowLength = position + layout.endPadding + layout.endRoom
        layout.size = layout.edge.isVertical
            ? CGSize(width: layout.thickness, height: rowLength)
            : CGSize(width: rowLength, height: layout.thickness)
        self.layout = layout
    }

    // MARK: Reordering

    /// Apps you've dragged into place keep that order; anything new joins at the end.
    private static func applyingSavedOrder(to keys: [String]) -> [String] {
        let saved = Settings.appOrder
        guard !saved.isEmpty else { return keys }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let known = keys.filter { rank[$0] != nil }.sorted { rank[$0]! < rank[$1]! }
        return known + keys.filter { rank[$0] == nil }
    }

    /// Whether an item can be dragged to a new place. Finder always stays first, as in the macOS Dock.
    func canMove(_ index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        return items[index].kind == .app && items[index].id != "com.apple.finder" && isInRunningGroup(index)
    }

    /// Moves an app to the slot nearest `position` (along the row) among the apps it can trade places with.
    /// Returns true if anything moved. Pass `save: false` while the drag is still going.
    @discardableResult
    func move(_ id: String, toward position: CGFloat, save: Bool) -> Bool {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return false }
        let group = items.indices.filter { canMove($0) || $0 == from }
        guard let first = group.first, let last = group.last else { return false }
        // Find the slot whose centre is closest to the pointer.
        var to = from
        var best = CGFloat.infinity
        for i in first...last where group.contains(i) {
            let span = layout.along(layout.frames[i])
            let distance = abs((span.lowerBound + span.upperBound) / 2 - position)
            if distance < best { best = distance; to = i }
        }
        if to != from {
            let item = items.remove(at: from)
            items.insert(item, at: to)
            relayout()
        }
        if save {
            Settings.appOrder = items.filter { $0.kind == .app }.map(\.id)
        }
        return to != from
    }

    private func isInRunningGroup(_ index: Int) -> Bool {
        // With pinned apps shown, only the open apps after the first divider can be reordered.
        guard Settings.showPinned, let divider = items.firstIndex(where: { $0.id == "separator-apps" }) else { return true }
        return index > divider
    }

    /// The process of an open app's icon, for showing its windows.
    func processID(at index: Int) -> pid_t? {
        guard items.indices.contains(index), items[index].kind == .app else { return nil }
        return runningApp(for: items[index])?.processIdentifier
    }

    // MARK: Icons

    /// A stable name for an item's picture, used to cache the small bitmap drawn from it.
    func iconKey(for item: DockItem) -> String {
        if item.kind == .trash { return isTrashFull ? "trash-full" : "trash-empty" }
        if let custom = Settings.customIcons[item.id] { return "custom:" + custom }
        return item.url?.path ?? item.id
    }

    func sourceIcon(for item: DockItem) -> NSImage? {
        switch item.kind {
        case .trash:
            return NSImage(named: isTrashFull ? NSImage.trashFullName : NSImage.trashEmptyName)
        case .app:
            // A picture you've chosen; an app or icon file uses its own icon.
            // Follow shortcuts (like /Applications/Safari.app) so the icon has no alias arrow.
            if let saved = Settings.customIcons[item.id],
               case let path = URL(fileURLWithPath: saved).resolvingSymlinksInPath().path,
               FileManager.default.fileExists(atPath: path) {
                if path.hasSuffix(".app") || path.hasSuffix(".icns") { return NSWorkspace.shared.icon(forFile: path) }
                if let picture = NSImage(contentsOfFile: path) { return picture }
            }
            if let url = item.url { return NSWorkspace.shared.icon(forFile: url.path) }
            return runningApp(for: item)?.icon
        case .separator:
            return nil
        }
    }

    // MARK: Hit testing (panel coordinates, origin top-left)

    func index(at point: CGPoint, includingSeparators: Bool = false) -> Int? {
        guard point.x >= 0, point.y >= 0, point.x <= layout.size.width, point.y <= layout.size.height else { return nil }
        let position = layout.along(point)
        let half = layout.gap / 2
        for (i, frame) in layout.frames.enumerated() where i < items.count {
            if items[i].kind == .separator && !includingSeparators { continue }
            let span = layout.along(frame)
            if position >= span.lowerBound - half && position < span.upperBound + half { return i }
        }
        return nil
    }

    // MARK: Actions

    func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        // Optionally, clicking the app you're already in hides it. An app with no windows open
        // (like Finder after clicking the desktop) is left alone, so the click opens a new window.
        if Settings.clickToHide, item.kind == .app, let running = runningApp(for: item), !running.isHidden,
           running.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
           Self.hasWindows(running.processIdentifier) {
            running.hide()
            return
        }
        // macOS only lets the active app bring another app forward. The click just landed
        // on Clear Dock, so it may become active for a moment and hand focus on.
        NSApp.activate()
        switch item.kind {
        case .app:
            guard let url = item.url else { return }
            if let running = runningApp(for: item) { NSApp.yieldActivation(to: running) }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        case .trash:
            NSWorkspace.shared.open(Self.trashURL)
        case .separator:
            break
        }
    }

    /// Shows all of an app's windows (App Exposé), as scrolling up on an icon does in the macOS Dock.
    func showWindows(_ index: Int) {
        guard items.indices.contains(index), items[index].kind == .app, let app = runningApp(for: items[index]) else { return }
        NSApp.activate()
        NSApp.yieldActivation(to: app)
        app.activate(from: .current)
        // App Exposé opens for whichever app is in front, so give it a moment to come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CoreDock.send("com.apple.expose.front.awake")
        }
    }

    func open(_ files: [URL], with index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        switch item.kind {
        case .app:
            guard let url = item.url else { return }
            NSWorkspace.shared.open(files, withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case .trash:
            NSWorkspace.shared.recycle(files, completionHandler: nil)
        case .separator:
            break
        }
    }

    func menu(for index: Int) -> NSMenu? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        let menu = NSMenu()
        menu.autoenablesItems = false

        if item.kind == .trash {
            menu.addItem(ActionMenuItem("Open") { [weak self] in self?.activate(index) })
            let empty = ActionMenuItem("Empty Trash") { Self.confirmAndEmptyTrash() }
            empty.isEnabled = isTrashFull
            menu.addItem(empty)
            return menu
        }
        guard item.kind == .app else { return nil }

        let app = runningApp(for: item)
        if let app {
            menu.addItem(ActionMenuItem("Show All Windows") { [weak self] in self?.showWindows(index) })
            menu.addItem(ActionMenuItem(app.isHidden ? "Show" : "Hide") {
                if app.isHidden { app.unhide() } else { app.hide() }
            })
        } else {
            menu.addItem(ActionMenuItem("Open") { [weak self] in self?.activate(index) })
        }
        if let url = item.url {
            menu.addItem(ActionMenuItem("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        menu.addItem(ActionMenuItem("Change Icon…") { [weak self] in self?.chooseIcon(for: item.id, name: item.name) })
        if Settings.customIcons[item.id] != nil {
            menu.addItem(ActionMenuItem("Use Original Icon") { [weak self] in self?.setCustomIcon(nil, for: item.id) })
        }
        if let app, item.id != "com.apple.finder" {
            menu.addItem(.separator())
            // Holding Option while opening the menu offers Force Quit. (A hidden alternate item
            // would still count towards the menu's height and push it away from the icon.)
            if NSEvent.modifierFlags.contains(.option) {
                menu.addItem(ActionMenuItem("Force Quit") { [weak self] in
                    self?.markQuitting(item.id)
                    app.forceTerminate()
                })
            } else {
                menu.addItem(ActionMenuItem("Quit") { [weak self] in
                    self?.markQuitting(item.id)
                    app.terminate()
                })
            }
        }
        return menu
    }

    /// Lets you pick any picture, icon file or app to use as this app's icon in the dock.
    func chooseIcon(for id: String, name: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose an icon for \(name)"
        panel.message = "Pick a picture, an .icns file, or an app whose icon you'd like to use."
        panel.prompt = "Use as Icon"
        panel.allowedContentTypes = [.image, .applicationBundle, .icns]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCustomIcon(url.path, for: id)
    }

    func setCustomIcon(_ path: String?, for id: String) {
        var icons = Settings.customIcons
        icons[id] = path
        Settings.customIcons = icons
        onChange?()
    }

    /// Some apps take a few seconds to shut down. Dim the icon straight away so the click feels
    /// answered; it disappears once the app has exited. If the app stays open (for example you
    /// cancel an unsaved-changes prompt), the icon comes back after a while.
    private func markQuitting(_ id: String) {
        quitting.insert(id)
        setQuitting(id, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.quitting.remove(id) != nil else { return }
                self.setQuitting(id, false)
            }
        }
    }

    private func setQuitting(_ id: String, _ value: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isQuitting != value else { return }
        items[i].isQuitting = value
        onChange?()
    }

    /// Asks first, like the macOS Dock, then has Finder empty the Trash.
    private static func confirmAndEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Run outside Clear Dock so a large Trash doesn't freeze the dock while Finder works.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        try? process.run()
    }

    // MARK: Helpers

    /// Whether the app has a real window open, shown or minimized. Apps such as Finder keep
    /// invisible helper windows, so first look for a normal window actually on screen, then
    /// ask the app itself (which also covers minimized windows), counting only true windows.
    private static func hasWindows(_ pid: pid_t) -> Bool {
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if onScreen.contains(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
            return true
        }
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        // Never wait long on an app that's busy.
        AXUIElementSetMessagingTimeout(app, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        // Finder lists the desktop here too, as a scroll area rather than a window.
        return windows.contains { window in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
                && (role as? String) == kAXWindowRole
        }
    }

    private static func key(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
    }

    private func runningApp(for item: DockItem) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { Self.key(for: $0) == item.id }
    }

    private func appItem(key: String, url: URL?, running: NSRunningApplication?) -> DockItem {
        var name = running?.localizedName
        if name == nil, let url {
            name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        }
        return DockItem(
            id: key,
            kind: .app,
            name: name ?? key,
            url: url,
            isRunning: running != nil,
            isHidden: running?.isHidden ?? false,
            badge: url.flatMap { badges[$0.standardizedFileURL.path] },
            isQuitting: quitting.contains(key)
        )
    }
}

/// A menu item that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
