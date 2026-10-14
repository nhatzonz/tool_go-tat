// Vẽ logo Gõ Tắt ra PNG 1024×1024.
// Dùng: swift icon/make_icon.swift <đường-dẫn-png>
import Cocoa

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Nền: khung bo góc theo lưới icon macOS (824×824, cách mép 100)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35).cgColor)
rgb(0x0E8F7E).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [rgb(0x34CDB4), rgb(0x0E8F7E), rgb(0x07584E)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// Ánh sáng nhẹ phía trên
NSGradient(colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)])!
    .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()

// Phím bàn phím
let cap = CGRect(x: 262, y: 262, width: 500, height: 480)
let edge = NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -34), xRadius: 96, yRadius: 96)
let face = NSBezierPath(roundedRect: cap, xRadius: 96, yRadius: 96)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 40, color: rgb(0x032E28, 0.55).cgColor)
rgb(0xB9CFCA).setFill()
edge.fill()
ctx.restoreGState()

ctx.saveGState()
face.addClip()
NSGradient(colors: [rgb(0xFFFFFF), rgb(0xE6EFED)])!.draw(in: cap, angle: -90)
ctx.restoreGState()
rgb(0xFFFFFF, 0.9).setStroke()
let rim = NSBezierPath(roundedRect: cap.insetBy(dx: 3, dy: 3), xRadius: 93, yRadius: 93)
rim.lineWidth = 6
rim.stroke()

func rounded(_ pt: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: pt, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: pt) ?? base
}

func draw(_ text: String, font: NSFont, color: NSColor, center: CGPoint) {
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let b = attr.boundingRect(with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
    attr.draw(at: CGPoint(x: center.x - b.midX, y: center.y - b.midY))
}

// Ký hiệu ⌃ ở góc trên trái như phím thật
draw("⌃", font: rounded(92, .bold), color: rgb(0x7F9894), center: CGPoint(x: cap.minX + 92, y: cap.maxY - 88))
// Chữ chính
draw("Gõ", font: rounded(250, .heavy), color: rgb(0x0B5F54), center: CGPoint(x: cap.midX, y: cap.midY - 34))

// Tia sét "nhanh" ở góc trên phải
let bolt = NSBezierPath()
let o = CGPoint(x: 722, y: 690), k: CGFloat = 0.8
let pts: [CGPoint] = [(60, 200), (-30, 60), (22, 60), (-40, -90), (70, 70), (16, 70), (60, 200)]
    .map { CGPoint(x: o.x + $0.0 * k, y: o.y + $0.1 * k) }
bolt.move(to: pts[0]); pts.dropFirst().forEach { bolt.line(to: $0) }; bolt.close()
bolt.lineJoinStyle = .round
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: rgb(0x5A3A00, 0.45).cgColor)
rgb(0xFFFFFF).setStroke(); bolt.lineWidth = 22; bolt.stroke()
rgb(0xFFC23D).setFill(); bolt.fill()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Đã vẽ \(out)")
