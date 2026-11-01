import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.45, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.22, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
// Treemap tiles
let m: CGFloat = 170, g: CGFloat = 16
let area = CGRect(x: m, y: m, width: size - 2 * m, height: size - 2 * m)
func c(_ h: CGFloat, _ s: CGFloat = 0.62, _ b: CGFloat = 0.95) -> CGColor { NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1).cgColor }
let w1 = area.width * 0.56, h2 = area.height * 0.58
let tiles: [(CGRect, CGColor)] = [
    (CGRect(x: area.minX, y: area.minY, width: w1 - g / 2, height: area.height), c(0.58)),
    (CGRect(x: area.minX + w1 + g / 2, y: area.maxY - h2, width: area.width - w1 - g / 2, height: h2), c(0.08)),
    (CGRect(x: area.minX + w1 + g / 2, y: area.minY, width: (area.width - w1) * 0.55 - g, height: area.height - h2 - g), c(0.38, 0.55, 0.85)),
    (CGRect(x: area.minX + w1 + (area.width - w1) * 0.55, y: area.minY + (area.height - h2 - g) * 0.5 + g / 2, width: (area.width - w1) * 0.45, height: (area.height - h2 - g) * 0.5 - g / 2), c(0.83, 0.45, 0.95)),
    (CGRect(x: area.minX + w1 + (area.width - w1) * 0.55, y: area.minY, width: (area.width - w1) * 0.45, height: (area.height - h2 - g) * 0.5 - g / 2), c(0.13, 0.7, 1.0)),
]
for (r, col) in tiles {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(col); ctx.fillPath()
}
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
