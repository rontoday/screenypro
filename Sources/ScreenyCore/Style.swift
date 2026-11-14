import CoreGraphics
import Foundation

/// sRGB color, components 0...1.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `0xRRGGBB`
    public init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
    }
}

/// A soft "mesh-like" gradient: a linear base plus blurred color glows.
public struct GradientPreset: Identifiable, Hashable, Sendable {
    public struct Glow: Hashable, Sendable {
        public var color: RGBA
        /// Center in unit canvas coordinates, origin TOP-left.
        public var center: CGPoint
        /// Radius as a fraction of the canvas width.
        public var radius: Double

        public init(color: RGBA, center: CGPoint, radius: Double) {
            self.color = color
            self.center = center
            self.radius = radius
        }
    }

    public let id: String
    public let name: String
    /// Linear base gradient, from `start` to `end` (unit coordinates, origin TOP-left).
    public let colors: [RGBA]
    public let start: CGPoint
    public let end: CGPoint
    public let glows: [Glow]

    public init(id: String, name: String, colors: [RGBA], start: CGPoint, end: CGPoint, glows: [Glow]) {
        self.id = id
        self.name = name
        self.colors = colors
        self.start = start
        self.end = end
        self.glows = glows
    }

    public static let all: [GradientPreset] = [
        // The reference look: deep violet on the left, magenta-pink glow on the right.
        GradientPreset(
            id: "orchid", name: "Orchid",
            colors: [RGBA(hex: 0x3B1D8F), RGBA(hex: 0x8E3FD1), RGBA(hex: 0xE58AD8)],
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1),
            glows: [
                Glow(color: RGBA(hex: 0xF7A8E0), center: CGPoint(x: 0.92, y: 0.55), radius: 0.45),
                Glow(color: RGBA(hex: 0x2A1470), center: CGPoint(x: 0.05, y: 0.1), radius: 0.5),
            ]
        ),
        GradientPreset(
            id: "ocean", name: "Ocean",
            colors: [RGBA(hex: 0x0B2A6F), RGBA(hex: 0x1E6FD9), RGBA(hex: 0x6FE3E1)],
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1),
            glows: [
                Glow(color: RGBA(hex: 0x8AF0E0), center: CGPoint(x: 0.9, y: 0.85), radius: 0.4),
                Glow(color: RGBA(hex: 0x081B4F), center: CGPoint(x: 0.05, y: 0.05), radius: 0.5),
            ]
        ),
        GradientPreset(
            id: "sunset", name: "Sunset",
            colors: [RGBA(hex: 0x5B1E8C), RGBA(hex: 0xE2466A), RGBA(hex: 0xFFB45E)],
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1),
            glows: [
                Glow(color: RGBA(hex: 0xFFC978), center: CGPoint(x: 0.95, y: 0.9), radius: 0.4),
                Glow(color: RGBA(hex: 0x3A1266), center: CGPoint(x: 0.0, y: 0.0), radius: 0.5),
            ]
        ),
        GradientPreset(
            id: "forest", name: "Forest",
            colors: [RGBA(hex: 0x0C3B2E), RGBA(hex: 0x1F8A5B), RGBA(hex: 0xB7E36B)],
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1),
            glows: [
                Glow(color: RGBA(hex: 0xD6F28A), center: CGPoint(x: 0.92, y: 0.8), radius: 0.4),
                Glow(color: RGBA(hex: 0x072419), center: CGPoint(x: 0.05, y: 0.1), radius: 0.5),
            ]
        ),
        GradientPreset(
            id: "graphite", name: "Graphite",
            colors: [RGBA(hex: 0x15171C), RGBA(hex: 0x2A2E38), RGBA(hex: 0x4A5162)],
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1),
            glows: [
                Glow(color: RGBA(hex: 0x6A7388), center: CGPoint(x: 0.9, y: 0.2), radius: 0.4),
            ]
        ),
        GradientPreset(
            id: "paper", name: "Paper",
            colors: [RGBA(hex: 0xF4F1EC), RGBA(hex: 0xE7E2F0), RGBA(hex: 0xD9E4F2)],
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1),
            glows: [
                Glow(color: RGBA(hex: 0xFFFFFF), center: CGPoint(x: 0.2, y: 0.2), radius: 0.4),
            ]
        ),
    ]

    public static func preset(id: String) -> GradientPreset {
        all.first { $0.id == id } ?? all[0]
    }
}

public enum BackgroundStyle: Codable, Hashable, Sendable {
    /// `GradientPreset.id`
    case gradient(String)
    case solid(RGBA)
    /// Image file, aspect-fill.
    case image(URL)
}

