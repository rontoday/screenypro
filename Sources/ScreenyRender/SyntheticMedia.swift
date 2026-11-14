import AppKit
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ScreenyCore

/// Synthetic sources for the self-test and benchmarks: a fake app window, a fake camera, sine tones.
enum Synthetic {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool)
        return pool
    }

    /// Draws into a pooled BGRA buffer with a top-left-origin CG context.
    static func drawBuffer(pool: CVPixelBufferPool, _ draw: (CGContext, CGSize) -> Void) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        draw(ctx, CGSize(width: w, height: h))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        return buffer
    }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: sRGB,
            components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
        )!
    }

    /// Draws one line of text with its baseline at `y` (top-left-origin, flipped context).
    static func text(_ string: String, in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat,
                     weight: NSFont.Weight = .regular, mono: Bool = false, color: CGColor) {
        let font: CTFont = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
            : NSFont.systemFont(ofSize: size, weight: weight) as CTFont
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}

/// A fake retina app window (2940×1912) with text and moving colored blocks.
final class SyntheticScreen {
    enum Layout {
        /// Wide desktop window with a sidebar, in fixed pixels (designed for 2940×1912, fine down to ~2000 px wide).
        case desktop
        /// Narrow window or display area for a portrait canvas (any aspect ratio). Drawn on a 1000 px wide
        /// reference grid and scaled to the buffer width, so text has the same relative size at any resolution.
        case narrow
    }

    let width: Int
    let height: Int
    let layout: Layout
    private let pool: CVPixelBufferPool
    private let base: CGImage

    init(width: Int = 2940, height: Int = 1912, layout: Layout = .desktop) throws {
        self.width = width
        self.height = height
        self.layout = layout
        let drawn: CGImage? = layout == .desktop
            ? Self.drawBase(width: width, height: height)
            : Self.drawNarrowBase(width: width, height: height)
        guard let pool = Synthetic.makePool(width: width, height: height), let base = drawn
        else { throw SelfTestError("cannot create the synthetic screen source") }
        self.pool = pool
        self.base = base
    }

