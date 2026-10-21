import AppKit

/// Icon themes and shapes. Each icon is drawn once at the exact size shown and then kept as a
/// small bitmap, so a theme costs nothing after that. All the work is plain pixel arithmetic on
/// images of a few thousand pixels.
enum IconEffects {
    /// Applies the shape, then the theme, to a freshly drawn square icon.
    static func apply(_ image: CGImage, style: IconStyle, shape: IconShape, accent: NSColor) -> CGImage {
        var bitmap = Bitmap(image)
        if shape != .original { bitmap = reshaped(bitmap, shape) }
        switch style {
        case .original: break
        case .soft: bitmap.map(soft)
        case .vintage: bitmap.map(vintage)
        case .mono: bitmap.map(mono)
        case .tinted:
            let (dark, light) = duotone(for: accent)
            bitmap.map { gradientMap($0, stops: [dark, light]) }
        case .pixel: bitmap = pixelated(bitmap)
        case .classic: bitmap = classicMac(bitmap)
        case .gameboy: bitmap = gameBoy(bitmap)
        case .aqua: bitmap = aqua(bitmap)
        case .synthwave: bitmap = synthwave(bitmap)
        case .sticker: bitmap = sticker(bitmap)
        case .phosphor: bitmap = phosphor(bitmap)
        case .ink: bitmap = ink(bitmap)
        case .pastel: bitmap = pastel(bitmap)
        case .blueprint: bitmap = blueprint(bitmap)
        }
        return bitmap.image() ?? image
    }

    // MARK: Colour themes (one pixel at a time)

    typealias RGB = (r: Double, g: Double, b: Double)

    private static func luma(_ c: RGB) -> Double { 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }

    /// Calmer colours, blacks kept black.
    private static func soft(_ c: RGB) -> RGB {
        let l = luma(c)
        let mix = 0.3
        return (c.r + (l - c.r) * mix + 0.04 * l, c.g + (l - c.g) * mix + 0.04 * l, c.b + (l - c.b) * mix + 0.04 * l)
    }

    /// Warm, slightly faded film. Lifts the darkest tones only a touch, so dark icons stay dark.
    private static func vintage(_ c: RGB) -> RGB {
        let sepia: RGB = (0.393 * c.r + 0.769 * c.g + 0.189 * c.b,
                          0.349 * c.r + 0.686 * c.g + 0.168 * c.b,
                          0.272 * c.r + 0.534 * c.g + 0.131 * c.b)
        let m = 0.35
        var out: RGB = (c.r + (sepia.r - c.r) * m, c.g + (sepia.g - c.g) * m, c.b + (sepia.b - c.b) * m)
        out = (out.r * 1.03 + 0.025, out.g * 0.99 + 0.02, out.b * 0.9 + 0.02)
        return out
    }

    private static func mono(_ c: RGB) -> RGB {
        let l = min(1, luma(c) * 1.04)
        return (l, l, l)
    }

    /// Maps brightness onto a run of colours.
    private static func gradientMap(_ c: RGB, stops: [RGB]) -> RGB {
        let l = min(1, max(0, luma(c)))
        let scaled = l * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(scaled))
        let t = scaled - Double(i)
        let a = stops[i], b = stops[i + 1]
        return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    private static func duotone(for accent: NSColor) -> (RGB, RGB) {
        let c = accent.usingColorSpace(.sRGB) ?? accent
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        return ((r * 0.18, g * 0.18, b * 0.22), (r + (1 - r) * 0.55, g + (1 - g) * 0.55, b + (1 - b) * 0.55))
    }

    // MARK: Retro themes

    /// 8-bit: big square pixels and a small palette.
    private static func pixelated(_ source: Bitmap) -> Bitmap {
        // Coarse enough to read as pixel art, fine enough to tell apps apart at small sizes.
        let grid = min(18, max(12, source.size * 2 / 5))
        var cells = source.downsampled(to: grid)
        cells.mapAll { c in
            guard c.a > 0.5 else { return (0, 0, 0, 0) }
            let levels = 5.0
            func q(_ v: Double) -> Double { (v * (levels - 1)).rounded() / (levels - 1) }
            return (q(c.r), q(c.g), q(c.b), 1)
        }
        return cells.upscaled(to: source.size)
    }

