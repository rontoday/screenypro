import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import os
import QuartzCore
import ScreenyCore

/// Live preview of the composed canvas. Backed by an `AVSampleBufferDisplayLayer` (aspect-fit),
/// with 10 pt rounded corners. `display(_:)` can be called from any thread; frames above ~30 fps are dropped.
public final class PreviewView: NSView, PreviewDisplaying {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "cz.comakers.screenypro.preview", qos: .userInteractive)
    private let log = Logger(subsystem: "cz.comakers.screenypro", category: "preview")

    // Preview queue only.
    private var formatDescription: CMVideoFormatDescription?
    private var lastEnqueue: Double = 0
    private var failureLogged = false

    /// Minimum time between shown frames: ~30 fps cap (a 60 fps pipeline shows every second frame).
    static let minFrameInterval: Double = 0.026

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.cornerRadius = 10
        displayLayer.cornerCurve = .continuous
        displayLayer.masksToBounds = true
    }

    public override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    public override var wantsUpdateLayer: Bool { true }

    public override var isOpaque: Bool { false }

    public func display(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            self?.enqueue(pixelBuffer)
        }
    }

    // MARK: Preview queue

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastEnqueue >= Self.minFrameInterval else { return }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            if !failureLogged {
                log.error("Preview renderer needs recovery: \(renderer.error?.localizedDescription ?? "flush required", privacy: .public)")
                failureLogged = true
            }
            renderer.flush()
        }

        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        renderer.enqueue(sampleBuffer)
        lastEnqueue = now
        if renderer.status != .failed { failureLogged = false }
    }
}
