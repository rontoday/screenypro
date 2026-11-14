import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VideoFacts: Sendable {
    var durationSeconds: Double
    /// Display size (after the track's preferred transform), in pixels.
    var width: Int
    var height: Int
}

enum VideoInspector {
    /// Duration and display pixel size, read from the file.
    static func facts(of url: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw CloudError.invalidVideo("it is not a readable video file.")
        }
        guard let track = tracks.first else { throw CloudError.invalidVideo("it has no video track.") }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = natural.applying(transform)
        let seconds = duration.seconds
        return VideoFacts(
            durationSeconds: seconds.isFinite && seconds > 0 ? seconds : 0,
            width: Int(abs(display.width).rounded()),
            height: Int(abs(display.height).rounded())
        )
    }

    /// A JPEG frame about 1 s into the video, longest side at most `maxSide` px. `nil` if no frame can be read.
    static func posterJPEG(of url: URL, durationSeconds: Double, maxSide: CGFloat = 1280) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let second = durationSeconds > 0 ? min(1.0, durationSeconds / 2) : 0
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
        } catch {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
