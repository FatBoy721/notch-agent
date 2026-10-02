// Renders the app icon (a dark tile with a notch and Claude's orange ✳)
// and packs it into AppIcon.icns. Usage: swift scripts/make-icon.swift <out-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: an 824pt body inset 100pt, corner radius ~185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSShadow().apply { $0.shadowColor = .black.withAlphaComponent(0.35); $0.shadowBlurRadius = 24; $0.shadowOffset = NSSize(width: 0, height: -10) }
    NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!.draw(in: tile, angle: -90)
    NSShadow().apply { $0.shadowColor = nil }

    // The notch, hanging from the top edge of the tile.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let notch = NSRect(x: 512 - 170, y: 924 - 120, width: 340, height: 140)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: notch, xRadius: 60, yRadius: 60).fill()
    NSRect(x: notch.minX, y: notch.midY, width: notch.width, height: notch.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Claude's ✳ in terracotta with a soft glow: eight rounded spokes.
    let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    let center = NSPoint(x: 512, y: 450), radius: CGFloat = 230
    let spokes = NSBezierPath()
    for index in 0..<4 {
        let angle = CGFloat(index) * .pi / 4 + .pi / 2
        spokes.move(to: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        spokes.line(to: NSPoint(x: center.x - cos(angle) * radius, y: center.y - sin(angle) * radius))
    }
    spokes.lineWidth = 78
    spokes.lineCapStyle = .round
    NSShadow().apply { $0.shadowColor = orange.withAlphaComponent(0.6); $0.shadowBlurRadius = 46; $0.shadowOffset = .zero }
    orange.setStroke()
    spokes.stroke()
    return true
}

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) { configure(self); set() }
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
