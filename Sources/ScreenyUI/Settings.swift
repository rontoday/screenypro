import Foundation
import ScreenyCore

enum SourceKind: String, Codable, Sendable {
    case display
    case window
}

/// Everything the user can change, persisted in `UserDefaults` as JSON.
struct AppSettings: Codable, Equatable {
    var style = StyleSettings()
    var output = OutputSettings()
    var sourceKind: SourceKind = .display
    var displayID: UInt32?
    /// Window IDs do not survive a relaunch, so the window is matched again by app and title.
    var windowID: UInt32?
    var windowBundleID: String?
    var windowTitle: String?
    /// `nil` = system default camera.
    var cameraDeviceID: String?
    var microphoneEnabled = true
    /// `nil` = first available microphone.
    var microphoneID: String?
    var capturesSystemAudio = true
    var showsCursor = true
    /// Last solid background color, so the solid swatch keeps it while a gradient is selected.
    var solidColor = RGBA(hex: 0x3D4250)
    /// Last background image, so the image swatch keeps it while a gradient is selected.
    var backgroundImage: URL?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case style, output, sourceKind, displayID, windowID, windowBundleID, windowTitle
        case cameraDeviceID, microphoneEnabled, microphoneID, capturesSystemAudio, showsCursor
        case solidColor, backgroundImage
    }

    /// Tolerant decoding: a missing or broken key falls back to its default instead of
    /// resetting all settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        style = (try? c.decodeIfPresent(StyleSettings.self, forKey: .style)) ?? d.style
        output = (try? c.decodeIfPresent(OutputSettings.self, forKey: .output)) ?? d.output
        sourceKind = (try? c.decodeIfPresent(SourceKind.self, forKey: .sourceKind)) ?? d.sourceKind
        displayID = try? c.decodeIfPresent(UInt32.self, forKey: .displayID)
        windowID = try? c.decodeIfPresent(UInt32.self, forKey: .windowID)
        windowBundleID = try? c.decodeIfPresent(String.self, forKey: .windowBundleID)
        windowTitle = try? c.decodeIfPresent(String.self, forKey: .windowTitle)
        cameraDeviceID = try? c.decodeIfPresent(String.self, forKey: .cameraDeviceID)
        microphoneEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .microphoneEnabled)) ?? d.microphoneEnabled
        microphoneID = try? c.decodeIfPresent(String.self, forKey: .microphoneID)
        capturesSystemAudio = (try? c.decodeIfPresent(Bool.self, forKey: .capturesSystemAudio)) ?? d.capturesSystemAudio
        showsCursor = (try? c.decodeIfPresent(Bool.self, forKey: .showsCursor)) ?? d.showsCursor
        solidColor = (try? c.decodeIfPresent(RGBA.self, forKey: .solidColor)) ?? d.solidColor
        backgroundImage = try? c.decodeIfPresent(URL.self, forKey: .backgroundImage)
        sanitize()
    }

    /// Clamps values that came from disk into the ranges the UI and the compositor expect.
    mutating func sanitize() {
        style.padding = min(max(style.padding, 0), 0.15)
        style.cornerRadius = min(max(style.cornerRadius, 0), 0.05)
        style.shadow = min(max(style.shadow, 0), 1)
        style.camera.size = min(max(style.camera.size, 0.15), 0.45)
        if output.fps != 30 && output.fps != 60 { output.fps = 30 }
        if case .image(let url) = style.background, !FileManager.default.fileExists(atPath: url.path) {
            style.background = .gradient(GradientPreset.all[0].id)
        }
    }
}

enum SettingsStore {
    static let key = "ScreenyPro.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