    /// Brightness of each pixel stretched to the full range, and flipped for dark icons, so retro
    /// palettes get light backgrounds with dark lines, as old icons had.
    private static func normalizedBrightness(_ bitmap: Bitmap, inside: [Bool]) -> [Double] {
        var values = [Double](repeating: 0, count: bitmap.size * bitmap.size)
        var sample: [Double] = []
        for y in 0..<bitmap.size {
            for x in 0..<bitmap.size where inside[y * bitmap.size + x] {
                let c = bitmap.get(x, y)
                let l = luma((c.r, c.g, c.b))
                values[y * bitmap.size + x] = l
                sample.append(l)
            }
        }
        guard !sample.isEmpty else { return values }
        sample.sort()
        let low = sample[sample.count / 20], high = sample[sample.count * 19 / 20]
        let mean = sample.reduce(0, +) / Double(sample.count)
        let invert = mean < 0.45
        let range = max(0.08, high - low)
        for i in values.indices where inside[i] {
            var l = min(1, max(0, (values[i] - low) / range))
            if invert { l = 1 - l }
            values[i] = l
        }
        return values
    }

    /// 1-bit, like System 7: white with black lines, a dither pattern only in the mid-tones,
    /// and a black outline.
    private static func classicMac(_ source: Bitmap) -> Bitmap {
        let grid = min(32, max(12, source.size / 2))
        var cells = source.downsampled(to: grid)
        let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        let inside = cells.alphaMask(threshold: 0.5)
        let brightness = normalizedBrightness(cells, inside: inside)
        for y in 0..<grid {
            for x in 0..<grid {
                guard inside[y * grid + x] else { cells.set(x, y, (0, 0, 0, 0)); continue }
                if cells.isEdge(x, y, mask: inside) {
                    cells.set(x, y, (0, 0, 0, 1))
                    continue
                }
                let l = brightness[y * grid + x]
                let white: Bool
                if l < 0.32 { white = false }
                else if l > 0.68 { white = true }
                else { white = (l - 0.32) / 0.36 > (bayer[y % 4][x % 4] + 0.5) / 16 }
                cells.set(x, y, white ? (1, 1, 1, 1) : (0, 0, 0, 1))
            }
        }
        return cells.upscaled(to: source.size)
    }

    /// Four shades of green, like the original Game Boy screen.
    private static func gameBoy(_ source: Bitmap) -> Bitmap {
        let grid = min(24, max(10, Int(Double(source.size) / 2.5)))
        var cells = source.downsampled(to: grid)
        let palette: [RGB] = [(0.06, 0.22, 0.06), (0.19, 0.38, 0.19), (0.55, 0.67, 0.06), (0.61, 0.74, 0.06)]
        let bayer: [[Double]] = [[0, 2], [3, 1]]
        let inside = cells.alphaMask(threshold: 0.5)
        let brightness = normalizedBrightness(cells, inside: inside)
        for y in 0..<grid {
            for x in 0..<grid {
                guard inside[y * grid + x] else { cells.set(x, y, (0, 0, 0, 0)); continue }
                if cells.isEdge(x, y, mask: inside) {
                    let p = palette[0]
                    cells.set(x, y, (p.r, p.g, p.b, 1))
                    continue
                }
                let l = min(0.999, max(0, brightness[y * grid + x] + (bayer[y % 2][x % 2] - 1.5) / 14))
                let p = palette[max(0, min(3, Int(l * 4)))]
                cells.set(x, y, (p.r, p.g, p.b, 1))
            }
        }
        return cells.upscaled(to: source.size)
    }

    /// Early-2000s Aqua: richer colour and a glossy shine across the top.
    private static func aqua(_ source: Bitmap) -> Bitmap {
        var out = source
        out.map { c in
            let l = luma(c)
            return (l + (c.r - l) * 1.2, l + (c.g - l) * 1.2, l + (c.b - l) * 1.2)
        }
        let size = Double(out.size)
        for y in 0..<out.size {
            // Rows are stored top first here; the shine fades out halfway down.
            let t = Double(y) / size
            guard t < 0.5 else { break }
            let shine = 0.55 * pow(1 - t / 0.5, 1.6)
            for x in 0..<out.size {
                var c = out.get(x, y)
                guard c.a > 0 else { continue }
                c.r += (1 - c.r) * shine; c.g += (1 - c.g) * shine; c.b += (1 - c.b) * shine
                out.set(x, y, c)
            }
        }
        return out
    }

