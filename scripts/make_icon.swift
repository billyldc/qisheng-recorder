import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.19, yRadius: p * 0.19).fill()
        NSColor(calibratedRed: 0.28, green: 0.82, blue: 0.73, alpha: 1).setStroke()
        let left = NSBezierPath(roundedRect: NSRect(x: p * 0.2, y: p * 0.26, width: p * 0.36, height: p * 0.5), xRadius: p * 0.04, yRadius: p * 0.04)
        left.lineWidth = p * 0.035
        left.stroke()
        NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.37, y: p * 0.21, width: p * 0.41, height: p * 0.52), xRadius: p * 0.04, yRadius: p * 0.04).fill()
        NSColor(calibratedRed: 0.86, green: 0.20, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: p * 0.45, y: p * 0.35, width: p * 0.25, height: p * 0.25)).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
