import AppKit

/// Draws the icons as plain Core Animation layers, and handles clicks, right-clicks, dragging to
/// reorder, scrolling, magnification and file drops. Works along any screen edge. Nothing redraws
/// unless something changes.
@MainActor
final class DockView: NSView {
    /// How long icons take to glide, grow in or shrink away.
    static let animationDuration: CFTimeInterval = 0.2

    private let model: DockModel

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Called when the pointer moves onto a different icon, or off them all (`nil`).
    var onHover: ((Int?) -> Void)?
    /// Called when an icon is pressed or picked up.
    var onPress: (() -> Void)?
    /// Builds the menu shown when a divider line is right-clicked.
    var settingsMenu: (() -> NSMenu)?
    /// While magnifying, the stretch of the row the icons cover (so the bar can follow); nil at rest.
    var onMagnifiedSpan: ((ClosedRange<CGFloat>?) -> Void)?

    /// Pixels per point of the screen the dock is on; icons are drawn at exactly this density.
    var scale: CGFloat = 2 {
        didSet { if scale != oldValue { update(animated: false) } }
    }

    private(set) var pressedIndex: Int? {
        didSet { if pressedIndex != oldValue { updateStates() } }
    }
    private(set) var dropIndex: Int? {
        didSet { if dropIndex != oldValue { updateStates() } }
    }
    var isBusy: Bool { pressedIndex != nil || dropIndex != nil || draggedID != nil }
    /// Whether the system has told us the pointer is over the dock (so it will also tell us when it leaves).
    private(set) var isPointerInside = false

    /// Each item's layers are kept between updates, so an icon can glide to its new place.
    private struct ItemLayers {
        let container = CALayer()
        let icon = CALayer()
        let dot = CALayer()
        let badge = CALayer()
        let badgeText = CATextLayer()
        var iconKey = ""
    }

    private var itemLayers: [String: ItemLayers] = [:]
    private var iconCache: [String: CGImage] = [:]

    // Dragging an icon to a new place
    private var mouseDownPoint: CGPoint?
    private var draggedID: String?

    private var hoveredIndex: Int?
    private var lastClick: (id: String, time: CFTimeInterval)?
    /// Where the pointer is along the row while magnifying.
    private var magnifyPosition: CGFloat?

    // Scrolling up on an icon
    private var scrollTotal: CGFloat = 0
    private var scrollHandled = false

