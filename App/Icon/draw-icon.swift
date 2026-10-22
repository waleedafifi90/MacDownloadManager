// Draws the app icon at 1024×1024 in the macOS icon grid (an 824 pt rounded square with
// a soft shadow). Usage: swift draw-icon.swift <blue|dark|green> <output.png>
import AppKit

let style = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A bold download arrow centred at (cx, cy): shaft plus head, with rounded joins.
func arrow(cx: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat) -> NSBezierPath {
    let shaft = width * 0.34, head = width, headHeight = height * 0.46
    let top = cy + height / 2, bottom = cy - height / 2, neck = bottom + headHeight
    let path = NSBezierPath()
    path.move(to: CGPoint(x: cx - shaft / 2, y: top))
    path.line(to: CGPoint(x: cx + shaft / 2, y: top))
    path.line(to: CGPoint(x: cx + shaft / 2, y: neck))
    path.line(to: CGPoint(x: cx + head / 2, y: neck))
    path.line(to: CGPoint(x: cx, y: bottom))
    path.line(to: CGPoint(x: cx - head / 2, y: neck))
    path.line(to: CGPoint(x: cx - shaft / 2, y: neck))
    path.close()
    path.lineJoinStyle = .round
    path.lineWidth = 34
    return path
}

func fillTile(_ top: NSColor, _ bottom: NSColor) {
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = CGSize(width: 0, height: -12)
    shadow.set()
    top.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)
    // A faint top highlight, as on Apple's icons.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

func drawWhiteArrow(cx: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat) {
    let path = arrow(cx: cx, cy: cy, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = CGSize(width: 0, height: -6)
    shadow.set()
    // One layer, so the shadow falls once around the whole arrow (not inside it too).
    let context = NSGraphicsContext.current!.cgContext
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setFill()
    NSColor.white.setStroke()
    path.fill()
    path.stroke()
    context.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high

switch style {
case "blue":
    // Arrow above three parallel bars: one file, several parts downloading together.
    fillTile(color(0x3D8BFF), color(0x0B4FD6))
    drawWhiteArrow(cx: 512, cy: 600, width: 400, height: 380)
    let bars: [(CGFloat, CGFloat)] = [(0.92, 1), (0.62, 0.85), (0.80, 0.7)]
    for (index, bar) in bars.enumerated() {
        let y = 300 - CGFloat(index) * 62
        let full = CGRect(x: 262, y: y, width: 500, height: 36)
        color(0xFFFFFF, 0.22).setFill()
        NSBezierPath(roundedRect: full, xRadius: 18, yRadius: 18).fill()
        color(0xFFFFFF, bar.1).setFill()
        NSBezierPath(roundedRect: CGRect(x: full.minX, y: y, width: full.width * bar.0, height: 36),
                     xRadius: 18, yRadius: 18).fill()
    }
case "dark":
    // A ring of segments, like the connection bar in the progress window.
    fillTile(color(0x2B2F3A), color(0x12141A))
    let center = CGPoint(x: 512, y: 512), ringRadius: CGFloat = 270
    let colors = [color(0x3D8BFF), color(0x34C759), color(0x5AC8FA), color(0xAF7CFF)]
    let gap: CGFloat = 9
    for i in 0..<4 {
        let start = 90 - CGFloat(i) * 90 - gap, end = 90 - CGFloat(i + 1) * 90 + gap
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: ringRadius, startAngle: start, endAngle: end, clockwise: true)
        arc.lineWidth = 58
        arc.lineCapStyle = .round
        colors[i].setStroke()
        arc.stroke()
    }
    drawWhiteArrow(cx: 512, cy: 512, width: 270, height: 290)
default:
    // Arrow with speed lines.
    fillTile(color(0x2FD08A), color(0x0E8F6E))
    drawWhiteArrow(cx: 560, cy: 500, width: 380, height: 420)
    for (i, length) in [CGFloat(150), 210, 150].enumerated() {
        let y = 610 - CGFloat(i) * 110
        color(0xFFFFFF, 0.75 - CGFloat(i) * 0.15).setFill()
        NSBezierPath(roundedRect: CGRect(x: 330 - length, y: y, width: length, height: 34), xRadius: 17, yRadius: 17).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
