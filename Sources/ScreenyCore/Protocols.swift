import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// The UI module depends only on these protocols. The executable target wires the concrete types.
// Do not change these signatures without a strong reason: three modules are built against them in parallel.

// MARK: - Capture (implemented in ScreenyCapture)

public protocol ScreenCapturing: AnyObject {
    /// Latest captured screen/window frame. Stays unchanged while the screen content is static.
    var frames: LatestFrameBox { get }
    /// Audio sample buffers with host-clock timestamps. Called on a background queue.
    var onAudio: ((AudioKind, CMSampleBuffer) -> Void)? { get set }
    /// The stream stopped by itself (window closed, display removed, user stopped sharing). Called on the main queue.
    var onStop: ((Error?) -> Void)? { get set }

    func listContent() async throws -> ShareableContent
    /// A still image of a source for the source picker. `nil` on failure.
    func thumbnail(for source: CaptureSource, maxSize: CGSize) async -> CGImage?
    /// Starts capturing. When already running, applies the new config (restarts the stream only if needed).
    func start(_ config: CaptureConfig) async throws
    func stop() async
}

public protocol CameraCapturing: AnyObject {
    /// Latest camera frame (not mirrored; the compositor mirrors).
    var frames: LatestFrameBox { get }
    func devices() -> [MediaDevice]
    /// `nil` = system default camera. When already running with another device, switches to the new one.
    func start(deviceID: String?) async throws
    func stop() async
}

public protocol SystemAccess: AnyObject {
    func microphones() -> [MediaDevice]
    func status(_ kind: PermissionKind) -> PermissionStatus
    /// Shows the system prompt when possible. Returns the status after the request.
    func request(_ kind: PermissionKind) async -> PermissionStatus
    /// Opens the matching pane of System Settings > Privacy & Security.
    func openSettings(for kind: PermissionKind)
}

// MARK: - Render and record (implemented in ScreenyRender)

/// Timer-driven compositor. On every tick it takes the latest screen and camera frames,
/// composes the styled canvas and delivers it.
public protocol RenderPipeline: AnyObject {
    /// Thread-safe. Can change at any time, also while recording.
    var style: StyleSettings { get set }
    /// A fresh 32BGRA IOSurface-backed buffer of the canvas size and the host-clock time of the tick.
    /// Called on the pipeline's render queue. The receiver may retain the buffer.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    /// Starts ticking. When already running, switches to the new canvas size / fps.
    func start(canvasSize: CGSize, fps: Int)
    func stop()
}

public protocol Recording: AnyObject {
    /// Prepares the writer. Recording time starts at the first appended video frame.
    func start() throws
    /// All append calls are thread-safe and non-blocking.
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime)
    func appendAudio(_ kind: AudioKind, _ sampleBuffer: CMSampleBuffer)
    func pause()
    func resume()
    var isPaused: Bool { get }
    /// Recorded time without pauses, in seconds.
    var duration: TimeInterval { get }
    /// Stops, mixes the audio into one track and writes the final web-ready `.mp4`. Returns its URL.
    func finish() async throws -> URL
    /// Stops and deletes all files.
    func cancel() async
}

public protocol PreviewDisplaying: AnyObject {
    /// Shows a composed frame, aspect-fit. Thread-safe.
    func display(_ pixelBuffer: CVPixelBuffer)
}

// MARK: - Wiring

public struct AppDependencies {
    public var makeScreenCapture: () -> ScreenCapturing
    public var makeCamera: () -> CameraCapturing
    public var system: SystemAccess
    /// Arguments: screen frame box, camera frame box.
    public var makePipeline: (LatestFrameBox, LatestFrameBox) -> RenderPipeline
    public var makeRecorder: (RecordingConfig) -> Recording
    /// Must be called on the main thread.
    public var makePreviewView: () -> NSView & PreviewDisplaying
    public var cloud: CloudUploading

    public init(
        makeScreenCapture: @escaping () -> ScreenCapturing,
        makeCamera: @escaping () -> CameraCapturing,
        system: SystemAccess,
        makePipeline: @escaping (LatestFrameBox, LatestFrameBox) -> RenderPipeline,
        makeRecorder: @escaping (RecordingConfig) -> Recording,
        makePreviewView: @escaping () -> NSView & PreviewDisplaying,
        cloud: CloudUploading
    ) {
        self.cloud = cloud
        self.makeScreenCapture = makeScreenCapture
        self.makeCamera = makeCamera
        self.system = system
        self.makePipeline = makePipeline
        self.makeRecorder = makeRecorder
        self.makePreviewView = makePreviewView
    }
}
