import CoreGraphics
import ScreenyCore

/// Pure layout math of the composed canvas. All rects are in canvas pixels, origin TOP-left.
/// Rects are snapped to whole pixels so the content stays sharp.
struct CanvasLayout: Equatable {
    struct Shadow: Equatable {
        /// Gaussian blur radius in pixels.
        var blur: CGFloat
        /// Downward offset in pixels.
        var offset: CGFloat
        /// 0...1
        var opacity: CGFloat

        var isVisible: Bool { opacity > 0.001 }
    }

    struct Screen: Equatable {
        var rect: CGRect
        var cornerRadius: CGFloat
        /// `false` when padding is 0: the content fills the canvas without shadow or hairline.
        var isCard: Bool
        var shadow: Shadow
        /// Width of the inner hairline in pixels.
        var hairlineWidth: CGFloat
    }

    struct Camera: Equatable {
        var rect: CGRect
        var shape: CameraShape
        var cornerRadius: CGFloat
        var mirrored: Bool
        var shadow: Shadow
        /// 0 = no border (portrait with padding 0).
        var borderWidth: CGFloat
        /// Portrait: the camera card sits next to the screen card (no overlap), so its shadow is baked into the
        /// static background layer, under both cards. Landscape: the bubble overlaps the screen, so its shadow is
        /// drawn over the screen content.
        var shadowInBackground: Bool = false
        /// Portrait: when the crop cuts the source vertically, cut at most this fraction of the source height
        /// from the top (the rest from the bottom), so a face is not cut. `nil` = centered crop.
        var maxTopCrop: CGFloat? = nil
    }

    var canvas: CGSize
    var screen: Screen?
    var camera: Camera?

    // Design constants (relative to the canvas height unless noted).
    static let shadowBlur: CGFloat = 0.035
    static let shadowOffset: CGFloat = 0.012
    static let shadowOpacityFactor: CGFloat = 0.55
    /// The camera shadow is the screen shadow scaled down by this factor.
    static let cameraShadowScale: CGFloat = 0.55
    static let cameraAspect: CGFloat = 1.5
    static let cameraRadiusFactor: CGFloat = 0.12
    /// Line widths are given for a 1440 px canvas and scale with the canvas height.
    static let hairlineAt1440: CGFloat = 1
    static let cameraBorderAt1440: CGFloat = 2

    /// - Parameters:
    ///   - screenContentSize: pixel size of the useful screen content, `nil` when there is no screen frame.
    ///   - cameraVisible: a fresh camera frame exists and the camera is enabled.
    static func make(canvas: CGSize, style: StyleSettings, screenContentSize: CGSize?, cameraVisible: Bool) -> CanvasLayout {
        if isPortrait(canvas) {
            return makePortrait(canvas: canvas, style: style, screenContentSize: screenContentSize, cameraVisible: cameraVisible)
        }
        let W = canvas.width
        let H = canvas.height
        let shadowStrength = CGFloat(clamp(style.shadow, 0, 1))
        let baseShadow = Shadow(
            blur: shadowBlur * H,
            offset: shadowOffset * H,
            opacity: shadowStrength * shadowOpacityFactor
        )
        let lineScale = H / 1440

        var screen: Screen?
        if let content = screenContentSize, content.width >= 1, content.height >= 1, W >= 2, H >= 2 {
            let padding = (CGFloat(clamp(style.padding, 0, 0.15)) * H).rounded()
            let isCard = padding >= 1
            let area = CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: padding, dy: padding)
            let fit = aspectFit(content, in: area)
            let radius = isCard ? min(CGFloat(clamp(style.cornerRadius, 0, 0.05)) * H, min(fit.width, fit.height) / 2) : 0
            screen = Screen(
                rect: fit,
                cornerRadius: radius,
                isCard: isCard,
                shadow: isCard ? baseShadow : Shadow(blur: 0, offset: 0, opacity: 0),
                hairlineWidth: max(1, (hairlineAt1440 * lineScale).rounded())
            )
        }

        var camera: Camera?
        if cameraVisible, style.camera.enabled, W >= 2, H >= 2 {
            let cam = style.camera
            let height = (CGFloat(clamp(cam.size, 0.1, 0.5)) * H).rounded()
            let width = cam.shape == .roundedRect ? (height * cameraAspect).rounded() : height
            let margin = (CGFloat(clamp(cam.margin, 0, 0.2)) * H).rounded()
            let x: CGFloat
            let y: CGFloat
            switch cam.corner {
            case .topLeft: x = margin; y = margin
            case .topRight: x = W - margin - width; y = margin
            case .bottomLeft: x = margin; y = H - margin - height
            case .bottomRight: x = W - margin - width; y = H - margin - height
            }
            let radius = cam.shape == .roundedRect ? cameraRadiusFactor * height : height / 2
            let k = cameraShadowScale
            camera = Camera(
                rect: CGRect(x: x, y: y, width: width, height: height),
                shape: cam.shape,
                cornerRadius: radius,
                mirrored: cam.mirrored,
                shadow: Shadow(blur: baseShadow.blur * k, offset: baseShadow.offset * k, opacity: baseShadow.opacity),
                borderWidth: max(1, cameraBorderAt1440 * lineScale)
            )
        }

