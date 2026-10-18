import AVFoundation
import Foundation

/// Captures mono float PCM while PTT is held (Swift-side mic; see architecture.md).
final class MicCapture {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case engineStart(String)
        case noFormat

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
            case .engineStart(let detail):
                return "Could not start microphone: \(detail)"
            case .noFormat:
                return "Microphone format unavailable."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var running = false
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000

    static let voiceProcessingKey = "typwrtr.voiceProcessing"

    /// Echo cancellation via macOS voice processing. Debug menu A/B only, off by
    /// default: while it is enabled, other apps capturing the mic without voice
    /// processing read ~33 dB quieter (architecture.md decision log, 2026-10-18).
    static var voiceProcessingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: voiceProcessingKey) }
        set { UserDefaults.standard.set(newValue, forKey: voiceProcessingKey) }
    }

    /// Last successful capture size (for dogfood visibility).
    private(set) var lastSampleCount: Int = 0
    private(set) var lastSampleRate: UInt32 = 16_000
    /// RMS of the latest converted chunk. The capture buffer itself is unchanged.
    private var latestRms: Float = 0

    /// Level for the Focus Dictation bar. 0 when the engine is idle.
    var recentRms: Float {
        lock.lock()
        defer { lock.unlock() }
        return running ? latestRms : 0
    }

    /// Whether the engine tap is currently installed.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }

    /// Switching voice processing takes ~1 s, so do it once off the main thread
    /// before the first capture rather than on the PTT press.
    func prepare() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            lock.lock()
            defer { lock.unlock() }
            if !running { applyVoiceProcessing() }
        }
    }

    /// Caller holds `lock` with the engine stopped.
    private func applyVoiceProcessing() {
        let input = engine.inputNode
        let want = Self.voiceProcessingEnabled
        guard input.isVoiceProcessingEnabled != want else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        do {
            try input.setVoiceProcessingEnabled(want)
        } catch {
            CaptureLog.note("voice processing \(want ? "on" : "off") failed: \(error.localizedDescription)")
            return
        }
        if want {
            // ux-decisions Q47: never duck the music the user is playing.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        }
        let format = input.outputFormat(forBus: 0)
        CaptureLog.note(String(
            format: "voice processing %@ ms=%llu format=%.0fHz ch=%u",
            want ? "on" : "off",
            (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000,
            format.sampleRate,
            format.channelCount
        ))
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        buffer.removeAll(keepingCapacity: true)
        latestRms = 0

        applyVoiceProcessing()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.noFormat
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        // Voice processing reports 9 identical channels; the default downmix of
        // those to mono is silence, so take the first.
        if inputFormat.channelCount > 1 {
            converter?.channelMap = [0]
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcm, _ in
            self?.append(pcm: pcm, targetFormat: targetFormat)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            throw CaptureError.engineStart(error.localizedDescription)
        }
        running = true
    }

    /// Stops capture and returns mono f32 samples at 16 kHz.
    func stop() -> (samples: [Float], sampleRate: UInt32) {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()

        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        lock.lock()
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        latestRms = 0
        converter = nil
        lock.unlock()

        lastSampleCount = out.count
        lastSampleRate = UInt32(targetSampleRate)
        return (out, UInt32(targetSampleRate))
    }

    /// Take buffered samples without stopping (Free continuous listen).
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }

    private func append(pcm inBuffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        lock.lock()
        let converter = self.converter
        lock.unlock()

        if let converter {
            let ratio = targetFormat.sampleRate / max(inBuffer.format.sampleRate, 1)
            let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }

            var offered = false
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if offered {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                offered = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            guard error == nil, let channels = outBuffer.floatChannelData else { return }
            let frameCount = Int(outBuffer.frameLength)
            let slice = Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
            store(slice)
            return
        }

        guard let channels = inBuffer.floatChannelData else { return }
        let frameCount = Int(inBuffer.frameLength)
        var slice = Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        let inRate = inBuffer.format.sampleRate
        if abs(inRate - targetSampleRate) > 1 {
            slice = Self.downsample(slice, from: inRate, to: targetSampleRate)
        }
        store(slice)
    }

    /// Append converted samples and remember their RMS. Does not drop or rewrite audio.
    private func store(_ slice: [Float]) {
        let level = Self.rms(of: slice)
        lock.lock()
        buffer.append(contentsOf: slice)
        if !slice.isEmpty {
            latestRms = level
        }
        lock.unlock()
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private static func downsample(_ input: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard inRate > 0, outRate > 0, !input.isEmpty else { return input }
        let step = inRate / outRate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 1)
        var i = 0.0
        while Int(i) < input.count {
            out.append(input[Int(i)])
            i += step
        }
        return out
    }
}