    /// Neon synthwave: deep purple to hot pink to cyan, with a glowing cyan edge.
    private static func synthwave(_ source: Bitmap) -> Bitmap {
        var out = source
        let stops: [RGB] = [(0.10, 0.02, 0.20), (0.55, 0.05, 0.55), (1.0, 0.18, 0.59), (0.24, 0.95, 1.0)]
        out.map { gradientMap($0, stops: stops) }
        let inside = out.alphaMask(threshold: 0.5)
        let width = max(1, out.size / 40)
        for y in 0..<out.size {
            for x in 0..<out.size where inside[y * out.size + x] && out.isEdge(x, y, mask: inside, radius: width) {
                out.set(x, y, (0.3, 1, 1, 1))
            }
        }
        return out
    }

    /// A white die-cut border, like a sticker.
    private static func sticker(_ source: Bitmap) -> Bitmap {
        // Shrink the icon a little so the border fits, then grow a white edge around it.
        let inner = source.scaledCentered(by: 0.86)
        let inside = inner.alphaMask(threshold: 0.4)
        let radius = max(1, inner.size / 22)
        var out = Bitmap(size: inner.size)
        for y in 0..<inner.size {
            for x in 0..<inner.size {
                let c = inner.get(x, y)
                if c.a > 0.02 {
                    // The icon over white, so soft edges blend into the border.
                    out.set(x, y, (c.r * c.a + (1 - c.a), c.g * c.a + (1 - c.a), c.b * c.a + (1 - c.a), 1))
                } else if inner.isNear(x, y, mask: inside, radius: radius) {
                    out.set(x, y, (1, 1, 1, 1))
                }
            }
        }
        return out
    }

    /// Light, chalky colours. Dark icons have their lightness flipped first (keeping their colours),
    /// so a black background becomes a pale one rather than a grey box.
    private static func pastel(_ source: Bitmap) -> Bitmap {
        var out = source
        var total = 0.0, count = 0.0
        for y in 0..<out.size {
            for x in 0..<out.size where out.get(x, y).a > 0.5 {
                let p = out.get(x, y)
                total += luma((p.r, p.g, p.b)); count += 1
            }
        }
        let flip = count > 0 && total / count < 0.45
        out.map { c in
            let color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let lightness = flip ? 1 - b : b
            let pastel = NSColor(hue: h, saturation: s * 0.45, brightness: 0.55 + lightness * 0.45, alpha: 1)
            return (Double(pastel.redComponent), Double(pastel.greenComponent), Double(pastel.blueComponent))
        }
        return out
    }