        return CanvasLayout(canvas: canvas, screen: screen, camera: camera)
    }

    /// A canvas is portrait when it is taller than wide.
    static func isPortrait(_ canvas: CGSize) -> Bool { canvas.height > canvas.width }

    /// Fraction of the camera source height the portrait crop may cut from the top.
    static let portraitMaxTopCrop: CGFloat = 0.08

    /// Portrait (9:16): screen card in the top slot, camera card in the bottom slot. The slots come from
    /// `PortraitLayout` in Core (shared with the UI); everything else (shadow, hairline, border) is the landscape
    /// look with the canvas WIDTH as the reference length.
    private static func makePortrait(canvas: CGSize, style: StyleSettings, screenContentSize: CGSize?, cameraVisible: Bool) -> CanvasLayout {
        let W = canvas.width
        let H = canvas.height
        guard W >= 2, H >= 2 else { return CanvasLayout(canvas: canvas, screen: nil, camera: nil) }
        let slots = PortraitLayout.slots(canvasSize: canvas, style: style, cameraVisible: cameraVisible)
        // Padding 0 = the screen slot touches the canvas edge: no cards, no radius, no shadow, no lines.
        let isCard = slots.screen.minX >= 1
        let shadowStrength = CGFloat(clamp(style.shadow, 0, 1))
        let shadow = isCard
            ? Shadow(blur: shadowBlur * W, offset: shadowOffset * W, opacity: shadowStrength * shadowOpacityFactor)
            : Shadow(blur: 0, offset: 0, opacity: 0)
        let lineScale = W / 1440

        var screen: Screen?
        if let content = screenContentSize, content.width >= 1, content.height >= 1,
           slots.screen.width >= 1, slots.screen.height >= 1 {
            let fit = aspectFit(content, in: slots.screen)
            screen = Screen(
                rect: fit,
                cornerRadius: isCard ? min(max(0, slots.cornerRadius), min(fit.width, fit.height) / 2) : 0,
                isCard: isCard,
                shadow: shadow,
                hairlineWidth: max(1, (hairlineAt1440 * lineScale).rounded())
            )
        }

        var camera: Camera?
        if let slot = slots.camera, slot.width >= 1, slot.height >= 1 {
            camera = Camera(
                rect: slot,
                shape: .roundedRect,
                cornerRadius: isCard ? min(max(0, slots.cornerRadius), min(slot.width, slot.height) / 2) : 0,
                mirrored: style.camera.mirrored,
                shadow: shadow,
                borderWidth: isCard ? max(1, cameraBorderAt1440 * lineScale) : 0,
                shadowInBackground: true,
                maxTopCrop: portraitMaxTopCrop
            )
        }
        return CanvasLayout(canvas: canvas, screen: screen, camera: camera)
    }

    /// Aspect-fit `size` into `area`, centered, snapped to whole pixels.
    static func aspectFit(_ size: CGSize, in area: CGRect) -> CGRect {
        let scale = min(area.width / size.width, area.height / size.height)
        let w = max(1, (size.width * scale).rounded())
        let h = max(1, (size.height * scale).rounded())
        let x = (area.minX + (area.width - w) / 2).rounded()
        let y = (area.minY + (area.height - h) / 2).rounded()
        return CGRect(x: x, y: y, width: min(w, area.width), height: min(h, area.height))
    }

    /// The source crop (top-left pixels) that aspect-fills `target` with `source`. Centered, except that a
    /// vertical crop cuts at most `maxTopCrop × source height` from the top when given (biased upward).
    static func aspectFillCrop(source: CGRect, target: CGSize, maxTopCrop: CGFloat? = nil) -> CGRect {
        let targetAspect = target.width / target.height
        let sourceAspect = source.width / source.height
        if sourceAspect > targetAspect {
            let w = source.height * targetAspect
            return CGRect(x: source.midX - w / 2, y: source.minY, width: w, height: source.height)
        } else {
            let h = source.width / targetAspect
            guard let maxTopCrop else {
                return CGRect(x: source.minX, y: source.midY - h / 2, width: source.width, height: h)
            }
            let top = min((source.height - h) / 2, max(0, maxTopCrop) * source.height)
            return CGRect(x: source.minX, y: source.minY + top, width: source.width, height: h)
        }
    }

    /// Converts a top-left-origin rect into Core Image coordinates (bottom-left origin).
    static func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

@inline(__always)
func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(max(value, low), high)
}
