import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenyCore

/// Timer-driven compositor. On every tick it samples the latest screen and camera frames,
/// composes the styled canvas and calls `onFrame` on the render queue.
///
/// Tick times are snapped to a constant-frame-rate grid on the host clock, so the recorded video has an
/// even cadence. If a frame is still rendering when the next tick is due, that tick is skipped (never queued).
public final class FramePipeline: RenderPipeline, @unchecked Sendable {
    private let screenBox: LatestFrameBox
    private let cameraBox: LatestFrameBox
    private let queue = DispatchQueue(label: "cz.comakers.screenypro.render", qos: .userInteractive)
    private let log = Logger(subsystem: "cz.comakers.screenypro", category: "pipeline")

    // Guarded by `lock`.
    private let lock = NSLock()
    private var _style = StyleSettings()
    private var _onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private var generation: UInt64 = 0
    private var isRunning = false

    // Render queue only.
    private var timer: DispatchSourceTimer?
    private var compositor: Compositor?
    private var compositorFailed = false
    private var fps = 30
    private var gridOrigin: Int64 = 0
    private var lastTickIndex: Int64 = -1
    private var lastDeliveredTime: Int64 = .min
    private var stats = Stats()

    /// Render statistics (render queue). Internal: used by benchmarks and debug logs.
    struct Stats {
        /// Frames after the warm-up (the first frames after `start` compile GPU kernels and bake caches).
        var frames = 0
        var warmupFrames = 0
        var warmupSkippedTicks = 0
        var skippedTicks = 0
        var poolExhausted = 0
        var renderErrors = 0
        var totalRenderTime: Double = 0
        var maxRenderTime: Double = 0
        var lastLog = Date()

        var averageRenderTime: Double { frames > 0 ? totalRenderTime / Double(frames) : 0 }
    }

    static let warmupFrameCount = 3

    public init(screen: LatestFrameBox, camera: LatestFrameBox) {
        screenBox = screen
        cameraBox = camera
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    public var style: StyleSettings {
        get { lock.withLock { _style } }
        set { lock.withLock { _style = newValue } }
    }

    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    public func start(canvasSize: CGSize, fps requestedFPS: Int) {
        let fps = clamp(requestedFPS, 1, 120)
        let size = CGSize(width: max(2, canvasSize.width), height: max(2, canvasSize.height))
        let gen: UInt64 = lock.withLock {
            isRunning = true
            generation &+= 1
            return generation
        }
        queue.async { [weak self] in
            self?.configure(canvas: size, fps: fps, generation: gen)
        }
    }

    public func stop() {
        lock.withLock {
            isRunning = false
            generation &+= 1
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.logStats(force: true)
        }
    }

    /// Statistics snapshot (blocks until the render queue is free; for tests and benchmarks only).
    var statistics: Stats { queue.sync { stats } }

    // MARK: Render queue

    private func configure(canvas: CGSize, fps: Int, generation gen: UInt64) {
        guard lock.withLock({ isRunning && generation == gen }) else { return }
        if compositor == nil && !compositorFailed {
            do {
                compositor = try Compositor()
            } catch {
                compositorFailed = true
                log.fault("Compositor unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let compositor else { return }
        do {
            try compositor.setCanvas(canvas)
        } catch {
            log.error("Cannot set canvas \(Int(canvas.width))x\(Int(canvas.height)): \(error.localizedDescription, privacy: .public)")
            return
        }

        self.fps = fps
        timer?.cancel()
        gridOrigin = Self.hostNanoseconds()
        lastTickIndex = -1
        stats = Stats()

        let intervalNs = Int(1_000_000_000 / fps)
        let newTimer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        newTimer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs), leeway: .nanoseconds(0))
        newTimer.setEventHandler { [weak self] in
            self?.tick(generation: gen)
        }
        timer = newTimer
        newTimer.resume()
    }

    private func tick(generation gen: UInt64) {
        guard lock.withLock({ isRunning && generation == gen }), let compositor else { return }

        // Snap to the frame grid. A late tick that lands on an already used slot is skipped.
        let now = Self.hostNanoseconds()
        let intervalNs = 1_000_000_000.0 / Double(fps)
        let index = Int64((Double(now - gridOrigin) / intervalNs).rounded())
        guard index > lastTickIndex else { return }
        if lastTickIndex >= 0, index > lastTickIndex + 1 {
            let missed = Int(index - lastTickIndex - 1)
            if stats.warmupFrames < Self.warmupFrameCount {
                stats.warmupSkippedTicks += missed
            } else {
                stats.skippedTicks += missed
            }
        }
        lastTickIndex = index
        var tickNs = gridOrigin + Int64((Double(index) * intervalNs).rounded())
        if tickNs <= lastDeliveredTime { tickNs = lastDeliveredTime + 1 }
        let time = CMTime(value: tickNs, timescale: 1_000_000_000)

        let (style, handler) = lock.withLock { (_style, _onFrame) }
        let started = CACurrentMediaTimeCompat()
        var output: CVPixelBuffer?
        var renderFailed = false
        autoreleasepool {
            do {
                output = try compositor.render(
                    screen: screenBox.get(),
                    camera: cameraBox.get(),
                    style: style,
                    time: time
                )
            } catch {
                renderFailed = true
                log.error("Frame render failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let elapsed = CACurrentMediaTimeCompat() - started

        guard let output else {
            if renderFailed { stats.renderErrors += 1 } else { stats.poolExhausted += 1 }
            return
        }
        if stats.warmupFrames < Self.warmupFrameCount {
            stats.warmupFrames += 1
        } else {
            stats.frames += 1
            stats.totalRenderTime += elapsed
            stats.maxRenderTime = max(stats.maxRenderTime, elapsed)
        }
        logStats(force: false)

        // Do not deliver after stop() / a reconfiguring start() returned.
        guard lock.withLock({ isRunning && generation == gen }) else { return }
        lastDeliveredTime = tickNs
        handler?(output, time)
    }

    private func logStats(force: Bool) {
        guard force || Date().timeIntervalSince(stats.lastLog) >= 10 else { return }
        stats.lastLog = Date()
        if stats.frames > 0 {
            log.debug("""
            render: \(self.stats.frames) frames, avg \(self.stats.averageRenderTime * 1000, format: .fixed(precision: 2)) ms, \
            max \(self.stats.maxRenderTime * 1000, format: .fixed(precision: 2)) ms, skipped ticks \(self.stats.skippedTicks), \
            pool exhausted \(self.stats.poolExhausted)
            """)
        }
    }

    static func hostNanoseconds() -> Int64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeConvertScale(t, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }
}

@inline(__always)
func CACurrentMediaTimeCompat() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
