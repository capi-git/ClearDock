import AppKit

/// What's drawn behind the icons: nothing, Liquid Glass, a colour, or a colour from the wallpaper,
/// with an optional bevel or gloss. With no background, nothing extra is drawn at all.
@MainActor
final class DockBackgroundView: NSView {
    private var glass: NSGlassEffectView?
    private let plain = NSView()
    /// The shine across the top half, for the gloss finish.
    private let shine = CAGradientLayer()
    /// A two-colour fill, when a gradient colour is chosen.
    private let fill = CAGradientLayer()
    /// Light top edge and dark bottom edge, for the bevel finish.
    private let highlight = CAShapeLayer()
    private let shade = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        plain.wantsLayer = true
        plain.autoresizingMask = [.width, .height]
        addSubview(plain)
        for layer in [fill, shine, highlight, shade] as [CALayer] {
            plain.layer?.addSublayer(layer)
        }
        for edge in [highlight, shade] {
            edge.fillColor = nil
            edge.lineWidth = 1.5
        }
        // This layer measures from the bottom, so "from the top" runs from y = 1 down to 0.
        for gradient in [fill, shine] {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutFinish()
    }

    func apply() {
        let style = Appearance.background
        let radius = CGFloat(Appearance.cornerRadius)
        isHidden = style == .none

        if style == .glass {
            plain.isHidden = true
            if glass == nil {
                let view = NSGlassEffectView(frame: bounds)
                view.autoresizingMask = [.width, .height]
                addSubview(view, positioned: .below, relativeTo: nil)
                glass = view
            }
            glass?.cornerRadius = radius
            return
        }

        // Glass keeps working in the background while it exists, so remove it when not in use.
        glass?.removeFromSuperview()
        glass = nil
        guard style != .none, let layer = plain.layer else { return }
        plain.isHidden = false

        let color: NSColor = style == .color
            ? Appearance.backgroundColor
            // Darken the wallpaper's own colour a little so the icons stand out against it.
            : (WallpaperPalette.shared.base.blended(withFraction: 0.25, of: .black) ?? WallpaperPalette.shared.base)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let opacity = CGFloat(Appearance.backgroundOpacity)
        if style == .color, let second = Appearance.gradientColor {
            layer.backgroundColor = nil
            fill.isHidden = false
            fill.colors = [color.withAlphaComponent(opacity).cgColor, second.withAlphaComponent(opacity).cgColor]
        } else {
            fill.isHidden = true
            layer.backgroundColor = color.withAlphaComponent(opacity).cgColor
        }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Appearance.outline ? 1 : 0
        let automatic = color.lightness > 0.5 ? NSColor(white: 0, alpha: 0.28) : NSColor(white: 1, alpha: 0.18)
        layer.borderColor = (Appearance.outlineColor ?? automatic).cgColor

        let finish = Appearance.finish
        shine.isHidden = finish != .gloss
        highlight.isHidden = finish != .bevel
        shade.isHidden = finish != .bevel
        shine.colors = [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        shine.locations = [0, 0.48, 0.5]
        highlight.strokeColor = NSColor(white: 1, alpha: 0.75).cgColor
        shade.strokeColor = NSColor(white: 0, alpha: 0.35).cgColor
        layoutFinish()
        CATransaction.commit()
    }

    private func layoutFinish() {
        let bounds = plain.bounds
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shine.frame = bounds
        fill.frame = bounds
        // A raised edge: light along the top, dark along the bottom (this layer measures from the bottom).
        let inset: CGFloat = 1.5
        let top = CGMutablePath()
        top.move(to: CGPoint(x: inset + 2, y: bounds.height - inset))
        top.addLine(to: CGPoint(x: bounds.width - inset - 2, y: bounds.height - inset))
        let bottom = CGMutablePath()
        bottom.move(to: CGPoint(x: inset + 2, y: inset))
        bottom.addLine(to: CGPoint(x: bounds.width - inset - 2, y: inset))
        highlight.frame = bounds
        highlight.path = top
        shade.frame = bounds
        shade.path = bottom
        CATransaction.commit()
    }
}

/// Holds the background behind the icons and keeps both sized to the dock window.
@MainActor
final class DockContainerView: NSView {
    let background = DockBackgroundView()
    let dock: DockView
    /// Where the bar goes inside the dock window (it follows the icons, and stretches while magnifying).
    var barRect: CGRect = .zero {
        didSet {
            guard barRect != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            background.frame = barRect
            CATransaction.commit()
        }
    }

    init(dock: DockView) {
        self.dock = dock
        super.init(frame: .zero)
        addSubview(background)
        addSubview(dock)
        dock.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // The bar sits just inside the dock window, leaving a little air above the screen edge.
        background.frame = barRect
    }
}
