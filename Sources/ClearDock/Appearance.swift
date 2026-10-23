import AppKit

/// What sits behind the icons.
enum DockBackground: String, CaseIterable, Identifiable {
    case none, glass, color, wallpaper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .glass: "Glass"
        case .color: "Colour"
        case .wallpaper: "Wallpaper"
        }
    }
}

/// The surface of a colour or wallpaper bar.
enum BarFinish: String, CaseIterable, Identifiable {
    case flat, bevel, gloss
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: "Flat"
        case .bevel: "Bevel"
        case .gloss: "Gloss"
        }
    }
}

/// How app icons are drawn. Applied once when each icon is drawn, so it costs nothing afterwards.
enum IconStyle: String, CaseIterable, Identifiable {
    case original, soft, vintage, mono, tinted, pixel, classic, gameboy, aqua, synthwave, sticker,
         phosphor, ink, pastel, blueprint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .soft: "Soft"
        case .vintage: "Vintage film"
        case .mono: "Mono"
        case .tinted: "Wallpaper tint"
        case .pixel: "8-bit pixel"
        case .classic: "Classic Mac (1-bit)"
        case .gameboy: "Game Boy"
        case .aqua: "Aqua gloss"
        case .synthwave: "Synthwave neon"
        case .sticker: "Sticker"
        case .phosphor: "Terminal phosphor"
        case .ink: "Manga ink"
        case .pastel: "Pastel"
        case .blueprint: "Blueprint"
        }
    }
}

/// What an icon does when you point at it.
enum HoverEffect: String, CaseIterable, Identifiable {
    case none, grow, lift, magnify
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .grow: "Grow"
        case .lift: "Lift"
        case .magnify: "Magnify"
        }
    }
}

/// The mark under an open app.
enum MarkerStyle: String, CaseIterable, Identifiable {
    case dot, line, square, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dot: "Dot"
        case .line: "Line"
        case .square: "Square"
        case .none: "None"
        }
    }
}

enum MarkerColor: String, CaseIterable, Identifiable {
    case white, black, wallpaper, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: "White"
        case .black: "Black"
        case .wallpaper: "Wallpaper"
        case .custom: "Custom"
        }
    }
}

/// Everything about how the dock looks, except size and spacing (which stay yours when you
/// switch themes). Stored in Clear Dock's preferences under "look." keys.
struct Look: Equatable {
    var background = DockBackground.none
    var backgroundColor = "#1C1C1E"
    var backgroundOpacity = 0.55
    /// A second colour fades the bar into it; empty means a single colour.
    var gradientColor = ""
    var cornerRadius = 18.0
    var finish = BarFinish.flat
    var outline = true
    /// Empty means "pick automatically from the background".
    var outlineColor = ""
    var iconStyle = IconStyle.original
    var iconShape = IconShape.original
    var markerStyle = MarkerStyle.dot
    var markerColor = MarkerColor.white
    var markerCustomColor = "#FFFFFF"
    var shadows = true
    var hoverEffect = HoverEffect.none
    /// How big the icon under the pointer gets when magnifying, as a multiple of its size.
    var magnifyScale = 1.6

    private static var defaults: UserDefaults { .standard }

    /// The look that's in use now.
    static var current: Look {
        get { Look(dictionary: defaults.dictionaryRepresentation()) }
        set {
            for (key, value) in newValue.dictionary { defaults.set(value, forKey: key) }
            Appearance.reload()
        }
    }

    init() {}

