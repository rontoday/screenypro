// Renders Resources/AppIcon.icns: Comakers wordmark and a record dot on the Orchid gradient.
// Usage: swift scripts/make-icon.swift   (run from the project root)
import AppKit

let logoURL = URL(fileURLWithPath: "Resources/comakers-logo-white.png")
guard let logo = NSImage(contentsOf: logoURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("missing \(logoURL.path)")
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt squircle centered in 1024, soft shadow below.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.16, blue: 0.62, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    func c(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    let base = CGGradient(colorsSpace: space, colors: [c(0x3B1D8F), c(0x8E3FD1), c(0xE58AD8)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.97, green: 0.66, blue: 0.88, alpha: 0.55), CGColor(srgbRed: 0.97, green: 0.66, blue: 0.88, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 860, y: 330), startRadius: 0, endCenter: CGPoint(x: 860, y: 330), endRadius: 520, options: [])
    // Top highlight.
    let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 300), options: [])
    ctx.restoreGState()

    // Record mark: white ring with a red dot.
    let center = CGPoint(x: 512, y: 610)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: CGColor(gray: 0, alpha: 0.28))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(26)
    ctx.strokeEllipse(in: CGRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 96, y: center.y - 96, width: 192, height: 192))
    ctx.restoreGState()

    // Wordmark.
    let w: CGFloat = 600
    let h = w * CGFloat(logo.height) / CGFloat(logo.width)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4 * s), blur: 12 * s, color: CGColor(gray: 0, alpha: 0.25))
    ctx.draw(logo, in: CGRect(x: 512 - w / 2, y: 250, width: w, height: h))
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(512).write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/null"))
print("wrote Resources/AppIcon.icns")
