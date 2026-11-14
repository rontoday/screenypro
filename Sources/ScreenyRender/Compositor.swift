import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import os
import ScreenyCore

/// Core Image compositor: background, screen card with shadow, camera bubble.
///
/// Not thread-safe: use one instance from one serial queue (the pipeline's render queue).
/// Everything static (background, shadows, masks, hairlines) is rendered once into IOSurface-backed
/// buffers and reused until the layout or the style changes.
final class Compositor {
    let context: CIContext
    /// Working space: non-linear sRGB, so blending, gradients and shadows match design tools.
    let workingSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Output pixels are sRGB-encoded. Buffers are tagged with Rec. 709 primaries and matrix (the same
    /// primaries as sRGB) and the sRGB transfer function (IEC 61966-2-1). Measured: AVFoundation/QuickTime and
    /// Chromium decode this exactly to the designed colors, and players that ignore the transfer tag also show
    /// the right values. A Rec. 709 transfer tag decodes ~10 levels lighter in QuickTime or darker in Chrome.
    let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private(set) var canvas: CGSize = .zero
    /// GPU statistics of the last frame (pass count, kernel time); for benchmarks.
    private(set) var lastRenderInfo: CIRenderInfo?
    private var pool: CVPixelBufferPool?
    /// The pool never holds more buffers than this. If the consumers keep all of them, the tick is skipped.
    static let maxPoolBuffers = 12

    private let log = Logger(subsystem: "cz.comakers.screenypro", category: "compositor")

    // MARK: Caches

    private struct BackgroundKey: Equatable {
        var background: BackgroundStyle
        var canvas: CGSize
    }

    /// A card shadow that is baked into the static under layer.
    private struct ShadowShape: Equatable {
        var rect: CGRect
        var radius: CGFloat
        var shadow: CanvasLayout.Shadow
    }

    private struct UnderKey: Equatable {
        var background: BackgroundKey
        var screen: CanvasLayout.Screen?
        /// Portrait only: the camera card shadow lies under both cards.
        var cameraShadow: ShadowShape?
    }

    private struct ScreenKey: Equatable {
        var screen: CanvasLayout.Screen
        var canvas: CGSize
    }

    private struct CameraKey: Equatable {
        var camera: CanvasLayout.Camera
        var canvas: CGSize
    }

    private struct CameraParts {
        /// `nil` when the card is a plain rectangle (the content is already cropped to it).
        var mask: CIImage?
        var border: CIImage?
        /// Shadow drawn over the screen content (landscape bubble). `nil` when it is in the under layer.
        var shadow: CIImage?
    }

    private var backgroundCache: (key: BackgroundKey, image: CIImage)?
    private var underCache: (key: UnderKey, image: CIImage)?
    private var screenCache: (key: ScreenKey, mask: CIImage?, hairline: CIImage?)?
    private var cameraCache: (key: CameraKey, parts: CameraParts)?
    private var loggedImageFailure: URL?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositorError.noMetalDevice }
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
            .highQualityDownsample: true,
            .useSoftwareRenderer: false,
            .priorityRequestLow: false,
            .name: "ScreenyPro.Compositor",
        ])
    }

    // MARK: Canvas

    /// Sets the output size and (re)creates the buffer pool. Sizes are rounded to even pixel counts.
    func setCanvas(_ size: CGSize) throws {
        let w = max(2, Int((size.width / 2).rounded()) * 2)
        let h = max(2, Int((size.height / 2).rounded()) * 2)
        let newSize = CGSize(width: w, height: h)
        guard newSize != canvas || pool == nil else { return }
        if let pool { CVPixelBufferPoolFlush(pool, [.excessBuffers]) }
        pool = nil
        canvas = newSize
        invalidateCaches()

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4,
            kCVPixelBufferPoolMaximumBufferAgeKey: 2.0,
        ]
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &newPool)
        guard status == kCVReturnSuccess, let newPool else {
            throw CompositorError.pixelBufferCreationFailed(code: status)
        }
        pool = newPool
    }

    func invalidateCaches() {
        backgroundCache = nil
        underCache = nil
        screenCache = nil
        cameraCache = nil
        context.clearCaches()
    }

    // MARK: Render

    /// Composes one frame into a fresh pool buffer. Returns `nil` when all pool buffers are still in use
    /// (the caller skips the tick).
    func render(screen: VideoFrame?, camera: VideoFrame?, style: StyleSettings, time: CMTime) throws -> CVPixelBuffer? {
        guard let pool else { throw CompositorError.pixelBufferCreationFailed(code: kCVReturnInvalidArgument) }
        let image = compose(screen: screen, camera: camera, style: style, time: time)

        var buffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey: Self.maxPoolBuffers] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let buffer else {
            throw CompositorError.pixelBufferCreationFailed(code: status)
        }
        Self.tagOutputColor(buffer)

        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = outputSpace
        destination.isDithered = true
        destination.isClamped = true
        destination.alphaMode = .premultiplied
        do {
            let task = try context.startTask(toRender: image, to: destination)
            lastRenderInfo = try task.waitUntilCompleted()
        } catch {
            throw CompositorError.renderFailed(underlying: error)
        }
        return buffer
    }

    /// Builds the Core Image graph of one frame (canvas coordinates, bottom-left origin).
    func compose(screen: VideoFrame?, camera: VideoFrame?, style: StyleSettings, time: CMTime) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let freshCamera = camera.flatMap { frame -> VideoFrame? in
            let age = CMTimeGetSeconds(CMTimeSubtract(time, frame.time))
            return age.isFinite && age > 1.0 ? nil : frame
        }
        let screenSize = screen.map { Self.contentRect(of: $0).size }
        let layout = CanvasLayout.make(
            canvas: canvas,
            style: style,
            screenContentSize: screenSize,
            cameraVisible: freshCamera != nil
        )

        var image = underLayer(layout: layout, background: style.background)

        if let screenLayout = layout.screen, let screen {
            let rect = CanvasLayout.flipped(screenLayout.rect, height: canvas.height)
            let parts = screenParts(screenLayout)
            var content = Self.scaledContent(
                CIImage(cvPixelBuffer: screen.pixelBuffer, options: Self.imageOptions(for: screen.pixelBuffer)),
                bufferHeight: CGFloat(CVPixelBufferGetHeight(screen.pixelBuffer)),
                crop: Self.contentRect(of: screen),
                mirrored: false,
                into: rect
            )
            if let mask = parts.mask {
                content = content.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
            image = content.composited(over: image)
            if let hairline = parts.hairline {
                image = hairline.composited(over: image)
            }
        }

        if let cameraLayout = layout.camera, let freshCamera {
            let rect = CanvasLayout.flipped(cameraLayout.rect, height: canvas.height)
            let parts = cameraParts(cameraLayout)
            let full = Self.contentRect(of: freshCamera)
            let crop = CanvasLayout.aspectFillCrop(source: full, target: rect.size, maxTopCrop: cameraLayout.maxTopCrop)
            var content = Self.scaledContent(
                CIImage(cvPixelBuffer: freshCamera.pixelBuffer, options: Self.imageOptions(for: freshCamera.pixelBuffer)),
                bufferHeight: CGFloat(CVPixelBufferGetHeight(freshCamera.pixelBuffer)),
                crop: crop,
                mirrored: cameraLayout.mirrored,
                into: rect
            )
            if let mask = parts.mask {
                content = content.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
            if let shadow = parts.shadow {
                image = shadow.composited(over: image)
            }
            image = content.composited(over: image)
            if let border = parts.border {
                image = border.composited(over: image)
            }
        }

        return image.cropped(to: canvasRect)
    }

    // MARK: Frame content

    /// The useful part of a frame in pixels (top-left origin), clipped to the buffer and snapped to whole pixels.
    static func contentRect(of frame: VideoFrame) -> CGRect {
        let bounds = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        let rect = frame.contentRect.integral.intersection(bounds)
        return (rect.isNull || rect.width < 1 || rect.height < 1) ? bounds : rect
    }

    /// Crops `crop` (top-left pixels) out of the source, optionally mirrors it, and scales it into `target`
    /// (Core Image coordinates) with a Lanczos filter.
    static func scaledContent(_ source: CIImage, bufferHeight: CGFloat, crop: CGRect, mirrored: Bool, into target: CGRect) -> CIImage {
        let ciCrop = CanvasLayout.flipped(crop, height: bufferHeight)
        var image = source.cropped(to: ciCrop)
            .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
        if mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: ciCrop.width, ty: 0))
        }
        let sx = target.width / ciCrop.width
        let sy = target.height / ciCrop.height
        let local = CGRect(origin: .zero, size: target.size)
        if abs(sx - 1) > 0.0005 || abs(sy - 1) > 0.0005 {
            let filter = CIFilter.lanczosScaleTransform()
            // Clamp first so the filter does not pull transparent pixels into the edges.
            filter.inputImage = image.clampedToExtent()
            filter.scale = Float(sy)
            filter.aspectRatio = Float(sx / sy)
            image = filter.outputImage ?? image
        }
        return image.cropped(to: local)
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
    }

    /// Source buffers without color information are treated as sRGB (ScreenCaptureKit default).
    static func imageOptions(for buffer: CVPixelBuffer) -> [CIImageOption: Any] {
        if CVImageBufferGetColorSpace(buffer) != nil { return [:] }
        if CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) != nil { return [:] }
        return [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]
    }

    static func tagOutputColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    // MARK: Static layers

    /// Background + card shadows, opaque, canvas size. Rebuilt only when the background, canvas or a card changes.
    private func underLayer(layout: CanvasLayout, background: BackgroundStyle) -> CIImage {
        let bgKey = BackgroundKey(background: background, canvas: canvas)
        var cameraShadow: ShadowShape?
        if let camera = layout.camera, camera.shadowInBackground, camera.shadow.isVisible {
            cameraShadow = ShadowShape(rect: camera.rect, radius: camera.cornerRadius, shadow: camera.shadow)
        }
        let key = UnderKey(background: bgKey, screen: layout.screen, cameraShadow: cameraShadow)
        if let cached = underCache, cached.key == key { return cached.image }

        let canvasRect = CGRect(origin: .zero, size: canvas)
        var image: CIImage
        var addNoise = true
        if let screen = layout.screen, !screen.isCard {
            // Padding 0: the content fills the canvas; black bars where the aspect ratio differs.
            image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: workingSpace)!).cropped(to: canvasRect)
            addNoise = false
        } else {
            image = backgroundImage(bgKey)
            if case .image = background { addNoise = false }
            if let screen = layout.screen, screen.shadow.isVisible {
                let rect = CanvasLayout.flipped(screen.rect, height: canvas.height)
                image = shadowImage(rect: rect, radius: screen.cornerRadius, shadow: screen.shadow).composited(over: image)
            }
        }
        if let cameraShadow {
            // Black shadows over each other: the order does not matter.
            let rect = CanvasLayout.flipped(cameraShadow.rect, height: canvas.height)
            image = shadowImage(rect: rect, radius: cameraShadow.radius, shadow: cameraShadow.shadow).composited(over: image)
        }
        if addNoise {
            image = Self.addingNoise(to: image)
        }
        let baked = bake(image.cropped(to: canvasRect), opaque: true) ?? image.cropped(to: canvasRect)
        underCache = (key, baked)
        return baked
    }

    private func screenParts(_ screen: CanvasLayout.Screen) -> (mask: CIImage?, hairline: CIImage?) {
        let key = ScreenKey(screen: screen, canvas: canvas)
        if let cached = screenCache, cached.key == key { return (cached.mask, cached.hairline) }
        let rect = CanvasLayout.flipped(screen.rect, height: canvas.height)
        var mask: CIImage?
        var hairline: CIImage?
        if screen.cornerRadius > 0 {
            mask = shapeImage(size: rect.size, radius: screen.cornerRadius, ellipse: false, stroke: nil, alpha: 1)
                .map { placed($0, at: rect.origin) }
        }
        if screen.isCard {
            hairline = shapeImage(size: rect.size, radius: screen.cornerRadius, ellipse: false, stroke: screen.hairlineWidth, alpha: 0.12)
                .map { placed($0, at: rect.origin) }
        }
        screenCache = (key, mask, hairline)
        return (mask, hairline)
    }

    private func cameraParts(_ camera: CanvasLayout.Camera) -> CameraParts {
        let key = CameraKey(camera: camera, canvas: canvas)
        if let cached = cameraCache, cached.key == key { return cached.parts }
        let rect = CanvasLayout.flipped(camera.rect, height: canvas.height)
        let ellipse = camera.shape == .circle
        var parts = CameraParts()
        if ellipse || camera.cornerRadius > 0 {
            parts.mask = shapeImage(size: rect.size, radius: camera.cornerRadius, ellipse: ellipse, stroke: nil, alpha: 1)
                .map { placed($0, at: rect.origin) } ?? CIImage(color: .white).cropped(to: rect)
        }
        if camera.borderWidth > 0 {
            parts.border = shapeImage(size: rect.size, radius: camera.cornerRadius, ellipse: ellipse, stroke: camera.borderWidth, alpha: 0.2)
                .map { placed($0, at: rect.origin) } ?? CIImage.empty()
        }
        if camera.shadow.isVisible, !camera.shadowInBackground {
            let raw = shadowImage(rect: rect, radius: camera.cornerRadius, shadow: camera.shadow)
            parts.shadow = bake(raw, opaque: false) ?? raw
        }
        cameraCache = (key, parts)
        return parts
    }

    private func placed(_ image: CGImage, at origin: CGPoint) -> CIImage {
        let ci = CIImage(cgImage: image, options: [.colorSpace: workingSpace])
        let positioned = ci.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return bake(positioned, opaque: false) ?? positioned
    }

    /// A soft drop shadow of a rounded rect (Core Image coordinates): the wide main shadow from the layout,
    /// plus a faint tight contact shadow that defines the edge, like a real object lifted off a surface.
    private func shadowImage(rect: CGRect, radius: CGFloat, shadow: CanvasLayout.Shadow) -> CIImage {
        func layer(blur: CGFloat, offset: CGFloat, opacity: CGFloat) -> CIImage {
            let generator = CIFilter.roundedRectangleGenerator()
            generator.extent = rect
            generator.radius = Float(radius)
            generator.color = CIColor(red: 0, green: 0, blue: 0, alpha: opacity, colorSpace: workingSpace)!
            guard let shape = generator.outputImage else { return CIImage.empty() }
            return shape
                .applyingGaussianBlur(sigma: Double(blur))
                .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
        }
        let main = layer(blur: shadow.blur, offset: shadow.offset, opacity: shadow.opacity)
        let contact = layer(
            blur: max(1, shadow.blur * Self.contactShadowScale),
            offset: shadow.offset * Self.contactShadowScale,
            opacity: shadow.opacity * Self.contactShadowOpacity
        )
        return contact.composited(over: main)
    }

    static let contactShadowScale: CGFloat = 0.12
    static let contactShadowOpacity: CGFloat = 0.35

    /// Anti-aliased white shape (filled, or an inner stroke of width `stroke`) drawn with Core Graphics.
    private func shapeImage(size: CGSize, radius: CGFloat, ellipse: Bool, stroke: CGFloat?, alpha: CGFloat) -> CGImage? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: workingSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        func path(_ rect: CGRect, _ r: CGFloat) -> CGPath {
            if ellipse { return CGPath(ellipseIn: rect, transform: nil) }
            let rr = max(0, min(r, rect.width / 2, rect.height / 2))
            return CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil)
        }
        ctx.setFillColor(CGColor(colorSpace: workingSpace, components: [1, 1, 1, alpha])!)
        ctx.setStrokeColor(CGColor(colorSpace: workingSpace, components: [1, 1, 1, alpha])!)
        if let stroke {
            let inset = stroke / 2
            ctx.setLineWidth(stroke)
            ctx.addPath(path(bounds.insetBy(dx: inset, dy: inset), radius - inset))
            ctx.strokePath()
        } else {
            ctx.addPath(path(bounds, radius))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    // MARK: Background

    private func backgroundImage(_ key: BackgroundKey) -> CIImage {
        if let cached = backgroundCache, cached.key == key { return cached.image }
        let rect = CGRect(origin: .zero, size: key.canvas)
        let image: CIImage
        switch key.background {
        case .gradient(let id):
            image = gradientImage(GradientPreset.preset(id: id), size: key.canvas)
        case .solid(let color):
            image = CIImage(color: ciColor(color)).cropped(to: rect)
        case .image(let url):
            if let loaded = loadImage(url, fill: key.canvas) {
                image = loaded
            } else {
                if loggedImageFailure != url {
                    log.error("Cannot load background image \(url.path, privacy: .public); using the default gradient")
                    loggedImageFailure = url
                }
                image = gradientImage(GradientPreset.all[0], size: key.canvas)
            }
        }
        // The background is cached as a float-precision graph; `underLayer` bakes the final pixels.
        backgroundCache = (key, image)
        return image
    }

    private func ciColor(_ c: RGBA, alpha: Double? = nil) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: alpha ?? c.a, colorSpace: workingSpace)!
    }

    /// Mesh-like gradient: a multi-stop smooth linear base plus soft Gaussian glows.
    func gradientImage(_ preset: GradientPreset, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: unit.x * size.width, y: (1 - unit.y) * size.height)
        }
        let colors = preset.colors.isEmpty ? [RGBA(hex: 0x3B1D8F)] : preset.colors
        var image = CIImage(color: ciColor(colors[0])).cropped(to: rect)
        if colors.count > 1 {
            let p0 = point(preset.start)
            let p1 = point(preset.end)
            let n = colors.count - 1
            func lerp(_ t: CGFloat) -> CGPoint {
                CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t)
            }
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let length = max(1, hypot(dx, dy))
            let ux = dx / length
            let uy = dy / length
            for i in 0..<n {
                let a = lerp(CGFloat(i) / CGFloat(n))
                let b = lerp(CGFloat(i + 1) / CGFloat(n))
                let segment = CIFilter.smoothLinearGradient()
                segment.point0 = a
                segment.point1 = b
                segment.color0 = ciColor(colors[i])
                segment.color1 = ciColor(colors[i + 1])
                guard let segmentImage = segment.outputImage?.cropped(to: rect) else { continue }
                if i == 0 {
                    image = segmentImage
                } else {
                    // Hard switch at the stop; both segments have the same color there, so there is no seam.
                    let step = CIFilter.linearGradient()
                    step.point0 = CGPoint(x: a.x - ux * 0.5, y: a.y - uy * 0.5)
                    step.point1 = CGPoint(x: a.x + ux * 0.5, y: a.y + uy * 0.5)
                    step.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: workingSpace)!
                    step.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: workingSpace)!
                    guard let mask = step.outputImage?.cropped(to: rect) else { continue }
                    image = segmentImage.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: image,
                        kCIInputMaskImageKey: mask,
                    ])
                }
            }
        }
        for glow in preset.glows {
            let filter = CIFilter.gaussianGradient()
            filter.center = point(glow.center)
            filter.radius = Float(glow.radius * size.width)
            filter.color0 = ciColor(glow.color, alpha: Self.glowAlpha * glow.color.a)
            filter.color1 = ciColor(glow.color, alpha: 0)
            if let glowImage = filter.outputImage?.cropped(to: rect) {
                image = glowImage.composited(over: image)
            }
        }
        return image.cropped(to: rect)
    }

    static let glowAlpha: Double = 0.85
    /// Peak noise amplitude (fraction of full scale). Triangular, monochrome.
    static let noiseAmount: CGFloat = 0.03

    /// Adds very light monochrome triangular noise so 8-bit output and the encoder show no banding.
    /// out = base + a * (n - base), n triangular in 0...1 (mean 0.5).
    static func addingNoise(to image: CIImage) -> CIImage {
        guard let random = CIFilter.randomGenerator().outputImage else { return image }
        let a = noiseAmount
        let noise = random
            .settingAlphaOne(in: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.5, y: 0.5, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.5, y: 0.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.5, y: 0.5, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: a),
            ])
            .cropped(to: image.extent)
        return noise.composited(over: image)
    }

    private func loadImage(_ url: URL, fill size: CGSize) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0
        else { return nil }
        // Decode only as many pixels as the canvas needs (aspect-fill).
        var longSide = CGFloat(max(pw, ph))
        let fillScale = max(size.width / CGFloat(pw), size.height / CGFloat(ph))
        if fillScale < 1 { longSide = (longSide * fillScale).rounded(.up) + 2 }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cg)
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let crop = CanvasLayout.aspectFillCrop(source: full, target: size)
        return Self.scaledContent(image, bufferHeight: full.height, crop: crop, mirrored: false, into: CGRect(origin: .zero, size: size))
    }

    // MARK: Baking

    /// Renders `image` once into an IOSurface-backed buffer and returns a cheap image backed by it.
    private func bake(_ image: CIImage, opaque: Bool) -> CIImage? {
        let extent = image.extent.integral
        guard !extent.isInfinite, !extent.isEmpty, extent.width < 16384, extent.height < 16384 else { return nil }
        let w = Int(extent.width)
        let h = Int(extent.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = workingSpace
        destination.alphaMode = .premultiplied
        destination.isDithered = opaque
        destination.isClamped = true
        let local = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        do {
            if !opaque {
                let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
                let task = try context.startTask(toRender: local.composited(over: clear), to: destination)
                _ = try task.waitUntilCompleted()
            } else {
                let task = try context.startTask(toRender: local, to: destination)
                _ = try task.waitUntilCompleted()
            }
        } catch {
            log.error("Baking a static layer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: workingSpace])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
