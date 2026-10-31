import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let source = root.appendingPathComponent("assets/hostshell-logo.svg")
guard let logo = NSImage(contentsOf: source) else { fatalError("Cannot load \(source.path)") }
let iosDir = root.appendingPathComponent("apps/ios/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let macDir = root.appendingPathComponent("apps/macos/Resources", isDirectory: true)
let iconset = macDir.appendingPathComponent("HostShell.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int, macOS: Bool, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    context.cgContext.clear(bounds)
    let artwork = macOS ? bounds.insetBy(dx: CGFloat(size) * 0.075, dy: CGFloat(size) * 0.075) : bounds
    if macOS {
        NSBezierPath(roundedRect: artwork, xRadius: CGFloat(size) * 0.19, yRadius: CGFloat(size) * 0.19).addClip()
    }
    logo.draw(in: artwork, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    if !macOS { bitmap.hasAlpha = false }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
    try png.write(to: url)
}

try render(size: 1024, macOS: false, to: iosDir.appendingPathComponent("AppIcon.png"))
let icons: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in icons {
    try render(size: size, macOS: true, to: iconset.appendingPathComponent(name))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", macDir.appendingPathComponent("HostShell.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
