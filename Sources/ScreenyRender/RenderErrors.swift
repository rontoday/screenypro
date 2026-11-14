import Foundation

/// Errors of the compositor and the render pipeline.
public enum CompositorError: LocalizedError {
    case noMetalDevice
    case pixelBufferCreationFailed(code: Int32)
    case renderFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "No Metal device is available for rendering."
        case .pixelBufferCreationFailed(let code):
            return "Could not create a pixel buffer for the composed frame (CoreVideo error \(code))."
        case .renderFailed(let underlying):
            return "Rendering the composed frame failed: \(underlying.localizedDescription)"
        }
    }
}

/// Errors of `MovieRecorder`.
public enum RecorderError: LocalizedError {
    case alreadyStarted
    case notRecording
    case cancelled
    case invalidConfiguration(String)
    case cannotCreateDirectory(URL, underlying: Error)
    case cannotCreateWriter(URL, underlying: Error)
    case cannotAddInput(String)
    case writerFailed(underlying: Error?)
    case noVideoFrames
    case finalizeFailed(String, underlying: Error?)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "The recorder was already started."
        case .notRecording:
            return "The recorder is not recording."
        case .cancelled:
            return "The recording was cancelled."
        case .invalidConfiguration(let reason):
            return "Invalid recording configuration: \(reason)."
        case .cannotCreateDirectory(let url, let underlying):
            return "Could not create the folder \(url.path): \(underlying.localizedDescription)"
        case .cannotCreateWriter(let url, let underlying):
            return "Could not create the movie file \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .cannotAddInput(let kind):
            return "The movie writer does not accept the \(kind) track settings."
        case .writerFailed(let underlying):
            return "Writing the movie failed: \(underlying?.localizedDescription ?? "unknown error")"
        case .noVideoFrames:
            return "Nothing was recorded: no video frames arrived."
        case .finalizeFailed(let step, let underlying):
            if let underlying {
                return "Could not finish the movie (\(step)): \(underlying.localizedDescription)"
            }
            return "Could not finish the movie (\(step))."
        }
    }
}

/// A failed check of `SelfTest.run(outputURL:portrait:)`.
public struct SelfTestError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { "Self-test failed: \(message)" }
}
