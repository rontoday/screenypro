import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenyCore

/// Privacy permissions and microphone discovery.
public final class MacSystemAccess: SystemAccess, @unchecked Sendable {
    /// macOS cannot tell "denied" from "never asked" for screen recording. We remember that we asked once.
    private static let screenRequestKey = "ScreenyCapture.didRequestScreenRecording"

    public init() {}

    public func microphones() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        return discovery.devices.compactMap { device in
            guard device.isConnected, seen.insert(device.uniqueID).inserted else { return nil }
            return MediaDevice(id: device.uniqueID, name: device.localizedName)
        }
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: Self.screenRequestKey) ? .denied : .notDetermined
        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            // Shows the system prompt only the first time; later calls return at once.
            let granted = CGRequestScreenCaptureAccess()
            UserDefaults.standard.set(true, forKey: Self.screenRequestKey)
            return granted ? .granted : status(.screenRecording)
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            return status(.camera)
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            return status(.microphone)
        }
    }

    public func openSettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        if Thread.isMainThread {
            NSWorkspace.shared.open(url)
        } else {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}
