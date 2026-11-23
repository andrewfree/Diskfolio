import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let files = FileManager.default
let build = root.appendingPathComponent("build", isDirectory: true)
let work = build.appendingPathComponent("icon-\(UUID().uuidString)", isDirectory: true)
let iconset = work.appendingPathComponent("Diskfolio.iconset", isDirectory: true)
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: work) }

func writeIcon(pixels: Int, to output: URL) throws {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let factor = CGFloat(pixels) / 96
    context.scaleBy(x: factor, y: factor)
    func tile(_ rect: CGRect, radius: CGFloat, color: (CGFloat, CGFloat, CGFloat)) {
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }
    tile(CGRect(x: 6, y: 6, width: 84, height: 84), radius: 22, color: (0.17, 0.20, 0.28))
    tile(CGRect(x: 8, y: 8, width: 80, height: 80), radius: 20, color: (0.06, 0.08, 0.13))
    tile(CGRect(x: 21, y: 45, width: 28, height: 29), radius: 6, color: (0.70, 0.94, 0.82))
    tile(CGRect(x: 21, y: 22, width: 28, height: 20), radius: 6, color: (0.99, 0.67, 0.54))
    tile(CGRect(x: 52, y: 56, width: 23, height: 18), radius: 6, color: (0.76, 0.72, 0.95))
    tile(CGRect(x: 52, y: 22, width: 23, height: 31), radius: 6, color: (0.99, 0.84, 0.52))
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: output, options: .atomic)
}

for size in [16, 32, 128, 256, 512] {
    let icon = "icon_\(size)x\(size)"
    try writeIcon(pixels: size, to: iconset.appendingPathComponent("\(icon).png"))
    try writeIcon(pixels: size * 2, to: iconset.appendingPathComponent("\(icon)@2x.png"))
}
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["--convert", "icns", "--output", root.appendingPathComponent("Sources/Diskfolio.icns").path, iconset.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
try writeIcon(pixels: 96, to: root.appendingPathComponent("site/icon.png"))
