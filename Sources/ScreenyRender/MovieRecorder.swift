@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenyCore
import VideoToolbox

/// Records composed frames and audio.
///
/// 1. Capture: a fragmented temporary `.mov` next to the output (`.<name>.recording.mov`), so a crash never
///    loses the recording. Hardware H.264/HEVC video, one AAC track per audio source.
/// 2. Finalize (`finish()`): pass the video through, mix all audio into one stereo AAC track and write a
///    fast-start `.mp4`.
///
/// All append calls return immediately: the work hops to a private serial queue. Samples that cannot be
/// written right away are dropped and counted.
public final class MovieRecorder: Recording, @unchecked Sendable {
    private let config: RecordingConfig
    private let canvas: (width: Int, height: Int)
    private let captureURL: URL
    private let finalizingURL: URL
    private let queue = DispatchQueue(label: "cz.comakers.screenypro.recorder", qos: .userInitiated)
    private let log = Logger(subsystem: "cz.comakers.screenypro", category: "recorder")

    private enum Phase { case idle, recording, finishing, finished, cancelled }

    private struct Pause {
        var start: CMTime
        var end: CMTime?
    }

    // Guarded by `lock`.
    private let lock = NSLock()
    private var phase: Phase = .idle
    private var pauses: [Pause] = []
    private var recordedDuration: TimeInterval = 0

    // Recorder queue only.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInputs: [AudioKind: AVAssetWriterInput] = [:]
    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime = .invalid
    private var audioEnd: [AudioKind: CMTime] = [:]
    private var pendingAudio: [(AudioKind, CMSampleBuffer)] = []
    private var videoFrameCount = 0
    private var finishRequested = false
    private var writerFailureLogged = false
    private var drops: [String: Int] = [:]
    private var dropsSinceLog: [String: Int] = [:]
    private var lastDropLog: Double = 0

    public init(config: RecordingConfig) {
        self.config = config
        canvas = (
            max(2, Int((config.canvasSize.width / 2).rounded()) * 2),
            max(2, Int((config.canvasSize.height / 2).rounded()) * 2)
        )
        let directory = config.outputURL.deletingLastPathComponent()
        let name = config.outputURL.deletingPathExtension().lastPathComponent
        captureURL = directory.appendingPathComponent(".\(name).recording.mov")
        finalizingURL = directory.appendingPathComponent(".\(name).finalizing.mp4")
    }

    // MARK: Recording

    public func start() throws {
        try lock.withLock {
            guard phase == .idle else { throw RecorderError.alreadyStarted }
            guard config.fps > 0, config.fps <= 240 else {
                throw RecorderError.invalidConfiguration("fps must be 1...240, got \(config.fps)")
            }
            guard config.canvasSize.width >= 16, config.canvasSize.height >= 16 else {
                throw RecorderError.invalidConfiguration("canvas size \(config.canvasSize) is too small")
            }
            let writer = try makeCaptureWriter()
            queue.sync {
                self.writer = writer.writer
                self.videoInput = writer.video
                self.adaptor = writer.adaptor
                self.audioInputs = writer.audio
            }
            phase = .recording
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard lock.withLock({ phase == .recording }) else { return }
        queue.async { [self] in writeVideo(pixelBuffer, at: time) }
    }

    public func appendAudio(_ kind: AudioKind, _ sampleBuffer: CMSampleBuffer) {
        guard lock.withLock({ phase == .recording }) else { return }
        queue.async { [self] in writeAudio(kind, sampleBuffer) }
    }

    public func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock {
            guard phase == .recording, pauses.last.map({ $0.end != nil }) ?? true else { return }
            pauses.append(Pause(start: now, end: nil))
        }
    }

