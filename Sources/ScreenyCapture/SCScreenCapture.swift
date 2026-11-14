import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit
import ScreenyCore

let captureLog = Logger(subsystem: "cz.comakers.screenypro", category: "capture")

/// Screen or window capture with ScreenCaptureKit. One `SCStream` delivers video, system audio and microphone.
///
/// Threading: public methods can be called from any thread or actor. `start`/`stop` and the internal
/// window-resize updates are serialized by an async gate, so quick repeated calls never race.
/// Sample buffers arrive on private serial queues.
public final class SCScreenCapture: ScreenCapturing, @unchecked Sendable {
    public let frames = LatestFrameBox()

    public var onAudio: ((AudioKind, CMSampleBuffer) -> Void)? {
        get { callbackLock.sync { audioHandler } }
        set { callbackLock.sync { audioHandler = newValue } }
    }

    public var onStop: ((Error?) -> Void)? {
        get { callbackLock.sync { stopHandler } }
        set { callbackLock.sync { stopHandler = newValue } }
    }

    private let callbackLock = NSLock()
    private var audioHandler: ((AudioKind, CMSampleBuffer) -> Void)?
    private var stopHandler: ((Error?) -> Void)?

    private let gate = AsyncSerialGate()
    private let videoQueue = DispatchQueue(label: "cz.comakers.screenypro.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "cz.comakers.screenypro.capture.audio", qos: .userInitiated)

    // Stream state. Read and written only while holding `gate`.
    private var stream: SCStream?
    private var receiver: ScreenStreamReceiver?
    private var activeConfig: CaptureConfig?
    private var outputSize: CGSize = .zero
    private var generation = 0

    // Short-lived cache of shareable content for thumbnails (the picker asks for many in a row).
    private let contentCacheLock = NSLock()
    private var contentCache: (content: SCShareableContent, date: Date)?

    public init() {}

    deinit {
        receiver?.invalidate(clearFrames: true)
        stream?.stopCapture { _ in }
    }

    // MARK: - Content

    public func listContent() async throws -> ShareableContent {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.wrap(error)
        }
        let screens = await MainActor.run { Self.screenDetails() }
        let mainID = CGMainDisplayID()

        var displays: [DisplayInfo] = []
        for (index, display) in content.displays.enumerated() {
            let details = screens[display.displayID]
            displays.append(DisplayInfo(
                id: display.displayID,
                name: details?.name ?? "Display \(index + 1)",
                frame: display.frame,
                scale: details?.scale ?? Self.modeScale(of: display.displayID)
            ))
        }
        displays.sort { lhs, rhs in
            if (lhs.id == mainID) != (rhs.id == mainID) { return lhs.id == mainID }
            return lhs.frame.minX < rhs.frame.minX
        }

        let ownPID = getpid()
        let ownBundleID = Bundle.main.bundleIdentifier
        let windows: [WindowInfo] = content.windows.compactMap { window in
            guard window.isOnScreen, window.windowLayer == 0 else { return nil }
            guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            guard window.frame.width >= 120, window.frame.height >= 80 else { return nil }
            guard let app = window.owningApplication else { return nil }
            if app.processID == ownPID { return nil }
            if let ownBundleID, !app.bundleIdentifier.isEmpty, app.bundleIdentifier == ownBundleID { return nil }
            if Self.systemUIBundleIDs.contains(app.bundleIdentifier) { return nil }
            if Self.systemUIAppNames.contains(app.applicationName) { return nil }
            return WindowInfo(
                id: window.windowID,
                title: title,
                appName: app.applicationName,
                bundleID: app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier,
                pid: app.processID,
                frame: window.frame
            )
        }
        .sorted { lhs, rhs in
            let byApp = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if byApp != .orderedSame { return byApp == .orderedAscending }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return ShareableContent(displays: displays, windows: windows)
    }

    public func thumbnail(for source: CaptureSource, maxSize: CGSize) async -> CGImage? {
        do {
            let content = try await cachedContent()
            let filter = try Self.makeFilter(for: source, in: content)
            let size = Self.fittedSize(Self.nativePixelSize(of: filter), maxPixelSize: maxSize)
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.scalesToFit = false
            config.preservesAspectRatio = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            captureLog.debug("Thumbnail failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Start / stop

    public func start(_ config: CaptureConfig) async throws {
        try await gate.withLock {
            try await self.startLocked(config)
        }
    }

    public func stop() async {
        await gate.withLock {
            await self.teardownLocked(clearFrames: true)
        }
        frames.set(nil)
    }

    private func startLocked(_ config: CaptureConfig) async throws {
        guard config.fps > 0 else {
            throw CaptureError.invalidConfiguration("The frame rate must be greater than zero.")
        }
        if config.microphoneID != nil {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .denied || micStatus == .restricted {
                throw CaptureError.permissionDenied(.microphone)
            }
        }

        let streamAlive = stream != nil && receiver.map { !$0.hasStopped } == true
        if streamAlive, activeConfig == config {
            return
        }

        let content: SCShareableContent
        do {
            // All windows (also on other Spaces), so a selected window can be found by ID.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.wrap(error)
        }
        let filter = try Self.makeFilter(for: config.source, in: content)
        let isWindow: Bool
        if case .window = config.source { isWindow = true } else { isWindow = false }
        let size = Self.fittedSize(Self.nativePixelSize(of: filter), maxPixelSize: config.maxPixelSize)

        // Update the running stream in place when the audio outputs stay the same.
        if streamAlive, let stream, let receiver, let current = activeConfig, Self.audioOutputsMatch(current, config) {
            do {
                if current.source != config.source {
                    try await stream.updateContentFilter(filter)
                }
                try await stream.updateConfiguration(Self.makeStreamConfiguration(config, size: size))
                activeConfig = config
                outputSize = size
                receiver.reset(isWindow: isWindow, maxPixelSize: config.maxPixelSize, outputSize: size)
                return
            } catch {
                captureLog.error("Live stream update failed, restarting: \(error.localizedDescription, privacy: .public)")
            }
        }

        await teardownLocked(clearFrames: false)
        do {
            try await launchLocked(config: config, filter: filter, isWindow: isWindow, size: size)
        } catch {
            frames.set(nil)
            throw CaptureError.wrap(error)
        }
    }

    private func launchLocked(config: CaptureConfig, filter: SCContentFilter, isWindow: Bool, size: CGSize) async throws {
        generation += 1
        let receiver = ScreenStreamReceiver(
            owner: self,
            generation: generation,
            frames: frames,
            isWindow: isWindow,
            maxPixelSize: config.maxPixelSize,
            outputSize: size
        )
        let stream = SCStream(filter: filter, configuration: Self.makeStreamConfiguration(config, size: size), delegate: receiver)
        do {
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: videoQueue)
            if config.capturesSystemAudio {
                try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if config.microphoneID != nil {
                try stream.addStreamOutput(receiver, type: .microphone, sampleHandlerQueue: audioQueue)
            }
            try await stream.startCapture()
        } catch {
            receiver.invalidate(clearFrames: false)
            throw error
        }
        self.stream = stream
        self.receiver = receiver
        activeConfig = config
        outputSize = size
    }

    private func teardownLocked(clearFrames: Bool) async {
        receiver?.invalidate(clearFrames: clearFrames)
        let oldStream = stream
        stream = nil
        receiver = nil
        activeConfig = nil
        outputSize = .zero
        guard let oldStream else { return }
        do {
            try await oldStream.stopCapture()
        } catch {
            // Already stopped (for example after didStopWithError). Nothing to do.
        }
    }

    // MARK: - Receiver callbacks (any queue)

    fileprivate func deliverAudio(_ kind: AudioKind, _ sampleBuffer: CMSampleBuffer) {
        let handler = callbackLock.sync { audioHandler }
        handler?(kind, sampleBuffer)
    }

    fileprivate func streamDidStop(generation stoppedGeneration: Int, error: Error) {
        let wrapped = CaptureError.wrapStop(error)
        captureLog.error("Stream stopped: \(wrapped.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onStop?(wrapped)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.gate.withLock {
                guard self.generation == stoppedGeneration, self.stream != nil else { return }
                self.receiver?.invalidate(clearFrames: true)
                self.stream = nil
                self.receiver = nil
                self.activeConfig = nil
                self.outputSize = .zero
            }
        }
    }

    fileprivate func resizeRequested(generation requestGeneration: Int) {
        Task { [weak self] in
            guard let self else { return }
            await self.gate.withLock {
                await self.applyPendingResizeLocked(generation: requestGeneration)
            }
        }
    }

    private func applyPendingResizeLocked(generation requestGeneration: Int) async {
        guard requestGeneration == generation,
              let stream, let receiver, let config = activeConfig,
              !receiver.hasStopped,
              let size = receiver.takePendingSize()
        else { return }
        guard size != outputSize else { return }
        do {
            try await stream.updateConfiguration(Self.makeStreamConfiguration(config, size: size))
            outputSize = size
            captureLog.debug("Window resized, stream size \(Int(size.width))x\(Int(size.height))")
        } catch {
            captureLog.error("Stream resize failed: \(error.localizedDescription, privacy: .public)")
            receiver.resizeFailed(currentSize: outputSize)
        }
    }

    // MARK: - Helpers

    private func cachedContent() async throws -> SCShareableContent {
        if let cached = contentCacheLock.sync({ contentCache }), Date().timeIntervalSince(cached.date) < 2 {
            return cached.content
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        contentCacheLock.sync { contentCache = (content, Date()) }
        return content
    }

    private static let systemUIBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.TextInputMenuAgent",
        "com.apple.wallpaper.agent",
    ]

    private static let systemUIAppNames: Set<String> = [
        "Window Server", "Dock", "Control Center", "Notification Center", "Wallpaper",
    ]

    static func makeFilter(for source: CaptureSource, in content: SCShareableContent) throws -> SCContentFilter {
        switch source {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayNotFound(displayID)
            }
            let ownPID = getpid()
            let ownBundleID = Bundle.main.bundleIdentifier
            let ownApps = content.applications.filter { app in
                app.processID == ownPID || (ownBundleID != nil && app.bundleIdentifier == ownBundleID)
            }
            if !ownApps.isEmpty {
                // Excluding the app (not single windows) also hides windows created later: HUD, countdown.
                return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            }
            // Fallback when the app is not listed yet: exclude the windows that exist now.
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            return SCContentFilter(display: display, excludingWindows: ownWindows)
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowNotFound(windowID)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Native pixel size of the filter content (points × backing scale).
    static func nativePixelSize(of filter: SCContentFilter) -> CGSize {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        if size.width < 2 || size.height < 2 {
            return CGSize(width: 1920, height: 1080)
        }
        return size
    }

    /// Aspect-fit `native` into `maxPixelSize` (a zero or negative dimension means no limit).
    /// Never upscales. Integer dimensions, at least 2×2. At native size the exact pixel size is kept
    /// (no 1 px downscale that would blur text).
    static func fittedSize(_ native: CGSize, maxPixelSize: CGSize) -> CGSize {
        let nativeWidth = native.width.rounded()
        let nativeHeight = native.height.rounded()
        guard nativeWidth >= 1, nativeHeight >= 1 else { return CGSize(width: 2, height: 2) }
        var scale: CGFloat = 1
        if maxPixelSize.width > 0 { scale = min(scale, maxPixelSize.width / nativeWidth) }
        if maxPixelSize.height > 0 { scale = min(scale, maxPixelSize.height / nativeHeight) }
        if scale >= 1 {
            return CGSize(width: max(2, nativeWidth), height: max(2, nativeHeight))
        }
        return CGSize(width: max(2, (nativeWidth * scale).rounded(.down)),
                      height: max(2, (nativeHeight * scale).rounded(.down)))
    }

    static func audioOutputsMatch(_ lhs: CaptureConfig, _ rhs: CaptureConfig) -> Bool {
        lhs.capturesSystemAudio == rhs.capturesSystemAudio && lhs.microphoneID == rhs.microphoneID
    }

    static func makeStreamConfiguration(_ config: CaptureConfig, size: CGSize) -> SCStreamConfiguration {
        let fps = min(max(config.fps, 1), 120)
        let scConfig = SCStreamConfiguration()
        scConfig.streamName = "ScreenyPro"
        scConfig.width = Int(size.width)
        scConfig.height = Int(size.height)
        scConfig.pixelFormat = kCVPixelFormatType_32BGRA
        scConfig.colorSpaceName = CGColorSpace.sRGB
        scConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        scConfig.queueDepth = 6
        scConfig.showsCursor = config.showsCursor
        scConfig.scalesToFit = false
        scConfig.preservesAspectRatio = true
        scConfig.captureResolution = .best
        scConfig.ignoreShadowsSingleWindow = true

        scConfig.capturesAudio = config.capturesSystemAudio
        scConfig.sampleRate = 48_000
        scConfig.channelCount = 2
        scConfig.excludesCurrentProcessAudio = true

        if let microphoneID = config.microphoneID {
            scConfig.captureMicrophone = true
            // Empty string = system default microphone.
            scConfig.microphoneCaptureDeviceID = microphoneID.isEmpty ? nil : microphoneID
        } else {
            scConfig.captureMicrophone = false
        }
        return scConfig
    }

    /// Name and backing scale of each screen. Main thread only (AppKit).
    @MainActor
    private static func screenDetails() -> [UInt32: (name: String, scale: Double)] {
        var result: [UInt32: (name: String, scale: Double)] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            result[number.uint32Value] = (screen.localizedName, Double(screen.backingScaleFactor))
        }
        return result
    }

    private static func modeScale(of displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }
}

// MARK: - Stream receiver

/// SCStream output and delegate. A new receiver is created for every stream, so callbacks of an old stream
/// can be told apart (`generation`) and ignored after `invalidate`. Holds its owner weakly (no retain cycle:
/// owner → stream → receiver ⇢ owner).
private final class ScreenStreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let generation: Int
    private weak var owner: SCScreenCapture?
    private let frames: LatestFrameBox

    private let lock = NSLock()
    // Guarded by `lock`.
    private var isActive = true
    private var stopped = false
    private var isWindow: Bool
    private var maxPixelSize: CGSize
    /// Last stream size requested (or configured). Used to detect window size changes.
    private var requestedSize: CGSize
    private var pendingSize: CGSize?
    private var resizeScheduled = false

    init(owner: SCScreenCapture, generation: Int, frames: LatestFrameBox, isWindow: Bool, maxPixelSize: CGSize, outputSize: CGSize) {
        self.owner = owner
        self.generation = generation
        self.frames = frames
        self.isWindow = isWindow
        self.maxPixelSize = maxPixelSize
        self.requestedSize = outputSize
    }

    var hasStopped: Bool { lock.sync { stopped } }

    /// No more frames, audio or stop reports from this receiver.
    func invalidate(clearFrames: Bool) {
        lock.sync {
            isActive = false
            if clearFrames { frames.set(nil) }
        }
    }

    /// New source or config on the same stream.
    func reset(isWindow: Bool, maxPixelSize: CGSize, outputSize: CGSize) {
        lock.sync {
            self.isWindow = isWindow
            self.maxPixelSize = maxPixelSize
            requestedSize = outputSize
            pendingSize = nil
            resizeScheduled = false
        }
    }

    func takePendingSize() -> CGSize? {
        lock.sync {
            let size = pendingSize
            pendingSize = nil
            resizeScheduled = false
            return size
        }
    }

    func resizeFailed(currentSize: CGSize) {
        lock.sync {
            // Let a later frame request the size again.
            requestedSize = currentSize
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            if lock.sync({ isActive }) { owner?.deliverAudio(.system, sampleBuffer) }
        case .microphone:
            if lock.sync({ isActive }) { owner?.deliverAudio(.microphone, sampleBuffer) }
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = Self.number(attachments[.status]),
              let status = SCFrameStatus(rawValue: Int(statusRaw)),
              status == .complete || status == .started,
              let pixelBuffer = sampleBuffer.imageBuffer // ARC-managed: the frame keeps the IOSurface alive.
        else { return }

        let bufferRect = CGRect(x: 0, y: 0,
                                width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        let scaleFactor = Self.number(attachments[.scaleFactor]) ?? 1
        let contentScale = Self.number(attachments[.contentScale]) ?? 1
        var pointRect: CGRect?
        if let dictionary = attachments[.contentRect] as? NSDictionary {
            pointRect = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }

        // contentRect is in points of the output buffer, origin top-left; × scaleFactor = pixels.
        var contentRect = bufferRect
        if let pointRect, scaleFactor > 0 {
            let pixelRect = CGRect(x: pointRect.minX * scaleFactor,
                                   y: pointRect.minY * scaleFactor,
                                   width: pointRect.width * scaleFactor,
                                   height: pointRect.height * scaleFactor)
                .integral
                .intersection(bufferRect)
            if !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 {
                contentRect = pixelRect
            }
        }

        let frame = VideoFrame(pixelBuffer: pixelBuffer, contentRect: contentRect, time: sampleBuffer.presentationTimeStamp)

        var scheduleResize = false
        let published: Bool = lock.sync {
            guard isActive else { return false }
            frames.set(frame)

            // Window capture: follow the window's native pixel size.
            if isWindow, let pointRect, contentScale > 0, scaleFactor > 0 {
                let native = CGSize(width: pointRect.width / contentScale * scaleFactor,
                                    height: pointRect.height / contentScale * scaleFactor)
                let desired = SCScreenCapture.fittedSize(native, maxPixelSize: maxPixelSize)
                // 1 px tolerance absorbs float noise of contentScale while the output is scaled.
                if abs(desired.width - requestedSize.width) > 1 || abs(desired.height - requestedSize.height) > 1 {
                    requestedSize = desired
                    pendingSize = desired
                    if !resizeScheduled {
                        resizeScheduled = true
                        scheduleResize = true
                    }
                }
            }
            return true
        }
        if published, scheduleResize {
            owner?.resizeRequested(generation: generation)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let shouldReport: Bool = lock.sync {
            stopped = true
            guard isActive else { return false }
            isActive = false
            frames.set(nil)
            return true
        }
        if shouldReport {
            owner?.streamDidStop(generation: generation, error: error)
        }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber: return CGFloat(number.doubleValue)
        case let double as Double: return CGFloat(double)
        case let float as CGFloat: return float
        case let int as Int: return CGFloat(int)
        default: return nil
        }
    }
}