    init(dictionary d: [String: Any]) {
        func text(_ key: String) -> String? { d["look." + key] as? String }
        func number(_ key: String) -> Double? {
            if let n = d["look." + key] as? NSNumber { return n.doubleValue }
            return (d["look." + key] as? String).flatMap(Double.init)
        }
        func flag(_ key: String) -> Bool? {
            if let n = d["look." + key] as? NSNumber { return n.boolValue }
            return (d["look." + key] as? String).map { ["1", "yes", "true"].contains($0.lowercased()) }
        }
        background = text("background").flatMap(DockBackground.init(rawValue:)) ?? background
        backgroundColor = text("backgroundColor") ?? backgroundColor
        backgroundOpacity = number("backgroundOpacity") ?? backgroundOpacity
        gradientColor = text("gradientColor") ?? gradientColor
        cornerRadius = number("cornerRadius") ?? cornerRadius
        finish = text("finish").flatMap(BarFinish.init(rawValue:)) ?? finish
        outline = flag("outline") ?? outline
        outlineColor = text("outlineColor") ?? outlineColor
        iconStyle = text("iconStyle").flatMap(IconStyle.init(rawValue:)) ?? iconStyle
        iconShape = text("iconShape").flatMap(IconShape.init(rawValue:)) ?? iconShape
        markerStyle = text("markerStyle").flatMap(MarkerStyle.init(rawValue:)) ?? markerStyle
        markerColor = text("markerColor").flatMap(MarkerColor.init(rawValue:)) ?? markerColor
        markerCustomColor = text("markerCustomColor") ?? markerCustomColor
        shadows = flag("shadows") ?? shadows
        hoverEffect = text("hoverEffect").flatMap(HoverEffect.init(rawValue:)) ?? hoverEffect
        magnifyScale = number("magnifyScale") ?? magnifyScale
    }

    var dictionary: [String: Any] {
        [
            "look.background": background.rawValue,
            "look.backgroundColor": backgroundColor,
            "look.backgroundOpacity": backgroundOpacity,
            "look.gradientColor": gradientColor,
            "look.cornerRadius": cornerRadius,
            "look.finish": finish.rawValue,
            "look.outline": outline,
            "look.outlineColor": outlineColor,
            "look.iconStyle": iconStyle.rawValue,
            "look.iconShape": iconShape.rawValue,
            "look.markerStyle": markerStyle.rawValue,
            "look.markerColor": markerColor.rawValue,
            "look.markerCustomColor": markerCustomColor,
            "look.shadows": shadows,
            "look.hoverEffect": hoverEffect.rawValue,
            "look.magnifyScale": magnifyScale,
        ]
    }
}

/// Quick access to the look in use, for drawing.
enum Appearance {
    private static var defaults: UserDefaults { .standard }
    /// Read once and kept, since drawing asks for these many times.
    nonisolated(unsafe) private static var cached: Look?
    private static var look: Look {
        if let cached { return cached }
        if let id = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["previewTheme"] as? String,
           let theme = DockTheme.all.first(where: { $0.id == id }) {
            cached = theme.look
            return theme.look
        }
        let look = Look(dictionary: defaults.dictionaryRepresentation())
        cached = look
        return look
    }

    /// Forget the kept copy, after the look has been changed elsewhere.
    static func reload() { cached = nil }

    static var background: DockBackground {
        get { look.background }
        set { defaults.set(newValue.rawValue, forKey: "look.background"); cached = nil }
    }
    static var backgroundColor: NSColor {
        get { NSColor(hex: look.backgroundColor) ?? .black }
        set { defaults.set(newValue.hexString, forKey: "look.backgroundColor"); cached = nil }
    }
    /// The second colour of a gradient bar, or nil for a single colour.
    static var gradientColor: NSColor? {
        get { NSColor(hex: look.gradientColor) }
        set { defaults.set(newValue?.hexString ?? "", forKey: "look.gradientColor"); cached = nil }
    }
    static var backgroundOpacity: Double {
        get { look.backgroundOpacity }
        set { defaults.set(newValue, forKey: "look.backgroundOpacity"); cached = nil }
    }
    static var cornerRadius: Double {
        get { look.cornerRadius }
        set { defaults.set(newValue, forKey: "look.cornerRadius"); cached = nil }
    }
    static var finish: BarFinish {
        get { look.finish }
        set { defaults.set(newValue.rawValue, forKey: "look.finish"); cached = nil }
    }
    static var outline: Bool {
        get { look.outline }
        set { defaults.set(newValue, forKey: "look.outline"); cached = nil }
    }
    /// Nil means "pick automatically".
    static var outlineColor: NSColor? {
        get { NSColor(hex: look.outlineColor) }
        set { defaults.set(newValue?.hexString ?? "", forKey: "look.outlineColor"); cached = nil }
    }
    static var iconStyle: IconStyle {
        get { look.iconStyle }
        set { defaults.set(newValue.rawValue, forKey: "look.iconStyle"); cached = nil }
    }
    static var iconShape: IconShape {
        get { look.iconShape }
        set { defaults.set(newValue.rawValue, forKey: "look.iconShape"); cached = nil }
    }
    static var markerStyle: MarkerStyle {
        get { look.markerStyle }
        set { defaults.set(newValue.rawValue, forKey: "look.markerStyle"); cached = nil }
    }
    static var markerColor: MarkerColor {
        get { look.markerColor }
        set { defaults.set(newValue.rawValue, forKey: "look.markerColor"); cached = nil }
    }
    static var markerCustomColor: NSColor {
        get { NSColor(hex: look.markerCustomColor) ?? .white }
        set { defaults.set(newValue.hexString, forKey: "look.markerCustomColor"); cached = nil }
    }
    static var shadows: Bool {
        get { look.shadows }
        set { defaults.set(newValue, forKey: "look.shadows"); cached = nil }
    }

