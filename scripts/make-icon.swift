import AppKit
import Foundation
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.20, blue: 0.23, alpha: 1), ending: NSColor(srgbRed: 0.035, green: 0.06, blue: 0.075, alpha: 1))!.draw(in: background, angle: -90)
let mint = NSColor(srgbRed: 0.47, green: 0.89, blue: 0.73, alpha: 1)
for (y, alpha) in [(325.0, 0.25), (440.0, 0.5), (555.0, 1.0)] {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 245, y: y)); p.line(to: NSPoint(x: 512, y: y - 140)); p.line(to: NSPoint(x: 779, y: y))
    p.lineWidth = 48; p.lineCapStyle = .round; p.lineJoinStyle = .round
    mint.withAlphaComponent(alpha).setStroke(); p.stroke()
}
let top = NSBezierPath()
top.move(to: NSPoint(x: 245, y: 585)); top.line(to: NSPoint(x: 512, y: 735)); top.line(to: NSPoint(x: 779, y: 585))
top.lineWidth = 48; top.lineCapStyle = .round; top.lineJoinStyle = .round; mint.setStroke(); top.stroke()
image.unlockFocus()
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
    }
}
