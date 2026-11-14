import AppKit
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ScreenyCore

/// The current recorder, read from the render and audio queues.
/// The lock is held during the append call, so after `set(nil)` returns no append is still running
/// and none will start. Appends are non-blocking by contract, so the lock is held only briefly.
final class RecorderSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: Recording?

    func set(_ newRecorder: Recording?) {
        lock.lock()
        recorder = newRecorder
        lock.unlock()
    }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        recorder?.appendVideo(buffer, at: time)
    }

    func appendAudio(_ kind: AudioKind, _ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        recorder?.appendAudio(kind, sampleBuffer)
    }
}

/// Lets the render-queue callback reach the preview view without touching main-actor state.
/// `PreviewDisplaying.display` is thread-safe by contract.
final class PreviewSink: @unchecked Sendable {
    private let preview: PreviewDisplaying

    init(_ preview: PreviewDisplaying) {
        self.preview = preview
    }

    func display(_ buffer: CVPixelBuffer) {
        preview.display(buffer)
    }
}

// MARK: - Microphone level

/// Collects the loudest microphone level since the last read. Written on the audio queue, read on main.
final class AudioLevelTap: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = -160

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let db = AudioLevel.rmsDecibels(sampleBuffer) else { return }
        lock.lock()
        if db > peak { peak = db }
        lock.unlock()
    }

    /// Returns the loudest level since the last call (dBFS) and resets it.
    func drain() -> Float {
        lock.lock()
        defer {
            peak = -160
            lock.unlock()
        }
        return peak
    }
}

enum AudioLevel {
    /// RMS level of an LPCM sample buffer in dBFS (-160...0). `nil` for non-PCM or empty buffers.
    static func rmsDecibels(_ sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return nil }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        var sum: Double = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            if isFloat && bits == 32 {
                let n = bytes / 4
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<n { let v = Double(p[i]); sum += v * v }
                count += n
            } else if !isFloat && bits == 16 {
                let n = bytes / 2
                let p = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
                count += n
            } else if !isFloat && bits == 32 {
                let n = bytes / 4
                let p = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<n { let v = Double(p[i]) / 2_147_483_648; sum += v * v }
                count += n
            }
        }
        guard count > 0 else { return nil }
        let rms = (sum / Double(count)).squareRoot()
        guard rms > 0 else { return -160 }
        return Float(max(-160, 20 * log10(rms)))
    }
}

/// Microphone level for the meter. Polled from the tap at 15 Hz, so the audio queue never hops to main.
@MainActor
final class LevelMeterModel: ObservableObject {
    /// 0...1, mapped from -60...0 dBFS.
    @Published private(set) var level: Double = 0
    @Published var isActive = false

    let tap = AudioLevelTap()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
    }

    private func tick() {
        let db = Double(tap.drain())
        let target = db <= -159 ? 0 : min(max((db + 60) / 60, 0), 1)
        let next = target >= level ? target : max(target, level - 0.06)
        if abs(next - level) > 0.004 { level = next }
    }
}

/// Elapsed recording time, read from `recorder.duration` four times per second.
@MainActor
final class ElapsedClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    var onTick: ((TimeInterval) -> Void)?
    private var timer: Timer?

    func start(reading source: @escaping () -> TimeInterval) {
        stop()
        elapsed = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = source()
                self.elapsed = value
                self.onTick?(value)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