    static var hoverEffect: HoverEffect {
        get { look.hoverEffect }
        set { defaults.set(newValue.rawValue, forKey: "look.hoverEffect"); cached = nil }
    }

    static var magnifyScale: Double {
        get { min(2.2, max(1.1, look.magnifyScale)) }
        set { defaults.set(newValue, forKey: "look.magnifyScale"); cached = nil }
    }

    /// How far the dock floats away from its screen edge, in points. Not part of themes.
    static var edgeGap: Double {
        get { defaults.double(forKey: "look.edgeGap") }
        set { defaults.set(newValue, forKey: "look.edgeGap") }
    }

    /// Space between icons, as a multiple of the normal gap. Not part of themes.
    static var spacing: Double {
        get { defaults.object(forKey: "look.spacing") == nil ? 1 : defaults.double(forKey: "look.spacing") }
        set { defaults.set(newValue, forKey: "look.spacing") }
    }

    /// The theme last picked, so the settings window can show it as selected.
    static var theme: String? {
        // Before anything has been customised, the dock looks like the Clear theme.
        get { defaults.string(forKey: "look.theme") ?? (defaults.object(forKey: "look.background") == nil ? "clear" : nil) }
        set { defaults.set(newValue, forKey: "look.theme") }
    }

    /// The dock takes on the top bar's look (its glass or colour, rounding and highlight), so the
    /// two match. Only while the bar is on; otherwise the dock keeps its own look.
    static var matchesBar: Bool {
        get { defaults.bool(forKey: "look.matchesBar") }
        set { defaults.set(newValue, forKey: "look.matchesBar") }
    }

    @MainActor static var hasBackground: Bool {
        if matchesBar, let look = BarLookShare.looks.values.first { return look.style != .none }
        return background != .none
    }

    /// Whether anything uses colours taken from the wallpaper.
    static var usesWallpaper: Bool {
        let look = look
        return look.background == .wallpaper || look.iconStyle == .tinted || look.markerColor == .wallpaper
    }
}

