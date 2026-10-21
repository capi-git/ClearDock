// Draws Clear Dock's app icon and writes Resources/AppIcon.icns.
// Run from the project folder: swift Icon/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func drawIcon(in context: CGContext) {
    // The standard macOS icon shape: an 824-point rounded square centred on the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor(white: 0, alpha: 0.3).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sky = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.53, green: 0.85, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.47, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // A soft sheen across the top.
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor(white: 1, alpha: 0.28).cgColor,
        NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])

    // A row of app icons with no dock bar behind them, and dots under the open ones.
    let size: CGFloat = 118, gap: CGFloat = 34, count = 4
    let rowWidth = CGFloat(count) * size + CGFloat(count - 1) * gap
    let rowY: CGFloat = 220
    for i in 0..<count {
        let x = body.midX - rowWidth / 2 + CGFloat(i) * (size + gap)
        let tile = CGPath(roundedRect: CGRect(x: x, y: rowY, width: size, height: size), cornerWidth: 28, cornerHeight: 28, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(white: 0, alpha: 0.25).cgColor)
        context.addPath(tile)
        context.setFillColor(NSColor(white: 1, alpha: 0.96).cgColor)
        context.fillPath()
        context.restoreGState()
        if i < 3 {
            context.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor)
            context.fillEllipse(in: CGRect(x: x + size / 2 - 9, y: rowY - 44, width: 18, height: 18))
        }
    }
    context.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(in: context)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Icon/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try fm.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
