import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenyCore

/// Camera capture with `AVCaptureSession`: up to 1920×1080, 30 fps, 32BGRA, late frames discarded.
///
/// Threading: `start`/`stop` can be called from any thread or actor and are serialized by an async gate.
/// All session work runs on a private serial queue (it blocks). Frames arrive on a separate video queue.
public final class AVCameraCapture: CameraCapturing, @unchecked Sendable {
    /// Latest camera frame, not mirrored. `contentRect` is the full buffer.
    public let frames = LatestFrameBox()

    private let gate = AsyncSerialGate()
    private let sessionQueue = DispatchQueue(label: "cz.comakers.screenypro.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "cz.comakers.screenypro.camera.video", qos: .userInteractive)

    // Session state. Touched only on `sessionQueue` while holding `gate`.
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    private var receiver: CameraReceiver?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        receiver?.deactivate()
        if let session {
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
            }
        }
    }

    // MARK: - Devices

    public func devices() -> [MediaDevice] {
        var seen = Set<String>()
        return Self.discoverySession().devices.compactMap { device in
            guard device.deviceType != .deskViewCamera, seen.insert(device.uniqueID).inserted else { return nil }
            return MediaDevice(id: device.uniqueID, name: device.localizedName)
        }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    private static func resolveDevice(_ deviceID: String?) throws -> AVCaptureDevice {
        if let deviceID, !deviceID.isEmpty {
            guard let device = AVCaptureDevice(uniqueID: deviceID),
                  device.hasMediaType(.video),
                  device.deviceType != .deskViewCamera,
                  device.isConnected
            else { throw CaptureError.cameraNotFound(deviceID) }
            return device
        }
        if let preferred = AVCaptureDevice.systemPreferredCamera,
           preferred.deviceType != .deskViewCamera, preferred.isConnected {
            return preferred
        }
        if let first = discoverySession().devices.first(where: { $0.deviceType != .deskViewCamera && $0.isConnected }) {
            return first
        }
        throw CaptureError.noCameraAvailable
    }

    // MARK: - Start / stop

    public func start(deviceID: String?) async throws {
        try await gate.withLock {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw CaptureError.permissionDenied(.camera)
                }
            default:
                throw CaptureError.permissionDenied(.camera)
            }
            let device = try Self.resolveDevice(deviceID)
            try await self.onSessionQueue {
                try self.configureAndRun(device: device)
            }
        }
    }

    public func stop() async {
        await gate.withLock { () async -> Void in
            _ = try? await self.onSessionQueue {
                self.receiver?.deactivate()
                guard let session = self.session else { return }
                if session.isRunning { session.stopRunning() }
                if let input = self.input {
                    session.beginConfiguration()
                    session.removeInput(input)
                    session.commitConfiguration()
                    self.input = nil
                }
            }
        }
        frames.set(nil)
    }

    /// Runs on `sessionQueue`.
    private func configureAndRun(device: AVCaptureDevice) throws {
        if let session, session.isRunning, let input, input.device.uniqueID == device.uniqueID {
            return
        }

        let session = self.session ?? makeSession()
        let output = self.output ?? makeOutput()

        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.cameraUnavailable(name: device.localizedName, reason: error.localizedDescription)
        }

        session.beginConfiguration()
        let oldInput = input
        if let oldInput { session.removeInput(oldInput) }
        guard session.canAddInput(newInput) else {
            if let oldInput, session.canAddInput(oldInput) { session.addInput(oldInput) }
            session.commitConfiguration()
            throw CaptureError.cameraUnavailable(name: device.localizedName, reason: "the device cannot be added to the capture session.")
        }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CaptureError.cameraUnavailable(name: device.localizedName, reason: "the video output cannot be added.")
            }
            session.addOutput(output)
        }
        for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high]
        where device.supportsSessionPreset(preset) && session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        session.commitConfiguration()

        Self.limitFrameRate(of: device, to: 30)

        receiver?.activate(clock: session.synchronizationClock)
        if !session.isRunning {
            session.startRunning()
        }
        guard session.isRunning else {
            receiver?.deactivate()
            throw CaptureError.cameraUnavailable(name: device.localizedName, reason: "the capture session did not start.")
        }
        // The clock is known for sure once the session runs.
        receiver?.activate(clock: session.synchronizationClock)
    }

    private func makeSession() -> AVCaptureSession {
        let session = AVCaptureSession()
        self.session = session
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            captureLog.error("Camera session error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            self?.receiver?.clear()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            self.sessionQueue.async {
                if self.input?.device.uniqueID == device.uniqueID {
                    captureLog.info("Camera disconnected: \(device.localizedName, privacy: .public)")
                    self.receiver?.clear()
                }
            }
        })
        return session
    }

    private func makeOutput() -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let receiver = CameraReceiver(frames: frames)
        output.setSampleBufferDelegate(receiver, queue: videoQueue)
        self.output = output
        self.receiver = receiver
        return output
    }

    /// Caps the frame rate. Leaves the max frame duration alone so the camera can slow down in low light.
    private static func limitFrameRate(of device: AVCaptureDevice, to fps: Double) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard ranges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.unlockForConfiguration()
        } catch {
            captureLog.error("Camera frame rate not set: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func onSessionQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Receiver

private final class CameraReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let frames: LatestFrameBox
    private let hostClock = CMClockGetHostTimeClock()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var isActive = false
    private var clock: CMClock?

    init(frames: LatestFrameBox) {
        self.frames = frames
    }

    func activate(clock: CMClock?) {
        lock.sync {
            isActive = true
            self.clock = clock
        }
    }

    func deactivate() {
        lock.sync {
            isActive = false
            frames.set(nil)
        }
    }

    /// Drops the current frame but keeps receiving (the device may come back).
    func clear() {
        lock.sync { frames.set(nil) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let pts = sampleBuffer.presentationTimeStamp
        lock.sync {
            guard isActive else { return }
            // Sample times are on the session's synchronization clock; the pipeline uses the host clock.
            var time = pts
            if let clock, clock !== hostClock {
                time = CMSyncConvertTime(pts, from: clock, to: hostClock)
            }
            frames.set(VideoFrame(pixelBuffer: pixelBuffer, contentRect: rect, time: time))
        }
    }
}