    init(model: DockModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry along the row

    private var vertical: Bool { model.layout.edge.isVertical }

    /// The rectangle each item's layers live in: its stretch of the row, across the whole depth.
    private func slot(for frame: CGRect, offset: CGFloat = 0) -> CGRect {
        let size = model.layout.size
        return vertical
            ? CGRect(x: 0, y: frame.minY + offset, width: size.width, height: frame.height)
            : CGRect(x: frame.minX + offset, y: 0, width: frame.width, height: size.height)
    }

    private func setAlong(_ layer: CALayer, _ value: CGFloat) {
        if vertical { layer.position.y = value } else { layer.position.x = value }
    }

    private func along(_ point: CGPoint) -> CGFloat { vertical ? point.y : point.x }

    /// Puts a layer at `rect` by its size and centre. Setting `frame` instead would fold any hover
    /// lift or magnification into its resting place, leaving it off-line once the effect ends.
    private func place(_ layer: CALayer, in rect: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: Drawing

    /// Brings the layers in line with the model. When animated, icons glide to their new places,
    /// newly opened apps grow in and quit apps shrink away. `offset` shifts everything along the
    /// row, for while the window is still its old length.
    func update(animated: Bool, offset: CGFloat = 0) {
        guard let root = layer else { return }
        let layout = model.layout
        // Drawn as big as they get when magnified, so they stay sharp then.
        let largest = Appearance.hoverEffect == .magnify ? CGFloat(Appearance.magnifyScale) : 1
        let pixels = Int((layout.iconSize * scale * largest).rounded())
        var seen = Set<String>()
        var renderedAny = false

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.animationDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(!animated)

        for (i, item) in model.items.enumerated() where i < layout.frames.count {
            seen.insert(item.id)
            let frame = layout.frames[i]
            let target = slot(for: frame, offset: offset)

            var entry: ItemLayers
            let isNew: Bool
            if let existing = itemLayers[item.id] {
                entry = existing
                isNew = false
            } else {
                entry = ItemLayers()
                isNew = true
            }

            // Sizes and new layers snap into place; only positions and fades animate.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let dotOpacity: Float = item.kind == .app && item.isRunning && !item.isQuitting ? 1 : 0
            if isNew {
                entry.container.addSublayer(entry.icon)
                entry.container.addSublayer(entry.dot)
                entry.badge.addSublayer(entry.badgeText)
                entry.container.addSublayer(entry.badge)
                entry.container.frame = target
                entry.dot.opacity = dotOpacity
                root.addSublayer(entry.container)
            }
            entry.container.bounds = CGRect(origin: .zero, size: target.size)
            // The item's frame inside its own slot.
            let local = frame.offsetBy(dx: -slot(for: frame).minX, dy: -slot(for: frame).minY)
            configure(&entry, for: item, layout: layout, frame: local, pixels: pixels, renderedAny: &renderedAny)
            CATransaction.commit()

            // The icon being dragged follows the pointer instead. Only an icon whose place changed is
            // given a new one (and so a glide); while magnifying, the wave just below places them.
            let position = CGPoint(x: target.midX, y: target.midY)
            if item.id != draggedID, entry.container.position != position, !magnifyingNow {
                entry.container.position = position
            }
            if entry.dot.opacity != dotOpacity { entry.dot.opacity = dotOpacity }
            if item.isRunning { entry.icon.removeAnimation(forKey: "opening") }
            if isNew && animated { animateIn(entry.container) }
            itemLayers[item.id] = entry
        }

        for (id, entry) in itemLayers where !seen.contains(id) {
            itemLayers[id] = nil
            if animated {
                animateOut(entry.container)
            } else {
                entry.container.removeFromSuperlayer()
            }
        }
        CATransaction.commit()

        // Forget pictures of apps that have closed.
        let usedKeys = Set(itemLayers.values.map(\.iconKey))
        iconCache = iconCache.filter { usedKeys.contains($0.key) }
        updateStates()
        // Keep magnifying where the pointer is, if the row changed under it.
        if let magnifyPosition, isPointerInside { magnify(at: magnifyPosition, animated: animated) }
        // The icon under the pointer may be a different one now (an app opened or quit, or the row
        // was reordered): hover follows what's actually under it.
        if isPointerInside, let window, draggedID == nil {
            setHovered(model.index(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
        if renderedAny { MemoryRelief.soon() }
    }

    private var magnifyingNow: Bool {
        Appearance.hoverEffect == .magnify && magnifyPosition != nil && isPointerInside
    }

    /// Moves every icon along the row at once, with no animation.
    func shift(by amount: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in itemLayers.values {
            if vertical { entry.container.position.y += amount } else { entry.container.position.x += amount }
        }
        CATransaction.commit()
    }

    private func configure(_ entry: inout ItemLayers, for item: DockItem, layout: DockLayout, frame: CGRect,
                           pixels: Int, renderedAny: inout Bool) {
        let iconSize = layout.iconSize

        if item.kind == .separator {
            entry.icon.contents = nil
            entry.icon.backgroundColor = Self.markerColor().withAlphaComponent(0.4).cgColor
            entry.icon.cornerRadius = 0.75
            entry.icon.shadowOpacity = 0
            // A short line across the row.
            place(entry.icon, in: vertical
                ? CGRect(x: frame.minX + iconSize * 0.2, y: frame.midY - 0.75, width: iconSize * 0.6, height: 1.5)
                : CGRect(x: frame.midX - 0.75, y: frame.minY + iconSize * 0.2, width: 1.5, height: iconSize * 0.6))
            entry.icon.setAffineTransform(.identity)
            entry.iconKey = ""
            entry.badge.isHidden = true
            entry.dot.isHidden = true
            return
        }

        place(entry.icon, in: frame)
        entry.icon.backgroundColor = nil
        // The picture depends on the icon style (and, for a wallpaper tint, on the wallpaper colour).
        let style = Appearance.iconStyle
        let tint = style == .tinted ? WallpaperPalette.shared.accent.hexString : ""
        // Shapes are for app icons; the Trash keeps its own outline.
        let iconShape = item.kind == .app ? Appearance.iconShape : .original
        let key = "\(model.iconKey(for: item))@\(pixels)#\(style.rawValue)\(tint)#\(iconShape.rawValue)"
        if key != entry.iconKey {
            if let cached = iconCache[key] {
                entry.icon.contents = cached
            } else {
                entry.icon.contents = autoreleasepool { render(item, pixels: pixels, key: key, shape: iconShape) }
                renderedAny = true
            }
            entry.iconKey = key
        }
        entry.icon.contentsGravity = .resizeAspect
        entry.icon.contentsScale = scale
        // A fixed shadow outline is drawn once by the system instead of being worked out per frame.
        let inset = iconSize * 0.09
        let outline = CGRect(x: 0, y: 0, width: iconSize, height: iconSize).insetBy(dx: inset, dy: inset)
        entry.icon.shadowPath = CGPath(roundedRect: outline, cornerWidth: outline.width * 0.225, cornerHeight: outline.width * 0.225, transform: nil)
        entry.icon.shadowColor = NSColor.black.cgColor
        entry.icon.shadowOpacity = Appearance.shadows ? 0.3 : 0
        entry.icon.shadowRadius = 3
        entry.icon.shadowOffset = CGSize(width: 0, height: 1.5)

        // The mark beside an open app, on the screen-edge side: a dot, a short line or a square.
        let markerColor = Self.markerColor()
        let length = (iconSize * 0.36).rounded()
        let markerSize: CGSize = switch Appearance.markerStyle {
        case .line: vertical ? CGSize(width: 3, height: length) : CGSize(width: length, height: 3)
        case .square: CGSize(width: 5, height: 5)
        default: CGSize(width: 4, height: 4)
        }
        let center = layout.markerCenter(for: frame)
        let dotFrame = CGRect(x: center.x - markerSize.width / 2, y: center.y - markerSize.height / 2 + (vertical ? 0 : 0.5),
                              width: markerSize.width, height: markerSize.height)
        entry.dot.frame = dotFrame
        entry.dot.isHidden = Appearance.markerStyle == .none
        entry.dot.backgroundColor = markerColor.withAlphaComponent(0.92).cgColor
        let markerRadius = Appearance.markerStyle == .square ? 0 : min(markerSize.width, markerSize.height) / 2
        entry.dot.cornerRadius = markerRadius
        entry.dot.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: dotFrame.size), cornerWidth: markerRadius,
                                      cornerHeight: markerRadius, transform: nil)
        // A soft edge in the opposite shade keeps the mark visible on any background.
        entry.dot.shadowColor = (markerColor.lightness > 0.5 ? NSColor.black : NSColor.white).cgColor
        entry.dot.shadowOpacity = Appearance.hasBackground ? 0.25 : 0.6
        entry.dot.shadowRadius = 1
        entry.dot.shadowOffset = .zero

        configureBadge(&entry, text: item.badge, iconFrame: frame)
    }

    /// A red count in the icon's top-right corner, or a small red dot for apps that badge without a number.
    private func configureBadge(_ entry: inout ItemLayers, text: String?, iconFrame: CGRect) {
        guard Settings.showBadges, let text else {
            entry.badge.isHidden = true
            return
        }
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let height = max(13, (iconFrame.width * 0.38).rounded())
        entry.badge.isHidden = false
        entry.badge.backgroundColor = NSColor.systemRed.cgColor
        entry.badge.shadowColor = NSColor.black.cgColor
        entry.badge.shadowOpacity = 0.25
        entry.badge.shadowRadius = 1.5
        entry.badge.shadowOffset = .zero

        if label.isEmpty || label == "•" {
            let size = (height * 0.62).rounded()
            place(entry.badge, in: CGRect(x: iconFrame.maxX - size + 1, y: iconFrame.minY - 3, width: size, height: size))
            entry.badge.cornerRadius = size / 2
            entry.badge.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
            entry.badgeText.isHidden = true
            return
        }

        let font = NSFont.systemFont(ofSize: (height * 0.66).rounded(), weight: .semibold)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let badgeWidth = max(height, textWidth + (height * 0.6).rounded())
        place(entry.badge, in: CGRect(x: iconFrame.maxX - badgeWidth + 3, y: iconFrame.minY - 4, width: badgeWidth, height: height))
        entry.badge.cornerRadius = height / 2
        entry.badge.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: badgeWidth, height: height),
                                        cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        let lineHeight = ceil(font.ascender - font.descender)
        entry.badgeText.isHidden = false
        entry.badgeText.string = label
        entry.badgeText.font = font
        entry.badgeText.fontSize = font.pointSize
        entry.badgeText.foregroundColor = NSColor.white.cgColor
        entry.badgeText.alignmentMode = .center
        entry.badgeText.contentsScale = scale
        entry.badgeText.frame = CGRect(x: 0, y: ((height - lineHeight) / 2).rounded(), width: badgeWidth, height: lineHeight)
    }

    private func animateIn(_ container: CALayer) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Self.animationDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.add(group, forKey: "appear")
    }

    private func animateOut(_ container: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { container.removeFromSuperlayer() }
        container.opacity = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [shrink, fade]
        group.duration = Self.animationDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        container.add(group, forKey: "disappear")
        CATransaction.commit()
    }

    /// A gentle pulse on an app that was clicked but hasn't finished opening yet.
    private func showOpening(_ id: String) {
        guard let icon = itemLayers[id]?.icon else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.55
        pulse.autoreverses = true
        pulse.repeatCount = 18  // gives up after about 20 seconds
        icon.add(pulse, forKey: "opening")
    }

    /// Draws the app's icon once into a small bitmap at the exact size shown,
    /// instead of keeping the full-size (up to 1024 px) icon in memory.
    private func render(_ item: DockItem, pixels: Int, key: String, shape: IconShape) -> CGImage? {
        guard pixels > 0, let source = model.sourceIcon(for: item),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let drawn = context.makeImage() else { return nil }
        let image = IconEffects.apply(drawn, style: Appearance.iconStyle, shape: shape,
                                      accent: WallpaperPalette.shared.accent)
        iconCache[key] = image
        return image
    }

    /// The top bar's highlight colour, while the dock matches the bar.
    static var barAccent: NSColor?

    /// The colour of the marks beside open apps, and of the divider lines.
    private static func markerColor() -> NSColor {
        if let barAccent { return barAccent }
        return switch Appearance.markerColor {
        case .white: .white
        case .black: .black
        case .wallpaper: WallpaperPalette.shared.accent
        case .custom: Appearance.markerCustomColor
        }
    }

    private func updateStates() {
        let layout = model.layout
        let out = layout.outward
        let magnifying = Appearance.hoverEffect == .magnify && magnifyPosition != nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        defer { CATransaction.commit() }
        func set(_ layer: CALayer, _ transform: CGAffineTransform) {
            if layer.affineTransform() != transform { layer.setAffineTransform(transform) }
        }
        for (i, item) in model.items.enumerated() where item.kind != .separator {
            guard let entry = itemLayers[item.id] else { continue }
            let base: Float = item.isQuitting ? 0.35 : (item.isHidden ? 0.5 : 1)
            let opacity = pressedIndex == i ? base * 0.6 : base
            if entry.icon.opacity != opacity { entry.icon.opacity = opacity }
            let lifted = dropIndex == i || item.id == draggedID
            let z: CGFloat = item.id == draggedID ? 1 : 0
            if entry.container.zPosition != z { entry.container.zPosition = z }
            if lifted {
                set(entry.icon, CGAffineTransform(scaleX: 1.12, y: 1.12))
                continue
            }
            // Magnification sets its own sizes as the pointer moves.
            if magnifying { continue }
            var transform = CGAffineTransform.identity
            if i == hoveredIndex {
                switch Appearance.hoverEffect {
                case .none, .magnify: break
                case .grow:
                    let grow: CGFloat = 1.16
                    let push = (grow - 1) * layout.iconSize / 2
                    transform = CGAffineTransform(translationX: out.dx * push, y: out.dy * push).scaledBy(x: grow, y: grow)
                case .lift:
                    let push = layout.hoverRoom * 0.8
                    transform = CGAffineTransform(translationX: out.dx * push, y: out.dy * push)
                }
            }
            set(entry.icon, transform)
            set(entry.badge, .identity)
        }
    }

    // MARK: Magnification

    /// Swells the icons near `position` (along the row) in a smooth wave, pushing neighbours apart
    /// while the icon under the pointer stays under it. Nil settles everything back.
    private func magnify(at position: CGFloat?, animated: Bool) {
        guard Appearance.hoverEffect == .magnify else { return }
        let layout = model.layout
        let items = model.items
        guard !items.isEmpty, items.count == layout.frames.count else { return }
        magnifyPosition = position

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.16)
        defer { CATransaction.commit() }

        guard let position else {
            for (i, item) in items.enumerated() {
                guard let entry = itemLayers[item.id], item.id != draggedID else { continue }
                let target = slot(for: layout.frames[i])
                entry.container.position = CGPoint(x: target.midX, y: target.midY)
                entry.icon.setAffineTransform(.identity)
                entry.badge.setAffineTransform(.identity)
            }
            onMagnifiedSpan?(nil)
            return
        }

        let peak = CGFloat(Appearance.magnifyScale)
        let reach = layout.iconSize * 2.6
        var starts: [CGFloat] = [], lengths: [CGFloat] = [], scales: [CGFloat] = []
        var cursor: CGFloat = 0
        for (i, frame) in layout.frames.enumerated() {
            let span = layout.along(frame)
            let length = span.upperBound - span.lowerBound
            var scale: CGFloat = 1
            if items[i].kind != .separator {
                let distance = min(1, abs(position - (span.lowerBound + span.upperBound) / 2) / reach)
                scale = 1 + (peak - 1) * (cos(distance * .pi) + 1) / 2
            }
            starts.append(cursor)
            lengths.append(length * scale)
            scales.append(scale)
            cursor += length * scale + layout.gap
        }
        // Keep whatever is under the pointer under the pointer.
        var anchor = 0
        for (i, frame) in layout.frames.enumerated() where position >= layout.along(frame).lowerBound - layout.gap / 2 {
            anchor = i
        }
        let anchorSpan = layout.along(layout.frames[anchor])
        let fraction = min(1, max(0, (position - anchorSpan.lowerBound) / max(1, anchorSpan.upperBound - anchorSpan.lowerBound)))
        let shift = position - (starts[anchor] + fraction * lengths[anchor])

        let out = layout.outward
        for (i, item) in items.enumerated() {
            guard let entry = itemLayers[item.id], item.id != draggedID else { continue }
            setAlong(entry.container, shift + starts[i] + lengths[i] / 2)
            guard item.kind != .separator else { continue }
            let scale = scales[i]
            let push = (scale - 1) * layout.iconSize / 2
            let transform = CGAffineTransform(translationX: out.dx * push, y: out.dy * push).scaledBy(x: scale, y: scale)
            entry.icon.setAffineTransform(transform)
            // The badge rides along on the icon's corner.
            let iconCenter = entry.icon.position  // the untransformed centre
            let badgeCenter = entry.badge.position
            let moved = CGPoint(x: iconCenter.x + scale * (badgeCenter.x - iconCenter.x) + out.dx * push,
                                y: iconCenter.y + scale * (badgeCenter.y - iconCenter.y) + out.dy * push)
            entry.badge.setAffineTransform(CGAffineTransform(translationX: moved.x - badgeCenter.x, y: moved.y - badgeCenter.y)
                .scaledBy(x: scale, y: scale))
        }
        let last = items.count - 1
        onMagnifiedSpan?((shift + starts[0])...(shift + starts[last] + lengths[last]))
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            // Pointer movement is only reported while it's over the dock itself.
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onEnter?()
        let point = convert(event.locationInWindow, from: nil)
        setHovered(model.index(at: point))
        if draggedID == nil { magnify(at: along(point), animated: true) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(draggedID == nil ? model.index(at: point) : nil)
        if draggedID == nil { magnify(at: along(point), animated: false) }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        setHovered(nil)
        magnify(at: nil, animated: true)
        onExit?()
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        onHover?(index)
        guard Appearance.hoverEffect == .grow || Appearance.hoverEffect == .lift else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        updateStates()
        CATransaction.commit()
    }

    /// For checking hover effects on screen: launch with -previewHover <icon number>.
    func applyPreviewHover() {
        guard let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["previewHover"] as? String,
              let index = Int(value), index < model.layout.frames.count else { return }
        hoveredIndex = index
        if Appearance.hoverEffect == .magnify {
            let span = model.layout.along(model.layout.frames[index])
            magnify(at: (span.lowerBound + span.upperBound) / 2, animated: false)
        } else {
            updateStates()
        }
    }

    /// Forgets which icon was hovered, e.g. after the icons have moved.
    func resetHover() {
        hoveredIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control) {
            showMenu(at: point)
            return
        }
        mouseDownPoint = point
        pressedIndex = model.index(at: point)
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggedID == nil {
            // A small wobble is still a click; a real move along the row picks the icon up.
            guard let start = mouseDownPoint, let index = pressedIndex, model.canMove(index),
                  abs(along(point) - along(start)) > 5 else { return }
            magnify(at: nil, animated: true)
            draggedID = model.items[index].id
            pressedIndex = nil
            updateStates()
        }
        guard let id = draggedID, let entry = itemLayers[id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setAlong(entry.container, min(max(along(point), 0), vertical ? bounds.height : bounds.width))
        CATransaction.commit()
        if model.move(id, toward: along(point), save: false) {
            update(animated: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = nil
        if let id = draggedID {
            model.move(id, toward: along(point), save: true)
            draggedID = nil
            update(animated: true)
            return
        }
        defer { pressedIndex = nil }
        guard let pressed = pressedIndex, model.index(at: point) == pressed else { return }
        let item = model.items[pressed]
        // Shortcuts from the macOS Dock: ⌘-click shows the app in Finder,
        // ⌥-click switches to it and hides the app you were using.
        if event.modifierFlags.contains(.command), item.kind == .app, let url = item.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        // A second click on the same icon this soon is part of the same intent (a habitual
        // double-click), so it shouldn't undo what the first click did.
        let now = CACurrentMediaTime()
        if let last = lastClick, last.id == item.id, now - last.time < 0.25 { return }
        lastClick = (item.id, now)
        let appToHide = event.modifierFlags.contains(.option) ? NSWorkspace.shared.frontmostApplication : nil
        if item.kind == .app && !item.isRunning { showOpening(item.id) }
        model.activate(pressed)
        if let appToHide, appToHide.bundleIdentifier != item.id, appToHide != NSRunningApplication.current { appToHide.hide() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onPress?()
        showMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard Settings.scrollToOpen, event.momentumPhase.isEmpty else { return }
        if event.phase == .began || event.phase.isEmpty {
            scrollTotal = 0
            scrollHandled = false
        }
        // Which way the fingers (or wheel) actually moved, whatever the scroll direction setting.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        scrollTotal += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 0.5
        if !scrollHandled, scrollTotal > threshold,
           let index = model.index(at: convert(event.locationInWindow, from: nil)) {
            scrollHandled = true
            model.showWindows(index)
        }
    }

    private func showMenu(at point: CGPoint) {
        guard let index = model.index(at: point, includingSeparators: true) else { return }
        // Like the macOS Dock, a divider line opens the dock's own settings.
        let isDivider = model.items[index].kind == .separator
        guard let menu = isDivider ? settingsMenu?() : model.menu(for: index) else { return }
        let frame = model.layout.frames[index]
        // Open the menu just beyond the icon, away from the screen edge, like the macOS Dock.
        let size = menu.size
        let origin: CGPoint = switch model.layout.edge {
        case .bottom: CGPoint(x: (frame.midX - size.width / 2).rounded(), y: frame.minY - 6 - size.height)
        case .left: CGPoint(x: frame.maxX + 8, y: (frame.midY - size.height / 2).rounded())
        case .right: CGPoint(x: frame.minX - 8 - size.width, y: (frame.midY - size.height / 2).rounded())
        }
        menu.popUp(positioning: nil, at: origin, in: self)
        pointerMayHaveLeft()
    }

    /// While a menu or a dialog is open, the dock isn't told when the pointer leaves; once it's
    /// closed, check, so the dock doesn't stay magnified, highlighted or up.
    func pointerMayHaveLeft() {
        guard isPointerInside, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard !bounds.contains(point) else { return }
        isPointerInside = false
        setHovered(nil)
        magnify(at: nil, animated: true)
        onExit?()
    }

    // MARK: Dropping files onto an app or the Trash

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEnter?()
        return dragUpdate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        onExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndex = nil }
        guard let index = dropIndex,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else { return false }
        model.open(urls, with: index)
        return true
    }

    private func dragUpdate(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = model.index(at: convert(sender.draggingLocation, from: nil))
        dropIndex = index
        guard let index else { return [] }
        return model.items[index].kind == .trash ? .move : .copy
    }
}
