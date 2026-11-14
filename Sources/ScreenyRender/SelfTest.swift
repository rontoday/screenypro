@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenyCore

/// Headless check of the render and record path. Needs no privacy permissions and no main thread.
///
/// Synthetic screen (2940×1912) and camera (1280×720) frames go through `LatestFrameBox` → `FramePipeline`
/// (1440p, 30 fps) → `MovieRecorder` for 3 s, with a 440 Hz microphone tone and a 660 Hz system tone.
/// The camera corner changes once, and there is one 0.5 s pause. The result must have one 2560×1440 video
/// track, one audio track and a duration of 2.3–2.8 s.
public enum SelfTest {
    public static func run(outputURL: URL) async throws {
        let rig = try SelfTestRig(outputURL: outputURL)
        defer { rig.stopSources() }
        try await rig.record()
        let url = try await rig.recorder.finish()
        try await verify(url: url, canvas: rig.canvas)
    }

    static func verify(url: URL, canvas: CGSize) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1 else { throw SelfTestError("expected 1 video track, found \(videoTracks.count)") }
        let size = try await videoTracks[0].load(.naturalSize)
        guard Int(size.width) == Int(canvas.width), Int(size.height) == Int(canvas.height) else {
            throw SelfTestError("video size is \(Int(size.width))x\(Int(size.height)), expected \(Int(canvas.width))x\(Int(canvas.height))")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 1 else { throw SelfTestError("expected 1 audio track, found \(audioTracks.count)") }
        if let format = try await audioTracks[0].load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            guard asbd.mFormatID == kAudioFormatMPEG4AAC, asbd.mChannelsPerFrame == 2 else {
                throw SelfTestError("audio track is not stereo AAC")
            }
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard (2.3...2.8).contains(duration) else {
            throw SelfTestError(String(format: "duration is %.3f s, expected 2.3–2.8 s", duration))
        }
    }
}

/// Wires synthetic sources, the pipeline and the recorder. Also used by the A/V sync check.
final class SelfTestRig: @unchecked Sendable {
    let canvas = CGSize(width: 2560, height: 1440)
    let fps = 30
    let screenBox = LatestFrameBox()
    let cameraBox = LatestFrameBox()
    let pipeline: FramePipeline
    let recorder: MovieRecorder
    let screen: SyntheticScreen
    let camera: SyntheticCamera

    /// Seconds (since `origin`) at which the screen shows the white sync marker and the system tone beeps.
    /// Empty for the plain self-test.
    var markerTimes: [Double] = []
    static let markerLength = 0.1

    private let lock = NSLock()
    private var firstFrameTime: CMTime?
    private let sourceQueue = DispatchQueue(label: "cz.comakers.screenypro.selftest.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "cz.comakers.screenypro.selftest.audio", qos: .userInitiated)
    private var videoTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private let origin = CMClockGetTime(CMClockGetHostTimeClock())

    init(outputURL: URL) throws {
        screen = try SyntheticScreen()
        camera = try SyntheticCamera()
        pipeline = FramePipeline(screen: screenBox, camera: cameraBox)
        recorder = MovieRecorder(config: RecordingConfig(
            outputURL: outputURL, canvasSize: canvas, fps: fps, codec: .h264,
            hasSystemAudio: true, hasMicrophone: true
        ))
    }

    private func seconds(_ time: CMTime) -> Double {
        CMTimeGetSeconds(CMTimeSubtract(time, origin))
    }

    private func isMarker(_ t: Double) -> Bool {
        markerTimes.contains { t >= $0 && t < $0 + Self.markerLength }
    }

    func startSources() throws {
        let mic = try SineSource(frequency: 440, channels: 1, startTime: origin)
        let system = try SineSource(frequency: 660, channels: 2, startTime: origin)
        if !markerTimes.isEmpty {
            system.gate = { [weak self] t in self?.isMarker(t) ?? false }
        }
        publishVideo()

        let video = DispatchSource.makeTimerSource(flags: .strict, queue: sourceQueue)
        video.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(1))
        video.setEventHandler { [weak self] in self?.publishVideo() }
        videoTimer = video
        video.resume()

        let audio = DispatchSource.makeTimerSource(flags: .strict, queue: audioQueue)
        audio.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        audio.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if let buffer = mic.samples(until: now) { self.recorder.appendAudio(.microphone, buffer) }
            if let buffer = system.samples(until: now) { self.recorder.appendAudio(.system, buffer) }
        }
        audioTimer = audio
        audio.resume()
    }

    private func publishVideo() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let t = seconds(now)
        if let frame = screen.frame(t: t, time: now, marker: isMarker(t)) { screenBox.set(frame) }
        if let frame = camera.frame(t: t, time: now) { cameraBox.set(frame) }
    }

    func stopSources() {
        videoTimer?.cancel()
        audioTimer?.cancel()
        videoTimer = nil
        audioTimer = nil
        pipeline.stop()
        pipeline.onFrame = nil
    }

    /// Records: 3 s of wall time measured from the first composed frame, camera corner change at 1.2 s,
    /// pause 1.5–2.0 s. Recorded duration ≈ 2.5 s.
    func record(styleChangeAt: Double = 1.2, pauseAt: Double = 1.5, resumeAt: Double = 2.0, stopAt: Double = 3.0) async throws {
        try recorder.start()
        let recorder = self.recorder
        // Like the app (preview runs before recording), skip the warm-up frames that compile GPU kernels.
        var warmup = 4
        pipeline.onFrame = { [weak self] buffer, time in
            guard let self else { return }
            let record: Bool = self.lock.withLock {
                if warmup > 0 { warmup -= 1; return false }
                if self.firstFrameTime == nil { self.firstFrameTime = time }
                return true
            }
            if record { recorder.appendVideo(buffer, at: time) }
        }
        try startSources()
        pipeline.start(canvasSize: canvas, fps: fps)

        // Wait for the first frame (the first render compiles the GPU kernels).
        var waited = 0
        while lock.withLock({ firstFrameTime }) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
            if waited > 1000 {
                await recorder.cancel()
                throw SelfTestError("the pipeline produced no frame within 10 s")
            }
        }
        let start = lock.withLock { firstFrameTime! }

        try await sleep(until: start, plus: styleChangeAt)
        var style = pipeline.style
        style.camera.corner = .topLeft
        pipeline.style = style

        try await sleep(until: start, plus: pauseAt)
        recorder.pause()
        try await sleep(until: start, plus: resumeAt)
        recorder.resume()
        try await sleep(until: start, plus: stopAt)
        stopSources()
    }

    private func sleep(until start: CMTime, plus offset: Double) async throws {
        let target = CMTimeGetSeconds(start) + offset
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if target > now {
            try await Task.sleep(nanoseconds: UInt64((target - now) * 1e9))
        }
    }
}