/// A named look: one of the built-in themes, or one you've saved.
struct DockTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let look: Look
    var isCustom = false

    func apply() {
        Look.current = look
        Appearance.theme = id
    }

    static var all: [DockTheme] { builtIn + custom }

    static let builtIn: [DockTheme] = {
        func theme(_ id: String, _ name: String, _ summary: String, _ configure: (inout Look) -> Void) -> DockTheme {
            var look = Look()
            configure(&look)
            return DockTheme(id: id, name: name, summary: summary, look: look)
        }
        return [
            theme("clear", "Clear", "Just the icons") { _ in },
            theme("glass", "Glass", "Liquid Glass bar") {
                $0.background = .glass; $0.cornerRadius = 22; $0.outline = false; $0.shadows = false
            },
            theme("wallpaper", "Wallpaper", "Wallpaper colours") {
                $0.background = .wallpaper; $0.backgroundOpacity = 0.6; $0.markerStyle = .line; $0.markerColor = .wallpaper
            },
            theme("storybook", "Storybook", "Soft and painterly") {
                $0.background = .wallpaper; $0.backgroundOpacity = 0.4; $0.cornerRadius = 24; $0.iconStyle = .soft
                $0.iconShape = .squircle; $0.markerStyle = .line; $0.markerColor = .wallpaper
            },
            theme("film", "Vintage Film", "Warm and faded") {
                $0.background = .color; $0.backgroundColor = "#EADFC8"; $0.backgroundOpacity = 0.9; $0.cornerRadius = 10
                $0.iconStyle = .vintage; $0.markerStyle = .line; $0.markerColor = .black; $0.shadows = false
            },
            theme("platinum", "Platinum", "Mac OS 9, 1999") {
                $0.background = .color; $0.backgroundColor = "#DDDDDD"; $0.backgroundOpacity = 1; $0.cornerRadius = 3
                $0.finish = .bevel; $0.outlineColor = "#555555"; $0.iconStyle = .classic; $0.markerStyle = .square
                $0.markerColor = .black; $0.shadows = false
            },
            theme("aqua", "Aqua", "Mac OS X, 2003") {
                $0.background = .color; $0.backgroundColor = "#F2F6FA"; $0.backgroundOpacity = 0.55; $0.cornerRadius = 12
                $0.finish = .gloss; $0.iconStyle = .aqua; $0.markerStyle = .dot; $0.markerColor = .black
                $0.hoverEffect = .grow
            },
            theme("arcade", "Arcade", "8-bit pixels") {
                $0.background = .color; $0.backgroundColor = "#14141F"; $0.backgroundOpacity = 0.92; $0.cornerRadius = 0
                $0.outlineColor = "#3DF2FF"; $0.iconStyle = .pixel; $0.markerStyle = .square; $0.markerColor = .custom
                $0.markerCustomColor = "#3DF2FF"; $0.shadows = false; $0.hoverEffect = .lift
            },
            theme("gameboy", "Game Boy", "Four shades of green") {
                $0.background = .color; $0.backgroundColor = "#9BBC0F"; $0.backgroundOpacity = 1; $0.cornerRadius = 8
                $0.finish = .bevel; $0.outlineColor = "#306230"; $0.iconStyle = .gameboy; $0.markerStyle = .square
                $0.markerColor = .custom; $0.markerCustomColor = "#0F380F"; $0.shadows = false
            },
            theme("synthwave", "Synthwave", "Neon, 1985") {
                $0.background = .color; $0.backgroundColor = "#1B0B2E"; $0.backgroundOpacity = 0.88; $0.cornerRadius = 14
                $0.finish = .gloss; $0.outlineColor = "#FF2E97"; $0.iconStyle = .synthwave; $0.markerStyle = .line
                $0.markerColor = .custom; $0.markerCustomColor = "#3DF2FF"; $0.shadows = false
            },
            theme("vaporwave", "Vaporwave", "Pink to cyan, 1995") {
                $0.background = .color; $0.backgroundColor = "#FF71CE"; $0.gradientColor = "#01CDFE"; $0.backgroundOpacity = 0.75
                $0.cornerRadius = 16; $0.finish = .gloss; $0.outlineColor = "#FFFFFF"; $0.iconStyle = .aqua
                $0.markerStyle = .line; $0.markerColor = .white; $0.hoverEffect = .grow
            },
            theme("win95", "Windows 95", "Grey taskbar, 1995") {
                $0.background = .color; $0.backgroundColor = "#C0C0C0"; $0.backgroundOpacity = 1; $0.cornerRadius = 0
                $0.finish = .bevel; $0.outlineColor = "#7B7B7B"; $0.iconStyle = .pixel; $0.markerStyle = .square
                $0.markerColor = .black; $0.shadows = false
            },
            theme("terminal", "Terminal", "Green phosphor") {
                $0.background = .color; $0.backgroundColor = "#050A06"; $0.backgroundOpacity = 0.92; $0.cornerRadius = 4
                $0.outlineColor = "#00FF66"; $0.iconStyle = .phosphor; $0.markerStyle = .square; $0.markerColor = .custom
                $0.markerCustomColor = "#00FF66"; $0.shadows = false; $0.hoverEffect = .lift
            },
            theme("manga", "Manga", "Ink and screentone") {
                $0.background = .color; $0.backgroundColor = "#F5F0E6"; $0.backgroundOpacity = 0.95; $0.cornerRadius = 6
                $0.outlineColor = "#111111"; $0.iconStyle = .ink; $0.iconShape = .rounded; $0.markerStyle = .line
                $0.markerColor = .black; $0.shadows = false
            },
            theme("pastel", "Pastel", "Soft candy colours") {
                $0.background = .color; $0.backgroundColor = "#FFE4EC"; $0.backgroundOpacity = 0.8; $0.cornerRadius = 22
                $0.iconStyle = .pastel; $0.iconShape = .squircle; $0.markerStyle = .dot; $0.markerColor = .custom
                $0.markerCustomColor = "#FF8FB1"; $0.hoverEffect = .grow
            },
            theme("blueprint", "Blueprint", "Lines on blue paper") {
                $0.background = .color; $0.backgroundColor = "#1F4E9A"; $0.backgroundOpacity = 0.94; $0.cornerRadius = 4
                $0.outlineColor = "#CFE3FF"; $0.iconStyle = .blueprint; $0.iconShape = .square; $0.markerStyle = .line
                $0.markerColor = .white; $0.shadows = false
            },
            theme("midnight", "Midnight", "Dark, with magnify") {
                $0.background = .color; $0.backgroundColor = "#0B0F1A"; $0.backgroundOpacity = 0.78; $0.cornerRadius = 20
                $0.outlineColor = "#2A3550"; $0.markerStyle = .line; $0.markerColor = .custom; $0.markerCustomColor = "#7AA2FF"
                $0.hoverEffect = .magnify
            },
            theme("sticker", "Stickers", "Die-cut icons") {
                $0.iconStyle = .sticker; $0.iconShape = .original; $0.markerColor = .white
            },
            theme("mono", "Mono", "Black and white icons") {
                $0.iconStyle = .mono
            },
        ]
    }()

    // MARK: Your own themes

    private static let customKey = "look.customThemes"

    static var custom: [DockTheme] {
        let saved = UserDefaults.standard.array(forKey: customKey) as? [[String: Any]] ?? []
        return saved.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                  let values = entry["look"] as? [String: Any] else { return nil }
            return DockTheme(id: id, name: name, summary: "Your theme", look: Look(dictionary: values), isCustom: true)
        }
    }

    /// Saves the current look under a name and selects it.
    @discardableResult
    static func saveCurrent(named name: String) -> DockTheme {
        let theme = DockTheme(id: "custom-\(UUID().uuidString)", name: name, summary: "Your theme", look: .current, isCustom: true)
        var saved = UserDefaults.standard.array(forKey: customKey) as? [[String: Any]] ?? []
        saved.append(["id": theme.id, "name": theme.name, "look": theme.look.dictionary])
        UserDefaults.standard.set(saved, forKey: customKey)
        Appearance.theme = theme.id
        return theme
    }

    /// A theme file: a property list with the theme's name and look.
    static let fileExtension = "cleardocktheme"

    func export(to url: URL) throws {
        let contents: [String: Any] = ["name": name, "look": look.dictionary, "format": 1]
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Adds a theme from a file to your themes and selects it.
    @discardableResult
    static func importTheme(from url: URL) throws -> DockTheme {
        let data = try Data(contentsOf: url)
        guard let contents = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let values = contents["look"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = (contents["name"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let theme = DockTheme(id: "custom-\(UUID().uuidString)", name: name, summary: "Your theme",
                              look: Look(dictionary: values), isCustom: true)
        var saved = UserDefaults.standard.array(forKey: customKey) as? [[String: Any]] ?? []
        saved.append(["id": theme.id, "name": theme.name, "look": theme.look.dictionary])
        UserDefaults.standard.set(saved, forKey: customKey)
        theme.apply()
        return theme
    }

    static func deleteCustom(_ id: String) {
        var saved = UserDefaults.standard.array(forKey: customKey) as? [[String: Any]] ?? []
        saved.removeAll { $0["id"] as? String == id }
        UserDefaults.standard.set(saved, forKey: customKey)
        if Appearance.theme == id { Appearance.theme = nil }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /// Roughly how light the colour looks, from 0 (black) to 1 (white).
    var lightness: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