    /// How sharply brightness changes at each pixel, from 0 to 1 (a Sobel edge filter).
    private static func edges(_ bitmap: Bitmap, brightness: [Double]) -> [Double] {
        let n = bitmap.size
        var out = [Double](repeating: 0, count: n * n)
        var peak = 0.0001
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                func l(_ dx: Int, _ dy: Int) -> Double { brightness[(y + dy) * n + x + dx] }
                let gx = -l(-1, -1) - 2 * l(-1, 0) - l(-1, 1) + l(1, -1) + 2 * l(1, 0) + l(1, 1)
                let gy = -l(-1, -1) - 2 * l(0, -1) - l(1, -1) + l(-1, 1) + 2 * l(0, 1) + l(1, 1)
                let m = (gx * gx + gy * gy).squareRoot()
                out[y * n + x] = m
                peak = max(peak, m)
            }
        }
        return out.map { $0 / peak }
    }

    /// A green computer terminal: phosphor glow on black, with scanlines.
    private static func phosphor(_ source: Bitmap) -> Bitmap {
        var out = source
        let inside = out.alphaMask(threshold: 0.3)
        var brightness = [Double](repeating: 0, count: out.size * out.size)
        var sample: [Double] = []
        for i in brightness.indices where inside[i] {
            let p = out.get(i % out.size, i / out.size)
            brightness[i] = luma((p.r, p.g, p.b)); sample.append(brightness[i])
        }
        sample.sort()
        let low = sample.isEmpty ? 0 : sample[sample.count / 20], high = sample.isEmpty ? 1 : sample[sample.count * 19 / 20]
        let stops: [RGB] = [(0.0, 0.05, 0.02), (0.0, 0.35, 0.12), (0.1, 1.0, 0.45), (0.8, 1.0, 0.85)]
        let lineEvery = max(2, out.size / 24)
        for y in 0..<out.size {
            for x in 0..<out.size where inside[y * out.size + x] {
                let l = min(1, max(0, (brightness[y * out.size + x] - low) / max(0.08, high - low)))
                var c = gradientMap((l, l, l), stops: stops)
                if y % lineEvery == 0 { c = (c.r * 0.6, c.g * 0.6, c.b * 0.6) }
                out.set(x, y, (c.r, c.g, c.b, 1))
            }
        }
        return out
    }

    /// Manga ink: black lines on paper, with screentone dots in the darker areas.
    private static func ink(_ source: Bitmap) -> Bitmap {
        var out = source
        let inside = out.alphaMask(threshold: 0.4)
        let brightness = normalizedBrightness(out, inside: inside)
        let lines = edges(out, brightness: brightness)
        let paper: Pixel = (0.96, 0.94, 0.89, 1), inkColor: Pixel = (0.08, 0.07, 0.07, 1)
        let dot = max(3, out.size / 16)
        for y in 0..<out.size {
            for x in 0..<out.size {
                let i = y * out.size + x
                guard inside[i] else { out.set(x, y, (0, 0, 0, 0)); continue }
                if out.isEdge(x, y, mask: inside, radius: max(1, out.size / 48)) || lines[i] > 0.35 {
                    out.set(x, y, inkColor)
                } else if brightness[i] < 0.38 && (x % dot == 0) && (y % dot == 0 || y % dot == dot / 2 && x % (dot * 2) == 0) {
                    out.set(x, y, inkColor)
                } else if brightness[i] < 0.18 && (x + y) % 3 == 0 {
                    out.set(x, y, inkColor)
                } else {
                    out.set(x, y, paper)
                }
            }
        }
        return out
    }

    /// A blueprint: white lines on blue paper with a faint grid.
    private static func blueprint(_ source: Bitmap) -> Bitmap {
        var out = source
        let inside = out.alphaMask(threshold: 0.4)
        let brightness = normalizedBrightness(out, inside: inside)
        let lines = edges(out, brightness: brightness)
        let paper: Pixel = (0.12, 0.31, 0.62, 1), grid: Pixel = (0.2, 0.4, 0.72, 1), white: Pixel = (0.92, 0.96, 1, 1)
        let step = max(4, out.size / 8)
        for y in 0..<out.size {
            for x in 0..<out.size {
                let i = y * out.size + x
                guard inside[i] else { out.set(x, y, (0, 0, 0, 0)); continue }
                if out.isEdge(x, y, mask: inside, radius: max(1, out.size / 48)) || lines[i] > 0.3 {
                    out.set(x, y, white)
                } else if x % step == 0 || y % step == 0 {
                    out.set(x, y, grid)
                } else {
                    out.set(x, y, paper)
                }
            }
        }
        return out
    }

    typealias Pixel = Bitmap.Pixel

    // MARK: Shapes

    /// Gives every icon the same outline. macOS icons leave a margin around their artwork,
    /// so the artwork is enlarged a little to fill the new shape.
    private static func reshaped(_ source: Bitmap, _ shape: IconShape) -> Bitmap {
        let size = CGFloat(source.size)
        guard let image = source.image(),
              let context = CGContext(data: nil, width: source.size, height: source.size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        let inset = size * 0.06
        let box = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path: CGPath
        switch shape {
        case .original: return source
        case .squircle: path = CGPath(roundedRect: box, cornerWidth: box.width * 0.24, cornerHeight: box.width * 0.24, transform: nil)
        case .circle: path = CGPath(ellipseIn: box, transform: nil)
        case .rounded: path = CGPath(roundedRect: box, cornerWidth: box.width * 0.12, cornerHeight: box.width * 0.12, transform: nil)
        case .square: path = CGPath(rect: box, transform: nil)
        }
        context.interpolationQuality = .high
        context.addPath(path)
        context.clip()
        let grow: CGFloat = shape == .circle ? 1.3 : 1.2
        let drawn = size * grow
        context.draw(image, in: CGRect(x: (size - drawn) / 2, y: (size - drawn) / 2, width: drawn, height: drawn))
        guard let result = context.makeImage() else { return source }
        return Bitmap(result)
    }
}

/// How app icons are outlined.
enum IconShape: String, CaseIterable, Identifiable {
    case original, squircle, rounded, circle, square
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "As designed"
        case .squircle: "Squircle"
        case .rounded: "Rounded"
        case .circle: "Circle"
        case .square: "Square"
        }
    }
}

