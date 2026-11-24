import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Records the microphone into memory as 16 kHz mono Float32, the input every
/// transcribe.cpp model takes. Nothing is written to disk.
///
/// A fresh `AVAudioEngine` per recording, so a changed microphone setting or a
/// device that came and went never leaves a stale graph behind. The device is
/// chosen by setting `kAudioOutputUnitProperty_CurrentDevice` on the input
/// node's unit *before* reading its format — the format follows the device.
@MainActor
final class DictationRecorder {
    nonisolated static let sampleRate: Double = 16_000
    /// Hard cap, so a latched recording that is forgotten can't grow forever.
    nonisolated static let maxDuration: TimeInterval = 5 * 60

    enum RecorderError: LocalizedError {
        case noInputDevice
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is available."
            case .engine(let message): return "The microphone couldn't start: \(message)"
            }
        }
    }

    /// Called on the main thread with an RMS level in 0…1, ~20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when `maxDuration` is reached.
    var onLimitReached: (() -> Void)?

    private var engine: AVAudioEngine?
    private let buffer = SampleBuffer()

    var isRecording: Bool { engine != nil }

    /// Starts recording from the device with `uid` (empty, or not attached:
    /// the system default input).
    func start(deviceUID: String) throws {
        stopEngine()
        buffer.reset()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty {
            if let id = AudioDevices.inputDeviceID(forUID: deviceUID), let unit = input.audioUnit {
                var device = id
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &device,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    Log.dictation.error("selecting microphone failed (\(status)); using the default")
                }
            } else {
                Log.dictation.info("chosen microphone not attached; using the default")
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.engine("unsupported input format \(inputFormat)")
        }

        let buffer = self.buffer
        let maxSamples = Int(Self.sampleRate * Self.maxDuration)
        var lastLevelAt = 0.0
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] pcm, _ in
            guard let converted = Self.convert(pcm, with: converter, to: target) else { return }
            let reachedLimit = buffer.append(converted, limit: maxSamples)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelAt >= 0.05 || reachedLimit {
                lastLevelAt = now
                let level = Self.rmsLevel(converted)
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        guard let self, self.isRecording else { return }
                        self.onLevel?(level)
                        if reachedLimit { self.onLimitReached?() }
                    }
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engine(error.localizedDescription)
        }
        self.engine = engine
    }

    /// Stops and returns everything recorded since `start`.
    func stop() -> [Float] {
        stopEngine()
        return buffer.drain()
    }

    /// Stops and throws the recording away.
    func cancel() {
        stopEngine()
        buffer.reset()
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // MARK: - Audio-thread helpers

    private nonisolated static func convert(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> [Float]? {
        let ratio = format.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// RMS mapped onto a perceptual 0…1 scale (-50 dBFS … 0 dBFS).
    nonisolated static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let db = 10 * log10(max(mean, 1e-10))
        return min(max((db + 50) / 50, 0), 1)
    }
}

/// The recording, appended from the audio thread and drained on main.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    /// Returns true once `limit` samples are held (further audio is dropped).
    func append(_ more: [Float], limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let room = limit - samples.count
        if room > 0 { samples.append(contentsOf: more.prefix(room)) }
        return samples.count >= limit
    }

    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples = []
    }
}
