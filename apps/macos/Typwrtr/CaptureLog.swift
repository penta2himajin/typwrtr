import Foundation
import os

/// Debug-only capture measurement (ux-decisions Q27).
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
/// Exists because Q25 defers the segment-end value to measurement, and because
/// `NSLog` output has been confirmed unrecoverable after the fact. Read it with:
///
///     log show --predicate 'subsystem == "app.typwrtr.macos.menuextra"' --last 30m
enum CaptureLog {
    #if DEBUG
        private static let log = Logger(
            subsystem: "app.typwrtr.macos.menuextra",
            category: "capture"
        )
    #endif

    /// Record what the detector made of the capture that just finished.
    static func record(_ metrics: FfiCaptureMetrics?, path: String) {
        #if DEBUG
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
        #endif
    }

    /// Streaming endpointing: why a buffer was closed (`silence` vs `release`).
    static func endpoint(reason: String, samples: Int, sampleRate: Double = 16_000) {
        #if DEBUG
            let seconds = sampleRate > 0 ? Double(samples) / sampleRate : 0
            log.info(
                """
                endpoint reason=\(reason, privacy: .public) \
                samples=\(samples, privacy: .public) \
                seconds=\(seconds, format: .fixed(precision: 2), privacy: .public)
                """
            )
        #endif
    }

    static func note(_ message: String) {
        #if DEBUG
            log.info("\(message, privacy: .public)")
        #endif
    }

    /// Insert outcome without the transcript (char count only).
    static func insert(path: String, outcome: String, chars: Int) {
        #if DEBUG
            log.info(
                """
                insert path=\(path, privacy: .public) \
                outcome=\(outcome, privacy: .public) \
                chars=\(chars, privacy: .public)
                """
            )
        #endif
    }
}
