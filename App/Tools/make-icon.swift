import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// Background: deep navy to electric blue, top-left to bottom-right.
let background = CGGradient(colorsSpace: space, colors: [color(18, 22, 58), color(36, 78, 214), color(64, 170, 255)] as CFArray,
                            locations: [0, 0.6, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

// Soft glow behind the display.
let glow = CGGradient(colorsSpace: space, colors: [color(140, 200, 255, 0.45), color(140, 200, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 520, options: [])

// Display: white bezel, dark screen, stand.
let bezel = CGRect(x: 172, y: 372, width: 680, height: 452)
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: color(5, 10, 40, 0.5))
ctx.setFillColor(color(255, 255, 255))
ctx.addPath(CGPath(roundedRect: bezel, cornerWidth: 54, cornerHeight: 54, transform: nil))
ctx.fillPath()
// Stand
ctx.addPath(CGPath(roundedRect: CGRect(x: 462, y: 262, width: 100, height: 130), cornerWidth: 10, cornerHeight: 10, transform: nil))
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: CGRect(x: 352, y: 232, width: 320, height: 46), cornerWidth: 23, cornerHeight: 23, transform: nil))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

let screen = bezel.insetBy(dx: 30, dy: 30)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 28, cornerHeight: 28, transform: nil))
ctx.clip()
let screenFill = CGGradient(colorsSpace: space, colors: [color(22, 30, 84), color(48, 110, 235)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(screenFill, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
// Speed streaks: the "high performance" hint.
ctx.setLineCap(.round)
for (y, x0, x1, alpha) in [(690.0, 250.0, 470.0, 0.55), (630.0, 250.0, 390.0, 0.4), (570.0, 250.0, 330.0, 0.28)] {
    ctx.setStrokeColor(color(255, 255, 255, alpha))
    ctx.setLineWidth(26)
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
}
ctx.restoreGState()

// Pointer arrow, overlapping the lower right of the screen.
let tip = CGPoint(x: 560, y: 640)
let s: CGFloat = 3.5
let arrow = CGMutablePath()
let points: [(CGFloat, CGFloat)] = [(0, 0), (0, -84), (20, -66), (35, -100), (50, -93), (35, -60), (62, -60)]
arrow.move(to: CGPoint(x: tip.x + points[0].0 * s, y: tip.y + points[0].1 * s))
for p in points.dropFirst() { arrow.addLine(to: CGPoint(x: tip.x + p.0 * s, y: tip.y + p.1 * s)) }
arrow.closeSubpath()
ctx.setLineJoin(.round)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 5, 40, 0.55))
ctx.addPath(arrow); ctx.setFillColor(color(255, 255, 255)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(arrow); ctx.setStrokeColor(color(255, 255, 255)); ctx.setLineWidth(34); ctx.strokePath()
ctx.addPath(arrow); ctx.setFillColor(color(16, 22, 64)); ctx.fillPath()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
