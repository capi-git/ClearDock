import AppKit
import ScreenCaptureKit

/// Colours taken from the wallpaper that's actually showing, so the dock can match it. It looks at
/// the screen with every window left out, which also works with live-wallpaper apps. Only runs
/// when a setting uses wallpaper colours, and only when the wallpaper or desktop changes.
@MainActor
final class WallpaperPalette {
    static let shared = WallpaperPalette()
    static let didChange = Notification.Name("ClearDockWallpaperPaletteChanged")

    /// A calm colour from along the bottom of the wallpaper, for backgrounds.
    private(set) var base = NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1)
    /// A calm colour from along the top of the wallpaper, for the top bar.
    private(set) var top = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.20, alpha: 1)
    /// The wallpaper's most colourful tone, for markers and icon tints.
    var accent: NSColor { accents.first ?? Self.fallbackAccent }
    /// Its strongest colours, most prominent first (up to four), for choosing a highlight.
    private(set) var accents: [NSColor] = [fallbackAccent]

    private static let fallbackAccent = NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1)

    private var task: Task<Void, Never>?
    private var lastLooked: Date?
    /// What each desktop's wallpaper looked like, and when: going back to a desktop seen in the last
    /// ten minutes uses that, rather than taking a picture of the screen again.
    private var seen: [UInt64: (colors: (base: NSColor, top: NSColor, accents: [NSColor]), file: URL?, at: Date)] = [:]

    /// Looks at the wallpaper again, a moment after the last time it's asked: desktop switches in a
    /// row, and the dock and the bar asking together, make one look, taken once a switch has
    /// finished rather than in the middle of its animation. `unlessRecent` skips it when it looked
    /// in the last half minute, for changes (like settings) that can't have changed the wallpaper.
    func refresh(for screen: NSScreen?, unlessRecent: Bool = false) {
        guard let screen else { return }
        if unlessRecent, let lastLooked, Date().timeIntervalSince(lastLooked) < 30 { return }
        task?.cancel()
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let size = CGSize(width: 96, height: max(24, (96 * screen.frame.height / screen.frame.width).rounded()))
        let file = NSWorkspace.shared.desktopImageURL(for: screen)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            let desktop = WindowSpaces.currentSpaceID(on: screen)
            if !unlessRecent, let desktop, let kept = self?.seen[desktop], kept.file == file, Date().timeIntervalSince(kept.at) < 600 {
                self?.use(kept.colors)
                return
            }
            guard let image = await Self.wallpaperImage(display: displayID, size: size, file: file) else { return }
            self?.lastLooked = Date()
            guard let self, !Task.isCancelled, let colors = Self.colors(in: image) else { return }
            if let desktop { self.seen[desktop] = (colors, file, Date()) }
            self.use(colors)
        }
    }

    private func use(_ colors: (base: NSColor, top: NSColor, accents: [NSColor])) {
        // A live wallpaper (from an app like Wallspace) looks a little different each time it's
        // looked at; only a real change of wallpaper should change the colours.
        if Self.near(colors.base, base) && Self.near(colors.top, top)
            && colors.accents.count == accents.count
            && zip(colors.accents, accents).allSatisfy({ Self.near($0, $1) }) { return }
        base = colors.base
        top = colors.top
        accents = colors.accents
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Whether two colours look about the same.
    private static func near(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        let dr = a.redComponent - b.redComponent, dg = a.greenComponent - b.greenComponent, db = a.blueComponent - b.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot() < 0.12
    }

    /// A small picture of the desktop with no windows on it, made away from the main thread.
    nonisolated private static func wallpaperImage(display displayID: CGDirectDisplayID?, size: CGSize, file: URL?) async -> CGImage? {
        if CGPreflightScreenCaptureAccess(),
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first {
            // Leave out every ordinary window (and anything above them), keeping the wallpaper.
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowLayer >= 0 })
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                return image
            }
        }
        // Without Screen Recording permission, fall back to the wallpaper picture file, read at the
        // small size it's needed at (wallpapers can be 6K pictures).
        guard let file, let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
        ] as CFDictionary)
    }

    static func colors(in image: CGImage) -> (base: NSColor, top: NSColor, accents: [NSColor])? {
        let width = 48, height = max(12, image.height * 48 / max(image.width, 1))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Base: the average of the bottom fifth, where the dock sits (rows are stored top first).
        // Top: the same along the top fifth, where the top bar sits.
        var sum = (r: 0.0, g: 0.0, b: 0.0), count = 0.0
        var topSum = (r: 0.0, g: 0.0, b: 0.0), topCount = 0.0
        let stripRows = max(1, height / 5)
        // Accent: group pixels by hue, weighting colourful, bright ones, and take the strongest group.
        var bins = Array(repeating: (weight: 0.0, r: 0.0, g: 0.0, b: 0.0), count: 12)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                if y >= height - stripRows { sum.r += r; sum.g += g; sum.b += b; count += 1 }
                if y < stripRows { topSum.r += r; topSum.g += g; topSum.b += b; topCount += 1 }
                let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                let s = Double(color.saturationComponent), v = Double(color.brightnessComponent)
                let weight = s * s * v
                guard weight > 0.02 else { continue }
                let bin = min(11, Int(Double(color.hueComponent) * 12))
                bins[bin].weight += weight
                bins[bin].r += r * weight; bins[bin].g += g * weight; bins[bin].b += b * weight
            }
        }
        guard count > 0, topCount > 0 else { return nil }
        let base = NSColor(srgbRed: sum.r / count, green: sum.g / count, blue: sum.b / count, alpha: 1)
        let top = NSColor(srgbRed: topSum.r / topCount, green: topSum.g / topCount, blue: topSum.b / topCount, alpha: 1)

        // The strongest hue groups, each made to read clearly as a colour against the desktop.
        var accents: [NSColor] = []
        for group in bins.sorted(by: { $0.weight > $1.weight }) where group.weight > 0 && accents.count < 4 {
            let raw = NSColor(srgbRed: group.r / group.weight, green: group.g / group.weight, blue: group.b / group.weight, alpha: 1)
            let color = NSColor(hue: raw.hueComponent, saturation: max(raw.saturationComponent, 0.5),
                                brightness: max(raw.brightnessComponent, 0.85), alpha: 1)
            if !accents.contains(where: { $0.hexString == color.hexString }) { accents.append(color) }
        }
        return (base, top, accents.isEmpty ? [fallbackAccent] : accents)
    }
}