    /// - Parameters:
    ///   - t: seconds since the source started (drives the animation).
    ///   - marker: draws a large white sync marker (used by the A/V sync check).
    func frame(t: Double, time: CMTime, marker: Bool = false) -> VideoFrame? {
        let base = self.base
        let narrow = layout == .narrow
        let buffer = Synthetic.drawBuffer(pool: pool) { ctx, size in
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(base, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
            if narrow {
                Self.drawNarrowAnimation(ctx, size: size, t: t, marker: marker)
                return
            }

            // Animated chart area.
            let chart = CGRect(x: 520, y: 1180, width: size.width - 600, height: 560)
            let colors: [UInt32] = [0xFF5F57, 0x2F80ED, 0x27AE60]
            for (i, hex) in colors.enumerated() {
                let phase = t * (0.35 + 0.12 * Double(i)) + Double(i) * 0.33
                let u = 0.5 - 0.5 * cos(phase * 2 * .pi)
                let w: CGFloat = 300
                let x = chart.minX + 30 + CGFloat(u) * (chart.width - w - 60)
                let y = chart.minY + 40 + CGFloat(i) * 170
                let r = CGRect(x: x, y: y, width: w, height: 130)
                ctx.setFillColor(Synthetic.color(hex))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil))
                ctx.fillPath()
                Synthetic.text("Block \(i + 1)", in: ctx, x: r.minX + 28, y: r.midY + 12, size: 32, weight: .semibold,
                               color: Synthetic.color(0xFFFFFF))
            }
            let clock = String(format: "t = %06.3f s", t)
            Synthetic.text(clock, in: ctx, x: chart.minX + 30, y: chart.maxY - 24, size: 26, mono: true,
                           color: Synthetic.color(0x6E6E73))
            if marker {
                ctx.setFillColor(Synthetic.color(0xFFFFFF))
                ctx.fill(CGRect(x: 0, y: 104, width: 460, height: size.height - 104))
            }
        }
        guard let buffer else { return nil }
        return VideoFrame(pixelBuffer: buffer, contentRect: CGRect(x: 0, y: 0, width: width, height: height), time: time)
    }

    // MARK: Narrow layout (1000 px wide reference grid)

    static let narrowReferenceWidth: CGFloat = 1000

    /// Chart area of the narrow layout in reference units; it takes the space left under the table.
    private static func narrowChart(referenceHeight: CGFloat) -> CGRect {
        let top: CGFloat = 790
        let bottom = max(top + 150, referenceHeight - 36)
        return CGRect(x: 40, y: top, width: narrowReferenceWidth - 80, height: bottom - top)
    }

    private static func drawNarrowAnimation(_ ctx: CGContext, size: CGSize, t: Double, marker: Bool) {
        let s = size.width / narrowReferenceWidth
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: s, y: s)
        let chart = narrowChart(referenceHeight: size.height / s)
        let colors: [UInt32] = [0xFF5F57, 0x2F80ED, 0x27AE60]
        let gap: CGFloat = 14
        let blockHeight = min(120, (chart.height - 48 - 2 * gap) / 3)
        let stack = 3 * blockHeight + 2 * gap
        let top = chart.minY + (chart.height - stack) / 2
        for (i, hex) in colors.enumerated() {
            let phase = t * (0.35 + 0.12 * Double(i)) + Double(i) * 0.33
            let u = 0.5 - 0.5 * cos(phase * 2 * .pi)
            let w: CGFloat = 250
            let x = chart.minX + 24 + CGFloat(u) * (chart.width - w - 48)
            let r = CGRect(x: x, y: top + CGFloat(i) * (blockHeight + gap), width: w, height: blockHeight)
            ctx.setFillColor(Synthetic.color(hex))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.fillPath()
            let textSize = min(28, blockHeight * 0.42)
            Synthetic.text("Block \(i + 1)", in: ctx, x: r.minX + 24, y: r.midY + textSize * 0.36, size: textSize,
                           weight: .semibold, color: Synthetic.color(0xFFFFFF))
        }
        Synthetic.text(String(format: "t = %06.3f s", t), in: ctx, x: narrowReferenceWidth - 210, y: 47, size: 20, mono: true,
                       color: Synthetic.color(0x6E6E73))
        if marker {
            ctx.setFillColor(Synthetic.color(0xFFFFFF))
            ctx.fill(CGRect(x: 0, y: 76, width: 220, height: size.height / s - 76))
        }
    }

    private static func drawNarrowBase(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Synthetic.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let s = CGFloat(width) / narrowReferenceWidth
        let W = narrowReferenceWidth
        let H = CGFloat(height) / s
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: s, y: -s)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Window body and title bar.
        ctx.setFillColor(Synthetic.color(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(Synthetic.color(0xECECEE))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: 76))
        ctx.setFillColor(Synthetic.color(0x000000, 0.1))
        ctx.fill(CGRect(x: 0, y: 75, width: W, height: 1.5))
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Synthetic.color(hex))
            ctx.fillEllipse(in: CGRect(x: 28 + CGFloat(i) * 34, y: 28, width: 20, height: 20))
        }
        Synthetic.text("Comakers Workspace", in: ctx, x: 140, y: 47, size: 24, weight: .semibold, color: Synthetic.color(0x1D1D1F))

        Synthetic.text("Automation report", in: ctx, x: 48, y: 152, size: 50, weight: .bold, color: Synthetic.color(0x1D1D1F))
        let paragraph = [
            "This synthetic window checks how the compositor",
            "scales text into a 9:16 canvas. Body text is 28 px,",
            "the caption is 22 px. Both must stay crisp.",
        ]
        for (i, line) in paragraph.enumerated() {
            Synthetic.text(line, in: ctx, x: 48, y: 208 + CGFloat(i) * 42, size: 28, color: Synthetic.color(0x3A3A3C))
        }
        Synthetic.text("350+ automations · pilot in 72 hours · 11 pt caption", in: ctx, x: 48, y: 334, size: 22,
                       color: Synthetic.color(0x8E8E93))

        let code = CGRect(x: 48, y: 366, width: W - 96, height: 200)
        ctx.setFillColor(Synthetic.color(0x1E1E2E))
        ctx.addPath(CGPath(roundedRect: code, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()
        let codeLines = [
            ("func compose(frame: VideoFrame) {", UInt32(0xCDD6F4)),
            ("    let slots = PortraitLayout.slots(…)", 0xA6E3A1),
            ("    // masks and shadows are cached", 0x7F849C),
            ("}", 0xCDD6F4),
        ]
        for (i, entry) in codeLines.enumerated() {
            Synthetic.text(entry.0, in: ctx, x: code.minX + 30, y: code.minY + 50 + CGFloat(i) * 42, size: 24, mono: true,
                           color: Synthetic.color(entry.1))
        }

        let table = CGRect(x: 48, y: 596, width: W - 96, height: 156)
        let columns: [CGFloat] = [0, 0.56, 0.8]
        for row in 0...2 {
            let y = table.minY + CGFloat(row) * 52
            ctx.setFillColor(Synthetic.color(0x000000, row == 0 ? 0.25 : 0.08))
            ctx.fill(CGRect(x: table.minX, y: y + 50, width: table.width, height: 2))
            let cells = row == 0 ? ["Module", "Status", "Saved"] :
                [["M1 Lead intake", "Live", "42 h"], ["M3 Support triage", "Pilot", "65 h"]][row - 1]
            for (c, cell) in cells.enumerated() {
                Synthetic.text(cell, in: ctx, x: table.minX + columns[c] * table.width, y: y + 36, size: 24,
                               weight: row == 0 ? .semibold : .regular, color: Synthetic.color(0x1D1D1F))
            }
        }
        let chart = narrowChart(referenceHeight: H)
        ctx.setFillColor(Synthetic.color(0xF2F2F7))
        ctx.addPath(CGPath(roundedRect: chart, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()
    }

    // MARK: Desktop layout

    private static func drawBase(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Synthetic.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let W = CGFloat(width)
        let H = CGFloat(height)
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Window body, title bar, sidebar.
        ctx.setFillColor(Synthetic.color(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(Synthetic.color(0xF5F5F7))
        ctx.fill(CGRect(x: 0, y: 0, width: 460, height: H))
        ctx.setFillColor(Synthetic.color(0xECECEE))
        ctx.fill(CGRect(x: 460, y: 0, width: W - 460, height: 104))
        ctx.setFillColor(Synthetic.color(0x000000, 0.1))
        ctx.fill(CGRect(x: 460, y: 103, width: W - 460, height: 2))
        ctx.fill(CGRect(x: 459, y: 0, width: 2, height: H))
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Synthetic.color(hex))
            ctx.fillEllipse(in: CGRect(x: 40 + CGFloat(i) * 40, y: 40, width: 24, height: 24))
        }
        Synthetic.text("Comakers Workspace", in: ctx, x: 520, y: 66, size: 28, weight: .semibold, color: Synthetic.color(0x1D1D1F))

        let items = ["Inbox", "Today", "Projects", "Automations", "Reports", "Settings"]
        for (i, item) in items.enumerated() {
            let y = 170 + CGFloat(i) * 64
            if i == 3 {
                ctx.setFillColor(Synthetic.color(0x8E5CF6))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: y - 42, width: 420, height: 60), cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.fillPath()
            }
            Synthetic.text(item, in: ctx, x: 48, y: y, size: 26, weight: .medium,
                           color: Synthetic.color(i == 3 ? 0xFFFFFF : 0x3A3A3C))
        }

        Synthetic.text("Quarterly automation report", in: ctx, x: 560, y: 230, size: 64, weight: .bold, color: Synthetic.color(0x1D1D1F))
        let paragraph = [
            "This synthetic window checks how the compositor scales text. Body text is 28 px (14 pt at 2x),",
            "the caption below is 22 px (11 pt). Both must stay crisp after the card is scaled into the canvas.",
            "The quick brown fox jumps over the lazy dog — 0123456789 — ScreenyPro self-test.",
        ]
        for (i, line) in paragraph.enumerated() {
            Synthetic.text(line, in: ctx, x: 560, y: 320 + CGFloat(i) * 46, size: 28, color: Synthetic.color(0x3A3A3C))
        }
        Synthetic.text("Caption: 350+ automations · pilot in 72 hours · small 11 pt text for sharpness checks",
                       in: ctx, x: 560, y: 480, size: 22, color: Synthetic.color(0x8E8E93))

        let code = CGRect(x: 560, y: 530, width: W - 640, height: 300)
        ctx.setFillColor(Synthetic.color(0x1E1E2E))
        ctx.addPath(CGPath(roundedRect: code, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.fillPath()
        let codeLines = [
            ("func compose(frame: VideoFrame) -> CVPixelBuffer {", UInt32(0xCDD6F4)),
            ("    let layout = CanvasLayout.make(canvas: size, style: style)", 0xA6E3A1),
            ("    // shadow, mask and background are cached", 0x7F849C),
            ("    return compositor.render(screen: frame, camera: nil)", 0xF9E2AF),
            ("}", 0xCDD6F4),
        ]
        for (i, entry) in codeLines.enumerated() {
            Synthetic.text(entry.0, in: ctx, x: code.minX + 36, y: code.minY + 64 + CGFloat(i) * 48, size: 26, mono: true,
                           color: Synthetic.color(entry.1))
        }

        // Table with thin rules.
        let table = CGRect(x: 560, y: 880, width: W - 640, height: 260)
        for row in 0...4 {
            let y = table.minY + CGFloat(row) * 52
            ctx.setFillColor(Synthetic.color(0x000000, row == 0 ? 0.25 : 0.08))
            ctx.fill(CGRect(x: table.minX, y: y + 50, width: table.width, height: 2))
            let cells = row == 0 ? ["Module", "Owner", "Status", "Saved hours"] :
                [["M1 Lead intake", "Sales", "Live", "42 h"], ["M2 Invoices", "Finance", "Pilot", "18 h"],
                 ["M3 Support triage", "Support", "Live", "65 h"], ["M4 Reporting", "Ops", "Draft", "—"]][row - 1]
            for (c, cell) in cells.enumerated() {
                Synthetic.text(cell, in: ctx, x: table.minX + CGFloat(c) * table.width / 4, y: y + 36, size: 24,
                               weight: row == 0 ? .semibold : .regular, color: Synthetic.color(0x1D1D1F))
            }
        }
        // Chart frame.
        let chart = CGRect(x: 520, y: 1180, width: W - 600, height: 560)
        ctx.setFillColor(Synthetic.color(0xF2F2F7))
        ctx.addPath(CGPath(roundedRect: chart, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()
    }
}

/// A fake 1280×720 webcam: soft backdrop and a simple swaying figure.
final class SyntheticCamera {
    let width = 1280
    let height = 720
    private let pool: CVPixelBufferPool

    init() throws {
        guard let pool = Synthetic.makePool(width: width, height: height) else {
            throw SelfTestError("cannot create the synthetic camera source")
        }
        self.pool = pool
    }

    func frame(t: Double, time: CMTime) -> VideoFrame? {
        let buffer = Synthetic.drawBuffer(pool: pool) { ctx, size in
            let gradient = CGGradient(
                colorsSpace: Synthetic.sRGB,
                colors: [Synthetic.color(0xD9C8B4), Synthetic.color(0x8FA6A8)] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            // A plant-like shape on the left, a lamp glow on the right.
            ctx.setFillColor(Synthetic.color(0x4F7A55, 0.8))
            ctx.fillEllipse(in: CGRect(x: 90, y: 260, width: 180, height: 300))
            ctx.setFillColor(Synthetic.color(0xFFF1C9, 0.5))
            ctx.fillEllipse(in: CGRect(x: 1020, y: 90, width: 160, height: 160))

            let sway = CGFloat(sin(t * 1.7)) * 18
            let cx = size.width / 2 + sway
            ctx.setFillColor(Synthetic.color(0x2B3A55))
            ctx.fillEllipse(in: CGRect(x: cx - 300, y: 520, width: 600, height: 420))
            ctx.setFillColor(Synthetic.color(0xE0AC8A))
            ctx.fill(CGRect(x: cx - 55, y: 430, width: 110, height: 120))
            ctx.fillEllipse(in: CGRect(x: cx - 130, y: 170, width: 260, height: 310))
            ctx.setFillColor(Synthetic.color(0x3B2A20))
            ctx.addPath(CGPath(ellipseIn: CGRect(x: cx - 140, y: 140, width: 280, height: 160), transform: nil))
            ctx.fillPath()
            ctx.setFillColor(Synthetic.color(0x2A1E18))
            ctx.fillEllipse(in: CGRect(x: cx - 70, y: 300, width: 26, height: 18))
            ctx.fillEllipse(in: CGRect(x: cx + 44, y: 300, width: 26, height: 18))
        }
        guard let buffer else { return nil }
        return VideoFrame(pixelBuffer: buffer, contentRect: CGRect(x: 0, y: 0, width: width, height: height), time: time)
    }
}

/// Continuous sine tone as host-clock LPCM sample buffers (Float32 interleaved, 48 kHz).
final class SineSource {
    let frequency: Double
    let channels: Int
    let amplitude: Float
    static let sampleRate = 48_000
    private let format: CMAudioFormatDescription
    private let startTime: CMTime
    private var cursor: Int64 = 0
    /// Optional gate: when it returns `false` for a sample time (seconds since start), the sample is silent.
    var gate: ((Double) -> Bool)?

    init(frequency: Double, channels: Int, amplitude: Float = 0.25, startTime: CMTime) throws {
        self.frequency = frequency
        self.channels = channels
        self.amplitude = amplitude
        self.startTime = startTime
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw SelfTestError("cannot create an audio format (\(status))") }
        format = description
    }

    /// Produces all samples up to `now` (host clock) as one buffer, or `nil` when there is nothing new.
    func samples(until now: CMTime) -> CMSampleBuffer? {
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, startTime))
        let target = Int64(elapsed * Double(Self.sampleRate))
        let count = Int(min(target - cursor, Int64(Self.sampleRate)))
        guard count > 0 else { return nil }

        var data = [Float](repeating: 0, count: count * channels)
        let rate = Double(Self.sampleRate)
        for i in 0..<count {
            let n = cursor + Int64(i)
            let seconds = Double(n) / rate
            let open = gate?(seconds) ?? true
            let value = open ? amplitude * Float(sin(2 * .pi * frequency * seconds)) : 0
            for c in 0..<channels { data[i * channels + c] = value }
        }
        let pts = CMTimeAdd(startTime, CMTime(value: cursor, timescale: CMTimeScale(Self.sampleRate)))
        cursor += Int64(count)

        let length = data.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }
}