    public func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock {
            guard let last = pauses.indices.last, pauses[last].end == nil else { return }
            pauses[last].end = roundedPauseEnd(start: pauses[last].start, now: now)
        }
    }

    /// The paused duration is rounded to whole frame intervals, so frames after the resume stay on the
    /// pipeline's constant-frame-rate grid. Audio uses the same offset, so A/V sync is unchanged.
    private func roundedPauseEnd(start: CMTime, now: CMTime) -> CMTime {
        let frames = (CMTimeGetSeconds(CMTimeSubtract(now, start)) * Double(config.fps)).rounded()
        let duration = CMTime(value: CMTimeValue(max(0, frames)), timescale: CMTimeScale(config.fps))
        return CMTimeAdd(start, duration)
    }

    public var isPaused: Bool {
        lock.withLock { pauses.last.map { $0.end == nil } ?? false }
    }

    public var duration: TimeInterval {
        lock.withLock { recordedDuration }
    }

    public func finish() async throws -> URL {
        let previous: Phase = lock.withLock {
            let p = phase
            if p == .recording {
                phase = .finishing
                if let last = pauses.indices.last, pauses[last].end == nil {
                    pauses[last].end = roundedPauseEnd(start: pauses[last].start, now: CMClockGetTime(CMClockGetHostTimeClock()))
                }
            }
            return p
        }
        switch previous {
        case .recording: break
        case .cancelled: throw RecorderError.cancelled
        default: throw RecorderError.notRecording
        }

        do {
            try await finishCapture()
            try await MovieRemuxer.remux(
                source: captureURL,
                destination: finalizingURL,
                isCancelled: { [weak self] in self?.isCancelled ?? true }
            )
            if isCancelled { throw RecorderError.cancelled }
            try moveIntoPlace()
            removeFile(captureURL)
            lock.withLock { if phase == .finishing { phase = .finished } }
            log.info("Recording saved: \(self.config.outputURL.path, privacy: .public)")
            return config.outputURL
        } catch {
            removeFile(finalizingURL)
            if isCancelled {
                removeFile(captureURL)
                throw RecorderError.cancelled
            }
            lock.withLock { phase = .finished }
            if case RecorderError.noVideoFrames = error {
                removeFile(captureURL)
            } else if FileManager.default.fileExists(atPath: captureURL.path) {
                log.error("Finalizing failed; the raw capture is kept at \(self.captureURL.path, privacy: .public)")
            }
            throw error
        }
    }

    public func cancel() async {
        let previous: Phase = lock.withLock {
            let p = phase
            phase = .cancelled
            return p
        }
        guard previous != .cancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let writer, !finishRequested, writer.status == .writing {
                    writer.cancelWriting()
                }
                writer = nil
                pendingAudio = []
                videoInput = nil
                adaptor = nil
                audioInputs = [:]
                removeFile(captureURL)
                removeFile(finalizingURL)
                continuation.resume()
            }
        }
        log.info("Recording cancelled")
    }

    // MARK: Writer setup

    private struct CaptureWriter {
        var writer: AVAssetWriter
        var video: AVAssetWriterInput
        var adaptor: AVAssetWriterInputPixelBufferAdaptor
        var audio: [AudioKind: AVAssetWriterInput]
    }

    private func makeCaptureWriter() throws -> CaptureWriter {
        let directory = config.outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.cannotCreateDirectory(directory, underlying: error)
        }
        removeFile(captureURL)
        removeFile(finalizingURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: captureURL, fileType: .mov)
        } catch {
            throw RecorderError.cannotCreateWriter(captureURL, underlying: error)
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = 600
        guard writer.canAdd(video) else { throw RecorderError.cannotAddInput("video") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width,
            kCVPixelBufferHeightKey as String: canvas.height,
        ])

        var audio: [AudioKind: AVAssetWriterInput] = [:]
        if config.hasSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2, bitRate: 160_000))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAddInput("system audio") }
            writer.add(input)
            audio[.system] = input
        }
        if config.hasMicrophone {
            // Microphones are mono sources; the finalizer tells the tracks apart by channel count.
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1, bitRate: 128_000))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAddInput("microphone") }
            writer.add(input)
            audio[.microphone] = input
        }

        guard writer.startWriting() else {
            let error = writer.error
            removeFile(captureURL)
            throw RecorderError.writerFailed(underlying: error)
        }
        return CaptureWriter(writer: writer, video: video, adaptor: adaptor, audio: audio)
    }

    private func videoSettings() -> [String: Any] {
        let pixelsPerSecond = Double(canvas.width * canvas.height * config.fps)
        var compression: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: config.fps * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoExpectedSourceFrameRateKey: config.fps,
        ]
        let codec: AVVideoCodecType
        switch config.codec {
        case .h264:
            codec = .h264
            compression[AVVideoAverageBitRateKey] = Int(pixelsPerSecond * 0.07)
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        case .hevc:
            codec = .hevc
            compression[AVVideoAverageBitRateKey] = Int(pixelsPerSecond * 0.07 * 0.6)
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                // sRGB transfer: the frames are sRGB-encoded (see Compositor.outputSpace).
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
    }

    static func aacSettings(channels: Int, bitRate: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    // MARK: Writing (recorder queue)

    private var isCancelled: Bool { lock.withLock { phase == .cancelled } }

    /// Samples queued before `finish()` are still written (the finish step runs after them on the queue).
    private var acceptsQueuedSamples: Bool { lock.withLock { phase == .recording || phase == .finishing } }

    /// Pause-adjusted offset for a host-clock time; `nil` when the time falls into a pause.
    private func pauseOffset(for time: CMTime) -> CMTime? {
        lock.withLock {
            var offset = CMTime.zero
            for pause in pauses where time >= pause.start {
                guard let end = pause.end, time >= end else { return nil }
                offset = CMTimeAdd(offset, CMTimeSubtract(end, pause.start))
            }
            return offset
        }
    }

    private func writerIsUsable() -> AVAssetWriter? {
        guard !finishRequested, let writer else { return nil }
        if writer.status == .writing { return writer }
        if writer.status == .failed, !writerFailureLogged {
            writerFailureLogged = true
            log.error("Capture writer failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
        return nil
    }

    private func writeVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard acceptsQueuedSamples, let writer = writerIsUsable(),
              let videoInput, let adaptor else { return }
        guard let offset = pauseOffset(for: time) else { return }
        let pts = CMTimeSubtract(time, offset)

        guard CVPixelBufferGetWidth(pixelBuffer) == canvas.width, CVPixelBufferGetHeight(pixelBuffer) == canvas.height else {
            drop("video: wrong size")
            return
        }
        if lastVideoTime.isValid, pts <= lastVideoTime {
            drop("video: non-increasing time")
            return
        }
        if sessionStart == nil {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            let pending = pendingAudio
            pendingAudio = []
            for (kind, buffer) in pending { writeAudio(kind, buffer) }
        }
        guard videoInput.isReadyForMoreMediaData else {
            drop("video: encoder busy")
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastVideoTime = pts
            videoFrameCount += 1
            if let start = sessionStart {
                let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, start))
                lock.withLock { recordedDuration = seconds }
            }
        } else {
            _ = writerIsUsable()
            drop("video: append failed")
        }
    }

    private func writeAudio(_ kind: AudioKind, _ sampleBuffer: CMSampleBuffer) {
        guard acceptsQueuedSamples, writerIsUsable() != nil,
              let input = audioInputs[kind] else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard originalPTS.isValid, let offset = pauseOffset(for: originalPTS) else { return }
        guard let start = sessionStart else {
            // The first composed frame usually arrives after audio of the same moment (render latency).
            // Keep recent audio until the session starts; older audio is dropped.
            pendingAudio.append((kind, sampleBuffer))
            let horizon = CMTimeSubtract(originalPTS, CMTime(value: 2, timescale: 1))
            pendingAudio.removeAll { CMSampleBufferGetPresentationTimeStamp($0.1) < horizon }
            return
        }
        var source = sampleBuffer
        var adjusted = CMTimeSubtract(originalPTS, offset)
        if adjusted < start {
            // Keep only the part after the session start (LPCM: one sample per frame).
            guard let trimmed = Self.trimmedLPCM(sampleBuffer, dropping: CMTimeSubtract(start, adjusted)) else { return }
            source = trimmed
            adjusted = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(trimmed), offset)
        }
        if let end = audioEnd[kind], adjusted < CMTimeSubtract(end, CMTime(value: 1, timescale: 1000)) {
            drop("\(kind): overlaps after resume")
            return
        }
        let buffer: CMSampleBuffer
        if offset == .zero {
            buffer = source
        } else if let retimed = Self.retimed(source, by: offset) {
            buffer = retimed
        } else {
            drop("\(kind): retime failed")
            return
        }
        guard input.isReadyForMoreMediaData else {
            drop("\(kind): encoder busy")
            return
        }
        if input.append(buffer) {
            let duration = CMSampleBufferGetDuration(buffer)
            audioEnd[kind] = duration.isValid ? CMTimeAdd(adjusted, duration) : adjusted
        } else {
            _ = writerIsUsable()
            drop("\(kind): append failed")
        }
    }

    /// Drops the first `amount` of an LPCM buffer. `nil` when nothing is left or the format is not LPCM.
    static func trimmedLPCM(_ sampleBuffer: CMSampleBuffer, dropping amount: CMTime) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0
        else { return nil }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let skip = Int((CMTimeGetSeconds(amount) * asbd.mSampleRate).rounded(.up))
        guard skip > 0 else { return sampleBuffer }
        guard skip < count else { return nil }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleRange: CFRange(location: skip, length: count - skip),
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }

    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr
        else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }

    private func drop(_ reason: String) {
        drops[reason, default: 0] += 1
        dropsSinceLog[reason, default: 0] += 1
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        guard now - lastDropLog >= 1 else { return }
        lastDropLog = now
        let summary = dropsSinceLog.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        dropsSinceLog = [:]
        log.notice("Dropped samples: \(summary, privacy: .public)")
    }

    // MARK: Finalizing

    /// Closes the capture file. Throws `noVideoFrames` when nothing was recorded.
    private func finishCapture() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let writer, let videoInput else {
                    continuation.resume(throwing: RecorderError.notRecording)
                    return
                }
                finishRequested = true
                if !drops.isEmpty {
                    let summary = drops.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
                    log.notice("Total dropped samples: \(summary, privacy: .public)")
                }
                guard videoFrameCount > 0 else {
                    if writer.status == .writing { writer.cancelWriting() }
                    continuation.resume(throwing: RecorderError.noVideoFrames)
                    return
                }
                guard writer.status == .writing else {
                    continuation.resume(throwing: RecorderError.writerFailed(underlying: writer.error))
                    return
                }
                videoInput.markAsFinished()
                for input in audioInputs.values { input.markAsFinished() }
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
                writer.endSession(atSourceTime: CMTimeAdd(lastVideoTime, frameDuration))
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RecorderError.writerFailed(underlying: writer.error))
                    }
                }
            }
        }
    }

    private func moveIntoPlace() throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: config.outputURL.path) {
                _ = try fm.replaceItemAt(config.outputURL, withItemAt: finalizingURL)
            } else {
                try fm.moveItem(at: finalizingURL, to: config.outputURL)
            }
        } catch {
            throw RecorderError.finalizeFailed("moving the file into place", underlying: error)
        }
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
