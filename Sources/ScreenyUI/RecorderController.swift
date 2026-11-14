import AppKit
import CoreMedia
import Foundation
import QuartzCore
import ScreenyCore

/// The recording state machine and the owner of the live capture → render → preview/record graph.
///
/// `idle (preview running) → countdown (3-2-1) → recording ⇄ paused → finishing → finished(url) → idle`
///
/// Threading: all state lives on the main actor. Video frames and audio buffers arrive on background
/// queues and go straight to the preview and to `RecorderSink` (lock-guarded), never through the main actor.
@MainActor
final class RecorderController: ObservableObject {
    enum State: Equatable {
        case idle
        case countdown(Int)
        case recording
        case paused
        case finishing
        case finished(URL)

        var isCapturingSession: Bool { self == .recording || self == .paused }
        var isCountdown: Bool { if case .countdown = self { return true } else { return false } }
        /// Settings that shape the recording file can change only here.
        var allowsOutputChanges: Bool {
            switch self {
            case .idle, .finished: return true
            default: return false
            }
        }
    }

    struct Banner: Equatable {
        enum Kind { case error, info }
        let kind: Kind
        let message: String
    }

    struct AlertInfo {
        let title: String
        let message: String
    }

    // MARK: Published state

    @Published private(set) var state: State = .idle
    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var content = ShareableContent(displays: [], windows: [])
    @Published private(set) var cameras: [MediaDevice] = []
    @Published private(set) var microphones: [MediaDevice] = []
    @Published private(set) var screenPermission: PermissionStatus = .notDetermined
    @Published private(set) var cameraPermission: PermissionStatus = .notDetermined
    @Published private(set) var microphonePermission: PermissionStatus = .notDetermined
    @Published private(set) var thumbnails: [CaptureSource: NSImage] = [:]
    @Published private(set) var isRefreshingContent = false
    @Published private(set) var isRequestingScreenAccess = false
    /// True after a "Grant access" attempt that did not take effect, so the onboarding can explain the restart.
    @Published private(set) var screenAccessNeedsRestart = false
    @Published var banner: Banner?
    /// True while `finishing` is a discard, not a save.
    @Published private(set) var isDiscarding = false

    let meter = LevelMeterModel()
    let clock = ElapsedClock()
    let previewView: NSView & PreviewDisplaying

    /// Shows an alert (the app delegate decides between a sheet and a standalone alert).
    var onAlert: ((AlertInfo) -> Void)?

    // MARK: Engine

    private let dependencies: AppDependencies
    private let screen: ScreenCapturing
    private let camera: CameraCapturing
    private let pipeline: RenderPipeline
    private let sink = RecorderSink()
    private var recorder: Recording?
    private var activity: NSObjectProtocol?

    private var sessionStarted = false
    private var appliedPipeline: (size: CGSize, fps: Int)?
    private var appliedCapture: CaptureConfig?
    private var captureTask: Task<Void, Never>?
    private var captureDebounce: Task<Void, Never>?
    private var captureGeneration = 0
    private var cameraTask: Task<Void, Never>?
    private var cameraGeneration = 0
    private var styleTask: Task<Void, Never>?
    private var lastStyleApply: CFTimeInterval = 0
    private var persistTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var lastContentRefresh: CFTimeInterval = 0
    private var countdownTask: Task<Void, Never>?
    private var restoredWindowSelection = false
    private var terminationPending = false

    init(dependencies: AppDependencies) {
        let screen = dependencies.makeScreenCapture()
        let camera = dependencies.makeCamera()
        self.dependencies = dependencies
        self.screen = screen
        self.camera = camera
        self.pipeline = dependencies.makePipeline(screen.frames, camera.frames)
        self.previewView = dependencies.makePreviewView()
        self.settings = SettingsStore.load()
        wireCallbacks()
    }

    private var system: SystemAccess { dependencies.system }

    // MARK: - Launch and permissions

