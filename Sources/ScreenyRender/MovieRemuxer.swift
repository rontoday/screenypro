@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Second recording step: capture `.mov` → web-ready `.mp4`.
/// Video samples pass through (no re-encode). All audio tracks are mixed into one stereo AAC track
/// (microphone at 1.0, system audio at 0.8). The movie header is placed first (fast start).
enum MovieRemuxer {
    static let microphoneVolume: Float = 1.0
    static let systemVolume: Float = 0.8

    static func remux(source: URL, destination: URL, isCancelled: @escaping @Sendable () -> Bool) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let videoTrack: AVAssetTrack
        var audioTracks: [AVAssetTrack] = []
        var audioChannels: [AVAssetTrack: UInt32] = [:]
        let videoFormat: CMFormatDescription?
        let videoTimeScale: CMTimeScale
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecorderError.finalizeFailed("the capture file has no video track", underlying: nil)
            }
            videoTrack = track
            videoFormat = try await track.load(.formatDescriptions).first
            videoTimeScale = try await track.load(.naturalTimeScale)
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let range = try await track.load(.timeRange)
                guard range.duration.isValid, range.duration > .zero else { continue }
                let format = try await track.load(.formatDescriptions).first
                let channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
                audioTracks.append(track)
                audioChannels[track] = channels
            }
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.finalizeFailed("reading the capture file", underlying: error)
        }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw RecorderError.finalizeFailed("opening reader/writer", underlying: error)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw RecorderError.finalizeFailed("reading the video track", underlying: nil)
        }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        if videoTimeScale > 0 { videoInput.mediaTimeScale = videoTimeScale }
        guard writer.canAdd(videoInput) else {
            throw RecorderError.finalizeFailed("writing the video track", underlying: nil)
        }
        writer.add(videoInput)

        var audioPair: (output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                // The recorder writes the microphone as mono and system audio as stereo.
                parameters.setVolume(audioChannels[track] == 1 ? microphoneVolume : systemVolume, at: .zero)
                return parameters
            }
            output.audioMix = mix
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: MovieRecorder.aacSettings(channels: 2, bitRate: 192_000))
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw RecorderError.finalizeFailed("mixing the audio tracks", underlying: nil)
            }
            reader.add(output)
            writer.add(input)
            audioPair = (output, input)
        }
        let audio = audioPair

        guard reader.startReading() else {
            throw RecorderError.finalizeFailed("reading the capture file", underlying: reader.error)
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RecorderError.finalizeFailed("writing the movie", underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        async let videoDone = pump(videoOutput, into: videoInput, label: "video", isCancelled: isCancelled)
        async let audioDone: Bool = {
            guard let audio else { return true }
            return await pump(audio.output, into: audio.input, label: "audio", isCancelled: isCancelled)
        }()
        let ok = await (videoDone, audioDone)

        if isCancelled() {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw RecorderError.cancelled
        }
        guard ok.0, ok.1, reader.status != .failed, writer.status == .writing else {
            let error = writer.error ?? reader.error
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: destination)
            throw RecorderError.finalizeFailed("copying samples", underlying: error)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw RecorderError.finalizeFailed("writing the movie", underlying: writer.error)
        }
    }

    /// Copies all samples of `output` into `input`. Returns `false` on failure or cancellation.
    private static func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        label: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let queue = DispatchQueue(label: "cz.comakers.screenypro.remux.\(label)", qos: .userInitiated)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while !finished && input.isReadyForMoreMediaData {
                    if isCancelled() {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(returning: false)
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(returning: true)
                        return
                    }
                    if !input.append(sample) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(returning: false)
                        return
                    }
                }
            }
        }
    }
}
