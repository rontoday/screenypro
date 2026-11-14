import CoreGraphics
import Foundation
import ScreenCaptureKit
import ScreenyCore

/// Errors thrown or reported (`onStop`) by the ScreenyCapture module.
public enum CaptureError: LocalizedError {
    /// The user has not granted the privacy permission.
    case permissionDenied(PermissionKind)
    /// The display is not connected any more.
    case displayNotFound(UInt32)
    /// The window was closed, minimized or is not shareable.
    case windowNotFound(UInt32)
    /// No camera is connected.
    case noCameraAvailable
    /// The selected camera is not connected.
    case cameraNotFound(String)
    /// The camera exists but cannot be opened (used by another app, failed to start).
    case cameraUnavailable(name: String, reason: String)
    /// The microphone could not be started.
    case microphoneFailed(String)
    /// The capture configuration is not valid.
    case invalidConfiguration(String)
    /// The capture stream failed to start or to update.
    case streamFailed(String)
    /// The user stopped sharing from the system UI (menu bar / Control Center).
    case stoppedByUser
    /// macOS stopped the stream (for example the display went away or the session locked).
    case stoppedBySystem
    /// The stream stopped for another reason (for example the captured window was closed).
    case streamStopped(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(.screenRecording):
            return "ScreenyPro does not have permission to record the screen."
        case .permissionDenied(.camera):
            return "ScreenyPro does not have permission to use the camera."
        case .permissionDenied(.microphone):
            return "ScreenyPro does not have permission to use the microphone."
        case .displayNotFound:
            return "The selected display is not available any more."
        case .windowNotFound:
            return "The selected window is not available any more. It may have been closed or minimized."
        case .noCameraAvailable:
            return "No camera is connected."
        case .cameraNotFound:
            return "The selected camera is not connected."
        case let .cameraUnavailable(name, reason):
            return "The camera \"\(name)\" could not be started: \(reason)"
        case let .microphoneFailed(reason):
            return "The microphone could not be started: \(reason)"
        case let .invalidConfiguration(reason):
            return "Invalid capture settings: \(reason)"
        case let .streamFailed(reason):
            return "Screen capture failed: \(reason)"
        case .stoppedByUser:
            return "Screen sharing was stopped from the macOS menu bar."
        case .stoppedBySystem:
            return "macOS stopped the screen capture."
        case let .streamStopped(reason):
            return "Screen capture stopped: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .permissionDenied(.screenRecording):
            return "Allow ScreenyPro in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen ScreenyPro."
        case .permissionDenied(.camera):
            return "Allow ScreenyPro in System Settings > Privacy & Security > Camera."
        case .permissionDenied(.microphone):
            return "Allow ScreenyPro in System Settings > Privacy & Security > Microphone."
        case .displayNotFound, .windowNotFound:
            return "Choose another source."
        case .noCameraAvailable, .cameraNotFound:
            return "Connect a camera or choose another one."
        case .cameraUnavailable:
            return "Close other apps that use the camera and try again."
        case .microphoneFailed:
            return "Check the microphone permission or choose another microphone."
        default:
            return nil
        }
    }

    /// Converts ScreenCaptureKit errors into `CaptureError`. Other errors become `.streamFailed`.
    static func wrap(_ error: Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain {
            switch nsError.code {
            case SCStreamError.Code.userDeclined.rawValue:
                return .permissionDenied(.screenRecording)
            case SCStreamError.Code.userStopped.rawValue:
                return .stoppedByUser
            case SCStreamError.Code.systemStoppedStream.rawValue:
                return .stoppedBySystem
            case SCStreamError.Code.failedToStartMicrophoneCapture.rawValue:
                return .microphoneFailed(nsError.localizedDescription)
            default:
                break
            }
        }
        if !CGPreflightScreenCaptureAccess() {
            return .permissionDenied(.screenRecording)
        }
        return .streamFailed(nsError.localizedDescription)
    }

    /// Same as `wrap`, for errors from a running stream (`didStopWithError`).
    static func wrapStop(_ error: Error) -> CaptureError {
        let wrapped = wrap(error)
        if case let .streamFailed(reason) = wrapped {
            return .streamStopped(reason)
        }
        return wrapped
    }
}
