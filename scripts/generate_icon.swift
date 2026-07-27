import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/AppIcon-Source.png")
let image = NSImage(size: NSSize(width: 1024, height: 1024))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

func fill(_ path: NSBezierPath, color: NSColor) {
    color.setFill()
    path.fill()
}

func drawShadow(color: NSColor, blur: CGFloat, offset: NSSize, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// Style reference:
// A quiet Apple-like icon with a neutral gray rounded-square base,
// a smaller white rounded tile, and one simple monochrome remote-desktop glyph.
// No color accents, no busy routing shapes, and no circular "prohibited" motif.

let base = rounded(NSRect(x: 64, y: 64, width: 896, height: 896), radius: 205)
NSGradient(colors: [
    color(0xd9dad8),
    color(0xc7c9c7)
])?.draw(in: base, angle: 300)

stroke(base, color: color(0xffffff, alpha: 0.35), width: 7)

let tileRect = NSRect(x: 244, y: 244, width: 536, height: 536)
let tile = rounded(tileRect, radius: 118)
drawShadow(color: color(0x000000, alpha: 0.18), blur: 28, offset: NSSize(width: 0, height: -10)) {
    fill(tile, color: color(0xf8f8f6))
}
stroke(tile, color: color(0xe7e7e4), width: 5)

let ink = color(0x282929)

// Minimal remote desktop glyph: a rounded display outline and a small
// pointer entering the screen. It reads clearly at Finder and menu-bar sizes.
let screen = rounded(NSRect(x: 352, y: 420, width: 320, height: 228), radius: 42)
stroke(screen, color: ink, width: 24)

let stand = NSBezierPath()
stand.move(to: NSPoint(x: 512, y: 420))
stand.line(to: NSPoint(x: 512, y: 370))
stand.move(to: NSPoint(x: 452, y: 370))
stand.line(to: NSPoint(x: 572, y: 370))
stroke(stand, color: ink, width: 22)

let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 438, y: 594))
cursor.line(to: NSPoint(x: 438, y: 438))
cursor.line(to: NSPoint(x: 482, y: 486))
cursor.line(to: NSPoint(x: 512, y: 420))
cursor.line(to: NSPoint(x: 548, y: 438))
cursor.line(to: NSPoint(x: 518, y: 502))
cursor.line(to: NSPoint(x: 594, y: 502))
cursor.close()
fill(cursor, color: ink)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}

try png.write(to: output, options: [.atomic])
print("Generated icon source: \(output.path)")
