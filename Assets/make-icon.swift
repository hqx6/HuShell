import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "HuShellIcon.png"
let canvas = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("无法创建图标画布")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

// A calm, deep teal shell: the panel remains legible in light, dark, and tinted Dock styles.
let silhouette = NSBezierPath(roundedRect: NSRect(x: 35, y: 35, width: 954, height: 954),
                            xRadius: 220, yRadius: 220)
NSGradient(starting: color(12, 46, 63), ending: color(29, 107, 119))!
    .draw(in: silhouette, angle: -45)

let panel = NSRect(x: 147, y: 225, width: 730, height: 582)
let panelPath = NSBezierPath(roundedRect: panel, xRadius: 109, yRadius: 109)
let shadow = NSShadow()
shadow.shadowColor = color(0, 13, 22, 0.42)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
color(8, 29, 43).setFill()
panelPath.fill()
NSShadow().set()
color(153, 225, 222, 0.20).setStroke()
panelPath.lineWidth = 8
panelPath.stroke()

// Minimal terminal chrome, without tiny text that would disappear at Dock sizes.
for (index, alpha) in [0.90, 0.42, 0.42].enumerated() {
    let dot = NSBezierPath(ovalIn: NSRect(x: 242 + index * 51, y: 716, width: 25, height: 25))
    color(133, 226, 208, alpha).setFill()
    dot.fill()
}

let ink = color(234, 249, 248)
rounded(NSRect(x: 253, y: 346, width: 72, height: 317), radius: 17, fill: ink)
rounded(NSRect(x: 459, y: 346, width: 72, height: 317), radius: 17, fill: ink)
rounded(NSRect(x: 315, y: 474, width: 156, height: 65), radius: 12, fill: ink)

// The mint prompt and cursor turn the H monogram into a terminal identity: H > _
let accent = color(113, 233, 198)
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 584, y: 568))
chevron.line(to: NSPoint(x: 663, y: 505))
chevron.line(to: NSPoint(x: 584, y: 442))
chevron.lineWidth = 43
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
accent.setStroke()
chevron.stroke()
rounded(NSRect(x: 679, y: 435, width: 96, height: 38), radius: 16, fill: accent)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法导出 PNG")
}
try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
