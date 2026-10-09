// Builds AppIcon.icns from the brand logo (packaging/brand/notch-agent.png,
// the same one Settings shows): the white square around its dark tile is
// made transparent, then the tile is fitted to the macOS icon grid with a
// soft shadow. Usage: swift scripts/make-icon.swift <out-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let logoPath = "packaging/brand/notch-agent.png"
let size: CGFloat = 1024

guard let source = NSImage(contentsOfFile: logoPath).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }) else {
    fatalError("Can't read \(logoPath)")
}
let width = source.width, height = source.height

// RGBA pixels of the logo, so the backdrop can be cut away.
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

func brightness(_ index: Int) -> Double {
    (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 765
}

// The tile's own color, sampled just inside its left edge halfway down.
let tileIndex = ((height / 2) * width + width / 8) * 4
let tile = (pixels[tileIndex], pixels[tileIndex + 1], pixels[tileIndex + 2])
let tileBrightness = brightness(tileIndex)

// Flood from the corners through everything lighter than the tile: that's
// the backdrop (the white N inside is walled off by the dark tile). Edge
// pixels become the tile's color at the coverage their grey implies, so
// the rounded corners stay smooth.
var visited = [Bool](repeating: false, count: width * height)
var stack = [0, width - 1, (height - 1) * width, height * width - 1]
var minX = width, minY = height, maxX = 0, maxY = 0
while let point = stack.popLast() {
    guard !visited[point] else { continue }
    visited[point] = true
    let index = point * 4
    let value = brightness(index)
    guard value > tileBrightness + 0.06 else { continue }
    let coverage = max(0, min(1, (1 - value) / (1 - tileBrightness)))
    let alpha = UInt8((coverage * 255).rounded())
    // Premultiplied.
    pixels[index] = UInt8(Double(tile.0) * coverage)
    pixels[index + 1] = UInt8(Double(tile.1) * coverage)
    pixels[index + 2] = UInt8(Double(tile.2) * coverage)
    pixels[index + 3] = alpha
    let x = point % width, y = point / width
    if x > 0 { stack.append(point - 1) }
    if x < width - 1 { stack.append(point + 1) }
    if y > 0 { stack.append(point - width) }
    if y < height - 1 { stack.append(point + width) }
}
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let cutout = context.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: an 824pt body inset 100pt.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSShadow().apply { $0.shadowColor = .black.withAlphaComponent(0.35); $0.shadowBlurRadius = 24; $0.shadowOffset = NSSize(width: 0, height: -10) }
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: cutout, size: body.size).draw(in: body)
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