public enum CanvasCorner: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    /// 3:2 rounded rectangle, like the reference.
    case roundedRect
    case circle
}

public struct CameraStyle: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var corner: CanvasCorner
    public var shape: CameraShape
    /// Camera height as a fraction of the canvas height (0.15...0.45).
    public var size: Double
    /// Distance from the canvas edges as a fraction of the canvas height.
    public var margin: Double
    public var mirrored: Bool
    /// Portrait canvas only: height of the camera slot as a fraction of the canvas height (0.25...0.6).
    /// `corner`, `shape`, `size` and `margin` are ignored on a portrait canvas.
    public var portraitShare: Double

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        corner = try c.decodeIfPresent(CanvasCorner.self, forKey: .corner) ?? .bottomRight
        shape = try c.decodeIfPresent(CameraShape.self, forKey: .shape) ?? .roundedRect
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.28
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 0.03
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? true
        portraitShare = try c.decodeIfPresent(Double.self, forKey: .portraitShare) ?? 0.42
    }

    public init(
        enabled: Bool = true,
        corner: CanvasCorner = .bottomRight,
        shape: CameraShape = .roundedRect,
        size: Double = 0.28,
        margin: Double = 0.03,
        mirrored: Bool = true,
        portraitShare: Double = 0.42
    ) {
        self.portraitShare = portraitShare
        self.enabled = enabled
        self.corner = corner
        self.shape = shape
        self.size = size
        self.margin = margin
        self.mirrored = mirrored
    }
}

/// Everything that defines the look of the composed frame. All sizes are relative to the canvas,
/// so the look is the same at 1080p and 4K.
public struct StyleSettings: Codable, Equatable, Sendable {
    public var background: BackgroundStyle
    /// Space between the canvas edge and the screen content, as a fraction of the canvas height (0...0.15).
    /// 0 = the screen content fills the canvas and has no rounded corners or shadow.
    public var padding: Double
    /// Corner radius of the screen content as a fraction of the canvas height (0...0.05).
    public var cornerRadius: Double
    /// Shadow strength under the screen content and the camera (0...1).
    public var shadow: Double
    public var camera: CameraStyle

    public init(
        background: BackgroundStyle = .gradient("orchid"),
        padding: Double = 0.055,
        cornerRadius: Double = 0.016,
        shadow: Double = 0.6,
        camera: CameraStyle = CameraStyle()
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.camera = camera
    }
}

/// Layout of a portrait (9:16) canvas: screen content in the top slot, camera in the bottom slot.
/// Shared by the compositor (drawing) and the UI (area aspect ratio, capture size).
public enum PortraitLayout {
    public struct Slots: Equatable, Sendable {
        /// Area for the screen content, canvas pixels, origin TOP-left. The content is aspect-fit and centered in it.
        public var screen: CGRect
        /// Area the camera fills (aspect-fill crop). `nil` when the camera is not shown.
        public var camera: CGRect?
        /// Corner radius for both cards, in pixels. 0 when `padding == 0`.
        public var cornerRadius: CGFloat
    }

    /// All relative style values use the canvas WIDTH as the reference on a portrait canvas.
    /// - `padding == 0`: the slots touch the canvas edges and each other, no radius.
    /// - camera not visible: the screen slot is the whole canvas inset by the padding.
    public static func slots(canvasSize: CGSize, style: StyleSettings, cameraVisible: Bool) -> Slots {
        let w = canvasSize.width
        let h = canvasSize.height
        let pad = (CGFloat(style.padding) * w).rounded()
        let radius = pad == 0 ? 0 : (CGFloat(style.cornerRadius) * w * 1.6).rounded()
        guard cameraVisible && style.camera.enabled else {
            return Slots(screen: CGRect(x: pad, y: pad, width: w - 2 * pad, height: h - 2 * pad), camera: nil, cornerRadius: radius)
        }
        let gap = (pad * 0.6).rounded()
        let share = CGFloat(min(max(style.camera.portraitShare, 0.25), 0.6))
        let usable = h - 2 * pad - gap
        let cameraHeight = (usable * share).rounded()
        let screenHeight = usable - cameraHeight
        let screen = CGRect(x: pad, y: pad, width: w - 2 * pad, height: screenHeight)
        let camera = CGRect(x: pad, y: pad + screenHeight + gap, width: w - 2 * pad, height: cameraHeight)
        return Slots(screen: screen, camera: camera, cornerRadius: radius)
    }
}
