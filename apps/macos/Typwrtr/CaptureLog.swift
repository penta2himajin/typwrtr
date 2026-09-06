import Foundation
import os

/// Capture measurement (ux-decisions Q27).
///
/// Numbers only: how long the capture was, how much of it the detector called
/// speech, how many utterances it found, and the trimmed fraction. No audio and
/// no transcribed text, so this stays inside the data-retention rules in
/// ux-decisions §10.
///
/// `trimmed` is what Q25 needs: the share of the capture the detector dropped.
/// Reporting speech as a share of the capture instead invited reading a padded
/// overcount as a fraction, which is how the first dogfood run showed 1.15.
///
/// Enabled when `LatencyLog.isEnabled` is on (Release dogfood) or in Xcode
/// Debug builds. Read with:
///
///     log show --predicate 'subsystem == "app.typwrtr.macos.menuextra"' --last 30m
enum CaptureLog {
    private static let log = Logger(
        subsystem: "app.typwrtr.macos.menuextra",
        category: "capture"
    )

    private static var isActive: Bool {
        #if DEBUG
            return true
        #else
            return LatencyLog.isEnabled
        #endif
    }

    /// Record what the detector made of the capture that just finished.
    static func record(_ metrics: FfiCaptureMetrics?, path: String) {
        guard isActive else { return }
        guard let metrics, metrics.sampleRate > 0 else { return }
        let rate = Double(metrics.sampleRate)
        let pushedSeconds = Double(metrics.pushedSamples) / rate
        let speechSeconds = Double(metrics.speechSamples) / rate
        let trimmedSeconds = max(0, pushedSeconds - speechSeconds)
        log.info(
            """
            capture path=\(path, privacy: .public) \
            pushed=\(pushedSeconds, format: .fixed(precision: 2), privacy: .public)s \
            speech=\(speechSeconds, format: .fixed(precision: 2), privacy: .public)s \
            trimmed=\(trimmedSeconds, format: .fixed(precision: 2), privacy: .public)s \
            segments=\(metrics.speechSegments, privacy: .public)
            """
        )
    }

    /// Streaming endpointing: why a buffer was closed (`silence` vs `release`).
    static func endpoint(reason: String, samples: Int, sampleRate: Double = 16_000) {
        guard isActive else { return }
        let seconds = sampleRate > 0 ? Double(samples) / sampleRate : 0
        log.info(
            """
            endpoint reason=\(reason, privacy: .public) \
            samples=\(samples, privacy: .public) \
            seconds=\(seconds, format: .fixed(precision: 2), privacy: .public)
            """
        )
    }

    static func note(_ message: String) {
        guard isActive else { return }
        log.info("\(message, privacy: .public)")
    }

    /// Insert outcome without the transcript (char count only).
    static func insert(path: String, outcome: String, chars: Int) {
        guard isActive else { return }
        log.info(
            """
            insert path=\(path, privacy: .public) \
            outcome=\(outcome, privacy: .public) \
            chars=\(chars, privacy: .public)
            """
        )
    }
}
