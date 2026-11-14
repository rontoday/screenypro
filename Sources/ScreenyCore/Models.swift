import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Capture sources

/// What the user records. IDs are `CGDirectDisplayID` / `CGWindowID`.
public enum CaptureSource: Hashable, Codable, Sendable {
    case display(UInt32)
    case window(UInt32)
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    /// Frame in global screen points.
    public let frame: CGRect
    /// Backing scale factor (2.0 on Retina).
    public let scale: Double

    public init(id: UInt32, name: String, frame: CGRect, scale: Double) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
    }
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let title: String
    public let appName: String
    public let bundleID: String?
    public let pid: Int32
    /// Frame in global screen points.
    public let frame: CGRect

    public init(id: UInt32, title: String, appName: String, bundleID: String?, pid: Int32, frame: CGRect) {
        self.id = id
        self.title = title
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.frame = frame
    }
}

public struct ShareableContent: Sendable {
    public var displays: [DisplayInfo]
    /// Only normal, on-screen, titled windows of other apps. Sorted by app name.
    public var windows: [WindowInfo]

    public init(displays: [DisplayInfo], windows: [WindowInfo]) {
        self.displays = displays
        self.windows = windows
    }
}

/// A camera or a microphone. `id` is `AVCaptureDevice.uniqueID`.
public struct MediaDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CaptureConfig: Equatable, Sendable {
    public var source: CaptureSource
    public var fps: Int
    /// Upper bound for the captured frame size in pixels. The engine keeps the source aspect ratio
    /// and never upscales above the native pixel size.
    public var maxPixelSize: CGSize
    public var showsCursor: Bool
    public var capturesSystemAudio: Bool
    /// `nil` = do not capture a microphone.
    public var microphoneID: String?
    /// Only for a `.display` source: capture just this part of the display.
    /// In points, relative to the display, origin TOP-left. `nil` = the whole display. Ignored for windows.
    public var cropRect: CGRect?

    public init(
        source: CaptureSource,
        fps: Int = 30,
        maxPixelSize: CGSize = CGSize(width: 3840, height: 2160),
        showsCursor: Bool = true,
        capturesSystemAudio: Bool = true,
        microphoneID: String? = nil,
        cropRect: CGRect? = nil
    ) {
        self.cropRect = cropRect
        self.source = source
        self.fps = fps
        self.maxPixelSize = maxPixelSize
        self.showsCursor = showsCursor
        self.capturesSystemAudio = capturesSystemAudio
        self.microphoneID = microphoneID
    }
}

// MARK: - Frames

/// One video frame. `pixelBuffer` is 32BGRA and IOSurface-backed.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// The useful part of the buffer, in pixels, origin TOP-left.
    /// For a window capture the buffer can be larger than the window content.
    public let contentRect: CGRect
    /// Host-clock time of the frame.
    public let time: CMTime

    public init(pixelBuffer: CVPixelBuffer, contentRect: CGRect, time: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.contentRect = contentRect
        self.time = time
    }
}

/// Thread-safe box with the most recent frame of a source. Writers: capture engines. Reader: render pipeline.
public final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VideoFrame?

    public init() {}

    public func set(_ newFrame: VideoFrame?) {
        lock.lock()
        frame = newFrame
        lock.unlock()
    }

    public func get() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

public enum AudioKind: Sendable {
    case system
    case microphone
}

// MARK: - Permissions

public enum PermissionKind: Sendable, CaseIterable {
    case screenRecording
    case camera
    case microphone
}

public enum PermissionStatus: Sendable {
    case granted
    case denied
    case notDetermined
}

// MARK: - Output

public enum OutputResolution: String, Codable, CaseIterable, Sendable {
    case p1080
    case p1440
    case p2160

    public var size: CGSize {
        switch self {
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p1440: return CGSize(width: 2560, height: 1440)
        case .p2160: return CGSize(width: 3840, height: 2160)
        }
    }

    public var label: String {
        switch self {
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    /// Plays everywhere, including every browser. Default.
    case h264
    /// Smaller files, weaker browser support.
    case hevc
}

/// Shape of the output canvas.
public enum CanvasFormat: String, Codable, CaseIterable, Sendable {
    /// 16:9, for client screencasts.
    case landscape
    /// 9:16, for Reels / Shorts / TikTok. Screen content on top, camera below (see `PortraitLayout`).
    case portrait
}

public struct OutputSettings: Codable, Equatable, Sendable {
    public var resolution: OutputResolution
    public var fps: Int
    public var codec: VideoCodec
    public var format: CanvasFormat

    public init(resolution: OutputResolution = .p1440, fps: Int = 30, codec: VideoCodec = .h264, format: CanvasFormat = .landscape) {
        self.resolution = resolution
        self.fps = fps
        self.codec = codec
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? .p1440
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? .h264
        format = try c.decodeIfPresent(CanvasFormat.self, forKey: .format) ?? .landscape
    }

    /// Canvas size in pixels. Portrait swaps width and height (1080p → 1080×1920).
    public var canvasSize: CGSize {
        let size = resolution.size
        return format == .portrait ? CGSize(width: size.height, height: size.width) : size
    }
}

public struct RecordingConfig: Sendable {
    /// Final `.mp4` file.
    public var outputURL: URL
    public var canvasSize: CGSize
    public var fps: Int
    public var codec: VideoCodec
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool

    public init(outputURL: URL, canvasSize: CGSize, fps: Int, codec: VideoCodec, hasSystemAudio: Bool, hasMicrophone: Bool) {
        self.outputURL = outputURL
        self.canvasSize = canvasSize
        self.fps = fps
        self.codec = codec
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
    }
}
