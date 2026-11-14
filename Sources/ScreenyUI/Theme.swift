import AppKit
import ScreenyCore
import SwiftUI

/// Visual tokens from the design spec. Dark, quiet, tool-like.
enum Theme {
    static let windowBackground = Color(hex: 0x16171B)
    static let panel = Color(hex: 0x1E2026)
    static let previewBackdrop = Color(hex: 0x111215)
    static let hairline = Color.white.opacity(0.08)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
    static let accent = Color(hex: 0x8E5CF6)
    static let record = Color(hex: 0xFF453A)
    static let fieldFill = Color.white.opacity(0.06)
    static let fieldFillHover = Color.white.opacity(0.09)
    static let fieldBorder = Color.white.opacity(0.08)
    static let meterGreen = Color(hex: 0x32D74B)
    static let meterYellow = Color(hex: 0xFFD60A)

    static let nsWindowBackground = NSColor(hex: 0x16171B)
    static let nsRecord = NSColor(hex: 0xFF453A)

    static let controlFont = Font.system(size: 13)
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12

    /// Short ease-out transition for state changes (150–200 ms).
    static let stateAnimation = Animation.easeOut(duration: 0.18)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension RGBA {
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Formatting

enum Format {
    /// `m:ss` below one hour, `h:mm:ss` above.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func codec(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