    func launch() {
        refreshPermissions()
        if screenPermission == .granted {
            startSession()
        }
    }

    func refreshPermissions() {
        screenPermission = system.status(.screenRecording)
        cameraPermission = system.status(.camera)
        microphonePermission = system.status(.microphone)
    }

    /// "Grant access" in the onboarding.
    func requestScreenAccess() {
        guard !isRequestingScreenAccess else { return }
        isRequestingScreenAccess = true
        Task {
            let status = await system.request(.screenRecording)
            isRequestingScreenAccess = false
            refreshPermissions()
            if status == .granted || screenPermission == .granted {
                startSession()
            } else {
                screenAccessNeedsRestart = true
            }
        }
    }

    func openSettings(for kind: PermissionKind) {
        system.openSettings(for: kind)
        if kind == .screenRecording { screenAccessNeedsRestart = true }
    }

    /// macOS applies a new screen recording permission only to a fresh process.
    func quitAndReopen() {
        persistNow()
        let bundleURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let target: String
        let launch: String
        if bundleURL.pathExtension == "app" {
            target = bundleURL.path
            launch = "/usr/bin/open -n \"$0\""
        } else {
            target = Bundle.main.executablePath ?? CommandLine.arguments[0]
            launch = "\"$0\" >/dev/null 2>&1 &"
        }
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; \(launch)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, target]
        do {
            try process.run()
        } catch {
            showAlert("Could not restart ScreenyPro", error.localizedDescription + "\nPlease open the app again by hand.")
        }
        NSApp.terminate(nil)
    }

    private func startSession() {
        guard !sessionStarted, screenPermission == .granted else { return }
        sessionStarted = true
        meter.start()
        applyPipeline()
        pipeline.style = settings.style
        lastStyleApply = CACurrentMediaTime()
        Task {
            await requestOptionalPermissionsIfNeeded()
            refreshDevices(applyChanges: false)
            await refreshContent()
            applyCaptureNow()
            applyCamera()
        }
    }

    private func requestOptionalPermissionsIfNeeded() async {
        if settings.style.camera.enabled, system.status(.camera) == .notDetermined {
            _ = await system.request(.camera)
        }
        if settings.microphoneEnabled, system.status(.microphone) == .notDetermined {
            _ = await system.request(.microphone)
        }
        refreshPermissions()
    }

    // MARK: - Callbacks from the engine

    private func wireCallbacks() {
        let preview = PreviewSink(previewView)
        let sink = self.sink
        pipeline.onFrame = { buffer, time in
            preview.display(buffer)
            sink.appendVideo(buffer, at: time)
        }
        let tap = meter.tap
        screen.onAudio = { kind, sampleBuffer in
            sink.appendAudio(kind, sampleBuffer)
            if kind == .microphone { tap.ingest(sampleBuffer) }
        }
        screen.onStop = { [weak self] error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.captureDidStop(message: message)
            }
        }
    }

    private func captureDidStop(message: String?) {
        NSLog("ScreenyPro: capture stopped: \(message ?? "no error")")
        appliedCapture = nil
        if state.isCapturingSession {
            stopRecording(reason: message ?? "The recorded window or display is no longer available.")
        } else if state.isCountdown {
            cancelCountdown()
        }
        // Re-list the sources (a vanished window falls back to the main display) and restart the stream.
        // If the restart fails, `applyCaptureNow` shows the error.
        Task {
            await refreshContent(force: true)
            applyCaptureNow()
        }
    }

    // MARK: - Main window events

    func mainWindowDidBecomeKey() {
        refreshPermissions()
        if screenPermission == .granted && !sessionStarted {
            startSession()
            return
        }
        guard sessionStarted, state.allowsOutputChanges else { return }
        refreshDevices(applyChanges: true)
        if CACurrentMediaTime() - lastContentRefresh > 1.5 {
            Task { await refreshContent() }
        }
    }

    /// Refresh button in the Source section.
    func reloadSources() {
        guard sessionStarted else { return }
        refreshDevices(applyChanges: true)
        Task { await refreshContent(force: true, reloadThumbnails: true) }
    }

    private func refreshDevices(applyChanges: Bool) {
        let oldCamera = effectiveCameraID
        let oldMic = effectiveMicrophoneID
        cameras = camera.devices()
        microphones = system.microphones()
        guard applyChanges else { return }
        if oldCamera != effectiveCameraID { applyCamera() }
        if oldMic != effectiveMicrophoneID { scheduleCaptureApply() }
    }

    func refreshContent(force: Bool = false, reloadThumbnails: Bool = false) async {
        guard screenPermission == .granted else { return }
        if let running = refreshTask {
            await running.value
            if !force { return }
        }
        let task = Task { await performContentRefresh(reloadThumbnails: reloadThumbnails) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performContentRefresh(reloadThumbnails: Bool) async {
        isRefreshingContent = true
        defer { isRefreshingContent = false }
        do {
            content = try await screen.listContent()
            lastContentRefresh = CACurrentMediaTime()
        } catch {
            banner = Banner(kind: .error, message: "Could not list displays and windows: \(error.localizedDescription)")
            return
        }
        reconcileSelection()
        loadThumbnails(reload: reloadThumbnails)
    }

    /// Keeps the selected source valid. A window that disappeared while idle falls back to the main display.
    private func reconcileSelection() {
        var s = settings
        let windows = content.windows
        if s.sourceKind == .window {
            if let id = s.windowID, let window = windows.first(where: { $0.id == id }) {
                s.windowTitle = window.title
                s.windowBundleID = window.bundleID
            } else if !restoredWindowSelection, let match = matchSavedWindow() {
                s.windowID = match.id
                s.windowTitle = match.title
                s.windowBundleID = match.bundleID
            } else {
                let hadWindow = restoredWindowSelection && s.windowID != nil
                s.sourceKind = .display
                s.windowID = nil
                s.displayID = mainDisplayID
                if hadWindow, state.allowsOutputChanges {
                    banner = Banner(kind: .info, message: "The selected window is gone. Recording the main display.")
                }
            }
        }
        restoredWindowSelection = true
        if let id = s.displayID, content.displays.contains(where: { $0.id == id }) {
            // still valid
        } else {
            s.displayID = mainDisplayID
        }
        if s != settings { settings = s }
    }

    private func matchSavedWindow() -> WindowInfo? {
        guard let bundle = settings.windowBundleID else { return nil }
        let sameApp = content.windows.filter { $0.bundleID == bundle }
        return sameApp.first { $0.title == settings.windowTitle } ?? sameApp.first
    }

    private var mainDisplayID: UInt32? {
        let main = CGMainDisplayID()
        if content.displays.contains(where: { $0.id == main }) || content.displays.isEmpty { return main }
        return content.displays.first?.id
    }

    private func loadThumbnails(reload: Bool) {
        thumbnailTask?.cancel()
        let sources: [CaptureSource] = content.displays.map { .display($0.id) } + content.windows.map { .window($0.id) }
        let live = Set(sources)
        thumbnails = thumbnails.filter { live.contains($0.key) }
        let screen = self.screen
        thumbnailTask = Task { [weak self] in
            for source in sources {
                if Task.isCancelled { return }
                if !reload, case .window = source, self?.thumbnails[source] != nil { continue }
                guard let image = await screen.thumbnail(for: source, maxSize: CGSize(width: 480, height: 300)) else { continue }
                if Task.isCancelled { return }
                self?.thumbnails[source] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    // MARK: - Source selection

    var currentSource: CaptureSource {
        if settings.sourceKind == .window, let id = settings.windowID {
            return .window(id)
        }
        return .display(settings.displayID ?? mainDisplayID ?? CGMainDisplayID())
    }

    func selectSourceKind(_ kind: SourceKind) {
        guard kind != settings.sourceKind else { return }
        var s = settings
        if kind == .window {
            let valid = s.windowID.map { id in content.windows.contains { $0.id == id } } ?? false
            guard valid || !content.windows.isEmpty else {
                banner = Banner(kind: .info, message: "No windows to record. Open an app window and press Refresh.")
                return
            }
            if !valid, let first = content.windows.first {
                s.windowID = first.id
                s.windowTitle = first.title
                s.windowBundleID = first.bundleID
            }
        }
        s.sourceKind = kind
        settings = s
    }

    func selectDisplay(_ id: UInt32) {
        var s = settings
        s.sourceKind = .display
        s.displayID = id
        settings = s
    }

    func selectWindow(_ window: WindowInfo) {
        var s = settings
        s.sourceKind = .window
        s.windowID = window.id
        s.windowTitle = window.title
        s.windowBundleID = window.bundleID
        settings = s
    }

    /// The display shown in the countdown: the recorded display, or the one that holds the recorded window.
    var recordedDisplayID: UInt32? {
        switch currentSource {
        case .display(let id):
            return id
        case .window(let id):
            guard let window = content.windows.first(where: { $0.id == id }) else { return mainDisplayID }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return content.displays.first { $0.frame.contains(center) }?.id ?? mainDisplayID
        }
    }

    var sourceTitle: String {
        switch currentSource {
        case .display(let id):
            return content.displays.first { $0.id == id }?.name ?? "Display"
        case .window(let id):
            guard let window = content.windows.first(where: { $0.id == id }) else { return "Window" }
            return "\(window.appName) — \(window.title)"
        }
    }

    // MARK: - Applying settings

    private func settingsDidChange(from old: AppSettings) {
        let new = settings
        if new.style != old.style { scheduleStyleApply() }
        if new.output != old.output { applyPipeline() }
        if new.style.camera.enabled != old.style.camera.enabled || new.cameraDeviceID != old.cameraDeviceID {
            if new.style.camera.enabled && system.status(.camera) == .notDetermined {
                requestThen(.camera) { [weak self] in self?.applyCamera() }
            } else {
                applyCamera()
            }
        }
        if new.microphoneEnabled && !old.microphoneEnabled && system.status(.microphone) == .notDetermined {
            requestThen(.microphone) { [weak self] in self?.scheduleCaptureApply() }
        }
        scheduleCaptureApply()
        schedulePersist()
    }

    private func requestThen(_ kind: PermissionKind, _ then: @escaping @MainActor () -> Void) {
        Task {
            _ = await system.request(kind)
            refreshPermissions()
            then()
        }
    }

    private func applyPipeline() {
        guard sessionStarted, state.allowsOutputChanges || appliedPipeline == nil else { return }
        let size = settings.output.resolution.size
        let fps = settings.output.fps
        if let applied = appliedPipeline, applied.size == size, applied.fps == fps { return }
        pipeline.start(canvasSize: size, fps: fps)
        appliedPipeline = (size, fps)
    }

    /// Style changes are cheap but come in bursts from sliders: apply at most every 150 ms (first and last change always).
    private func scheduleStyleApply() {
        guard sessionStarted else { return }
        let interval: CFTimeInterval = 0.15
        let now = CACurrentMediaTime()
        if styleTask == nil && now - lastStyleApply >= interval {
            pipeline.style = settings.style
            lastStyleApply = now
            return
        }
        guard styleTask == nil else { return }
        let delay = max(0.01, interval - (now - lastStyleApply))
        styleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.styleTask = nil
            self.pipeline.style = self.settings.style
            self.lastStyleApply = CACurrentMediaTime()
        }
    }

    var effectiveMicrophoneID: String? {
        guard settings.microphoneEnabled, microphonePermission == .granted, !microphones.isEmpty else { return nil }
        if let id = settings.microphoneID, microphones.contains(where: { $0.id == id }) { return id }
        return microphones.first?.id
    }

    var effectiveCameraID: String? {
        guard let id = settings.cameraDeviceID, cameras.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The screen content rect on the canvas: no need to capture more pixels than that.
    private var captureMaxPixelSize: CGSize {
        let canvas = settings.output.resolution.size
        let inset = settings.style.padding * canvas.height
        let w = max(2, (canvas.width - 2 * inset).rounded(.up))
        let h = max(2, (canvas.height - 2 * inset).rounded(.up))
        return CGSize(width: w + w.truncatingRemainder(dividingBy: 2), height: h + h.truncatingRemainder(dividingBy: 2))
    }

    private var desiredCaptureConfig: CaptureConfig {
        CaptureConfig(
            source: currentSource,
            fps: settings.output.fps,
            maxPixelSize: captureMaxPixelSize,
            showsCursor: settings.showsCursor,
            capturesSystemAudio: settings.capturesSystemAudio,
            microphoneID: effectiveMicrophoneID
        )
    }

    private func scheduleCaptureApply() {
        guard sessionStarted else { return }
        captureDebounce?.cancel()
        captureDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.applyCaptureNow()
        }
    }

    /// Serialized: a new apply waits for the previous `start` to return; stale requests are skipped.
    private func applyCaptureNow() {
        guard sessionStarted, screenPermission == .granted else { return }
        captureDebounce?.cancel()
        captureDebounce = nil
        captureGeneration += 1
        let generation = captureGeneration
        let previous = captureTask
        let screen = self.screen
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.captureGeneration else { return }
            let config = self.desiredCaptureConfig
            guard config != self.appliedCapture else { return }
            do {
                try await screen.start(config)
                self.appliedCapture = config
                if self.banner?.kind == .error { self.banner = nil }
            } catch {
                self.appliedCapture = nil
                self.banner = Banner(kind: .error, message: "Could not start capture: \(error.localizedDescription)")
            }
        }
    }

    /// Waits until the capture runs with the latest settings.
    private func flushCapture() async {
        if captureDebounce != nil { applyCaptureNow() }
        await captureTask?.value
    }

    private func applyCamera() {
        guard sessionStarted else { return }
        let wanted = settings.style.camera.enabled && cameraPermission == .granted && !cameras.isEmpty
        let device = effectiveCameraID
        cameraGeneration += 1
        let generation = cameraGeneration
        let previous = cameraTask
        let camera = self.camera
        cameraTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.cameraGeneration else { return }
            if wanted {
                do {
                    try await camera.start(deviceID: device)
                } catch {
                    self.banner = Banner(kind: .error, message: "Could not start the camera: \(error.localizedDescription)")
                }
            } else {
                await camera.stop()
            }
        }
    }

    // MARK: - Persistence

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        SettingsStore.save(settings)
    }

    // MARK: - Recording

    /// ⌘⇧R, the Record button and the status item all land here.
    func toggleRecording() {
        switch state {
        case .idle, .finished:
            startCountdown()
        case .countdown:
            cancelCountdown()
        case .recording, .paused:
            stopRecording()
        case .finishing:
            break
        }
    }

    func startCountdown() {
        guard state.allowsOutputChanges else { return }
        guard screenPermission == .granted, sessionStarted else {
            showAlert("Screen recording is off", "Allow ScreenyPro to record the screen first, then try again.")
            return
        }
        banner = nil
        state = .countdown(3)
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard let self, self.state.isCountdown else { return }
                self.state = .countdown(n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            await self?.beginRecording()
        }
    }

    func cancelCountdown() {
        guard state.isCountdown else { return }
        countdownTask?.cancel()
        countdownTask = nil
        state = .idle
    }

    private func beginRecording() async {
        await flushCapture()
        guard state.isCountdown, !Task.isCancelled else { return }
        countdownTask = nil
        let url: URL
        do {
            url = try Self.makeOutputURL()
        } catch {
            state = .idle
            showAlert("Could not create the recordings folder", error.localizedDescription)
            return
        }
        let output = settings.output
        let config = RecordingConfig(
            outputURL: url,
            canvasSize: output.resolution.size,
            fps: output.fps,
            codec: output.codec,
            hasSystemAudio: appliedCapture?.capturesSystemAudio ?? settings.capturesSystemAudio,
            hasMicrophone: (appliedCapture?.microphoneID ?? effectiveMicrophoneID) != nil
        )
        let newRecorder = dependencies.makeRecorder(config)
        do {
            try newRecorder.start()
        } catch {
            state = .idle
            showAlert("Could not start recording", error.localizedDescription)
            return
        }
        recorder = newRecorder
        sink.set(newRecorder)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Recording the screen"
        )
        clock.start { [weak newRecorder] in newRecorder?.duration ?? 0 }
        state = .recording
    }

    func togglePause() {
        guard let recorder else { return }
        switch state {
        case .recording:
            recorder.pause()
            state = .paused
        case .paused:
            recorder.resume()
            state = .recording
        default:
            break
        }
    }

    /// Finishes the file. `reason` explains a stop the user did not ask for.
    func stopRecording(reason: String? = nil) {
        guard state.isCapturingSession, let recorder else { return }
        state = .finishing
        sink.set(nil)
        clock.stop()
        Task {
            var savedURL: URL?
            var failure: Error?
            do {
                savedURL = try await recorder.finish()
            } catch {
                failure = error
            }
            self.recorder = nil
            endActivity()
            if terminationPending {
                if let failure { showAlert("Could not save the recording", failure.localizedDescription) }
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            // Change the state first, so the main window is back and the alert attaches to it as a sheet.
            if let savedURL {
                state = .finished(savedURL)
                if let reason {
                    showAlert("Recording stopped", "\(reason)\nThe part recorded so far was saved.")
                }
            } else {
                state = .idle
                let message = failure?.localizedDescription ?? "Unknown error."
                showAlert("Could not save the recording", reason.map { "\(message)\n\($0)" } ?? message)
            }
            applyCaptureNow()
        }
    }

    func discardRecording() {
        guard state.isCapturingSession, let recorder else { return }
        isDiscarding = true
        state = .finishing
        sink.set(nil)
        clock.stop()
        Task {
            await recorder.cancel()
            self.recorder = nil
            isDiscarding = false
            endActivity()
            if terminationPending {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            state = .idle
        }
    }

    func dismissFinished() {
        if case .finished = state { state = .idle }
    }

    /// Moves the finished file to the Trash (recoverable) and returns to idle.
    func trashFinished() {
        guard case .finished(let url) = state else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            state = .idle
        } catch {
            showAlert("Could not move the recording to the Trash", error.localizedDescription)
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Termination

    func terminationReply() -> NSApplication.TerminateReply {
        persistNow()
        switch state {
        case .countdown:
            cancelCountdown()
            return .terminateNow
        case .recording, .paused:
            terminationPending = true
            stopRecording()
            return .terminateLater
        case .finishing:
            terminationPending = true
            return .terminateLater
        case .idle, .finished:
            return .terminateNow
        }
    }

    func shutdown() {
        persistNow()
        pipeline.stop()
    }

    // MARK: - Helpers

    private func showAlert(_ title: String, _ message: String) {
        onAlert?(AlertInfo(title: title, message: message))
    }

    static var recordingsFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("ScreenyPro", isDirectory: true)
    }

    static func openRecordingsFolder() {
        let folder = recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// `~/Movies/ScreenyPro/ScreenyPro 2026-11-13 at 10.45.12.mp4`
    static func makeOutputURL(date: Date = Date()) throws -> URL {
        let folder = recordingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "ScreenyPro \(formatter.string(from: date))"
        var url = folder.appendingPathComponent(base + ".mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(index)).mp4")
            index += 1
        }
        return url
    }
}