/// A small square RGBA image in plain (not premultiplied) 0–1 values, rows stored top first.
struct Bitmap {
    typealias Pixel = (r: Double, g: Double, b: Double, a: Double)
    let size: Int
    private var pixels: [Pixel]

    init(size: Int) {
        self.size = size
        pixels = Array(repeating: (0, 0, 0, 0), count: size * size)
    }

    init(_ image: CGImage) {
        let size = max(image.width, image.height)
        self.init(size: size)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        for i in 0..<(size * size) {
            let a = Double(bytes[i * 4 + 3]) / 255
            guard a > 0 else { continue }
            pixels[i] = (Double(bytes[i * 4]) / 255 / a, Double(bytes[i * 4 + 1]) / 255 / a, Double(bytes[i * 4 + 2]) / 255 / a, a)
        }
    }

    func image() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for (i, p) in pixels.enumerated() {
            let a = min(1, max(0, p.a))
            bytes[i * 4] = UInt8((min(1, max(0, p.r)) * a * 255).rounded())
            bytes[i * 4 + 1] = UInt8((min(1, max(0, p.g)) * a * 255).rounded())
            bytes[i * 4 + 2] = UInt8((min(1, max(0, p.b)) * a * 255).rounded())
            bytes[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func get(_ x: Int, _ y: Int) -> Pixel { pixels[y * size + x] }
    mutating func set(_ x: Int, _ y: Int, _ p: Pixel) { pixels[y * size + x] = p }

    /// Changes colour, keeping transparency.
    mutating func map(_ transform: (IconEffects.RGB) -> IconEffects.RGB) {
        for i in pixels.indices where pixels[i].a > 0 {
            let c = transform((pixels[i].r, pixels[i].g, pixels[i].b))
            pixels[i] = (c.r, c.g, c.b, pixels[i].a)
        }
    }

    mutating func mapAll(_ transform: (Pixel) -> Pixel) {
        for i in pixels.indices { pixels[i] = transform(pixels[i]) }
    }

    /// Averages blocks of pixels into a `grid` × `grid` image.
    func downsampled(to grid: Int) -> Bitmap {
        var out = Bitmap(size: grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                let x0 = gx * size / grid, x1 = max(x0 + 1, (gx + 1) * size / grid)
                let y0 = gy * size / grid, y1 = max(y0 + 1, (gy + 1) * size / grid)
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0, n = 0.0
                for y in y0..<min(y1, size) {
                    for x in x0..<min(x1, size) {
                        let p = pixels[y * size + x]
                        r += p.r * p.a; g += p.g * p.a; b += p.b * p.a; a += p.a; n += 1
                    }
                }
                out.pixels[gy * grid + gx] = a > 0 ? (r / a, g / a, b / a, a / n) : (0, 0, 0, 0)
            }
        }
        return out
    }

    /// Blows the image back up with hard, square pixels.
    func upscaled(to target: Int) -> Bitmap {
        var out = Bitmap(size: target)
        for y in 0..<target {
            for x in 0..<target {
                out.pixels[y * target + x] = pixels[(y * size / target) * size + (x * size / target)]
            }
        }
        return out
    }

    /// Shrinks the picture towards the centre, leaving a transparent margin.
    func scaledCentered(by factor: Double) -> Bitmap {
        var out = Bitmap(size: size)
        let offset = Double(size) * (1 - factor) / 2
        for y in 0..<size {
            for x in 0..<size {
                let sx = Int((Double(x) - offset) / factor), sy = Int((Double(y) - offset) / factor)
                guard sx >= 0, sy >= 0, sx < size, sy < size else { continue }
                out.pixels[y * size + x] = pixels[sy * size + sx]
            }
        }
        return out
    }

    func alphaMask(threshold: Double) -> [Bool] { pixels.map { $0.a > threshold } }

    /// Whether an inside pixel touches the outside within `radius`.
    func isEdge(_ x: Int, _ y: Int, mask: [Bool], radius: Int = 1) -> Bool {
        for dy in -radius...radius {
            for dx in -radius...radius {
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= size || ny >= size || !mask[ny * size + nx] { return true }
            }
        }
        return false
    }

    /// Whether an outside pixel is within `radius` of the inside.
    func isNear(_ x: Int, _ y: Int, mask: [Bool], radius: Int) -> Bool {
        for dy in -radius...radius {
            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < size, ny < size, mask[ny * size + nx] { return true }
            }
        }
        return false
    }
}
