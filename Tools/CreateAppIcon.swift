import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon-1024.png")
let canvasSize = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("無法建立圖示畫布")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("無法建立繪圖環境")
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

let tileRect = NSRect(x: 66, y: 66, width: 892, height: 892)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 214, yRadius: 214)

// 柔和陰影只增加與 Dock 的分離感，不形成方形底色。
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
tile.fill()
NSShadow().set()

NSGradient(colors: [
    NSColor(calibratedWhite: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.067, alpha: 1)
])?.draw(in: tile, angle: -90)

// 液態玻璃感：上緣柔光、外框冷色折射與細微內框。
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let gloss = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.13),
    NSColor.white.withAlphaComponent(0.025),
    NSColor.clear
])
gloss?.draw(
    in: NSRect(x: tileRect.minX, y: tileRect.midY, width: tileRect.width, height: tileRect.height / 2),
    angle: -90
)
NSGraphicsContext.restoreGraphicsState()

NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.69, alpha: 0.38).setStroke()
tile.lineWidth = 7
tile.stroke()

let innerEdge = NSBezierPath(
    roundedRect: tileRect.insetBy(dx: 9, dy: 9),
    xRadius: 205,
    yRadius: 205
)
NSColor.white.withAlphaComponent(0.10).setStroke()
innerEdge.lineWidth = 3
innerEdge.stroke()

let moon = NSBezierPath(ovalIn: NSRect(x: 668, y: 644, width: 144, height: 144))
NSGradient(colors: [
    NSColor(calibratedRed: 0.66, green: 0.90, blue: 0.89, alpha: 1),
    NSColor(calibratedRed: 0.40, green: 0.72, blue: 0.74, alpha: 1)
])?.draw(in: moon, angle: -60)
NSColor.white.withAlphaComponent(0.20).setStroke()
moon.lineWidth = 3
moon.stroke()

func mountainPath(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else { return path }
    path.move(to: first)
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    return path
}

let rearMountain = mountainPath([
    NSPoint(x: 156, y: 310),
    NSPoint(x: 410, y: 670),
    NSPoint(x: 544, y: 490),
    NSPoint(x: 664, y: 628),
    NSPoint(x: 880, y: 310)
])
NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.65, blue: 0.70, alpha: 1),
    NSColor(calibratedRed: 0.17, green: 0.32, blue: 0.37, alpha: 1)
])?.draw(in: rearMountain, angle: -90)
NSColor.white.withAlphaComponent(0.12).setStroke()
rearMountain.lineWidth = 3
rearMountain.stroke()

let frontMountain = mountainPath([
    NSPoint(x: 124, y: 260),
    NSPoint(x: 348, y: 568),
    NSPoint(x: 456, y: 444),
    NSPoint(x: 572, y: 584),
    NSPoint(x: 900, y: 260)
])
NSGradient(colors: [
    NSColor(calibratedWhite: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.76, alpha: 1)
])?.draw(in: frontMountain, angle: -90)
NSColor.white.withAlphaComponent(0.26).setStroke()
frontMountain.lineWidth = 3
frontMountain.stroke()

let lake = NSBezierPath(
    roundedRect: NSRect(x: 184, y: 188, width: 656, height: 28),
    xRadius: 14,
    yRadius: 14
)
NSGradient(colors: [
    NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.87, alpha: 0.82),
    NSColor(calibratedRed: 0.22, green: 0.63, blue: 0.67, alpha: 0.82)
])?.draw(in: lake, angle: 0)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("無法輸出 PNG")
}
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
