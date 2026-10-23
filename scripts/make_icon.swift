// Renders Resources/AppIcon.icns: a rounded square with a deep blue→violet
// gradient, three lyric "lines" (the middle one lit, karaoke-style) and a note.
// Usage: swift scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~10% margin
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.35, alpha: 1),
                        NSColor(red: 0.42, green: 0.20, blue: 0.62, alpha: 1)])!
        .draw(in: shape, angle: -60)

    // Lyric lines: dim, lit (half filled), dim
    func bar(_ y: CGFloat, _ w: CGFloat, _ color: NSColor) {
        let r = NSRect(x: body.minX + body.width * 0.16, y: body.minY + body.height * y,
                       width: body.width * w, height: body.height * 0.075)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
    bar(0.66, 0.50, .white.withAlphaComponent(0.35))
    bar(0.46, 0.68, .white.withAlphaComponent(0.35))
    bar(0.46, 0.40, NSColor(red: 0.65, green: 0.88, blue: 1.0, alpha: 1))
    bar(0.26, 0.44, .white.withAlphaComponent(0.35))

    // Note glyph, bottom right
    let note = NSAttributedString(string: "♪", attributes: [
        .font: NSFont.systemFont(ofSize: body.height * 0.34, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let ns = note.size()
    note.draw(at: NSPoint(x: body.maxX - ns.width - body.width * 0.1, y: body.minY + body.height * 0.06))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
try! render(512).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
print(out.path)
