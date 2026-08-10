import Foundation

/// Simple energy VAD: after speech, silence below threshold ends a segment.
///
/// Silence duration comes from core (`focusDictationSilenceSeconds` /
/// `streamingPttSilenceSeconds`). Endpointing only — trimming for ASR is
/// euhadra `EarshotVad` on the pipeline (`FinalPass::SpeechOnly`).
struct SilenceVad {
    var silenceSeconds: TimeInterval = 1.5
    /// RMS above this counts as speech (16 kHz mono f32). Lowered for quiet mics.
    var speechRmsThreshold: Float = 0.006

    private(set) var sawSpeech = false
    private var lastSpeechAt: Date?

    enum Event {
        case none
        case speechStarted
        case segmentEnded
    }

    mutating func reset() {
        sawSpeech = false
        lastSpeechAt = nil
    }

    mutating func push(samples: [Float], now: Date = Date()) -> Event {
        guard !samples.isEmpty else { return tickSilence(now: now) }
        let level = Self.rms(samples)
        if level >= speechRmsThreshold {
            let first = !sawSpeech
            sawSpeech = true
            lastSpeechAt = now
            return first ? .speechStarted : .none
        }
        return tickSilence(now: now)
    }

    private mutating func tickSilence(now: Date) -> Event {
        guard sawSpeech, let last = lastSpeechAt else { return .none }
        if now.timeIntervalSince(last) >= silenceSeconds {
            sawSpeech = false
            lastSpeechAt = nil
            return .segmentEnded
        }
        return .none
    }

    private static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }
}
