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

    /// Last successful capture size (for dogfood visibility).
    private(set) var lastSampleCount: Int = 0
    private(set) var lastSampleRate: UInt32 = 16_000

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

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        buffer.removeAll(keepingCapacity: true)

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
        converter = nil
        lock.unlock()

        lastSampleCount = out.count
        lastSampleRate = UInt32(targetSampleRate)
        return (out, UInt32(targetSampleRate))
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
            lock.lock()
            buffer.append(contentsOf: slice)
            lock.unlock()
            return
        }

        guard let channels = inBuffer.floatChannelData else { return }
        let frameCount = Int(inBuffer.frameLength)
        var slice = Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        let inRate = inBuffer.format.sampleRate
        if abs(inRate - targetSampleRate) > 1 {
            slice = Self.downsample(slice, from: inRate, to: targetSampleRate)
        }
        lock.lock()
        buffer.append(contentsOf: slice)
        lock.unlock()
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
