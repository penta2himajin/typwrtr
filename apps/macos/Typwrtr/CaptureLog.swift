import Foundation
import os

/// Debug-only capture measurement (ux-decisions Q27).
///
/// Numbers only: how long the capture was, how much of it the detector called
/// speech, and the ratio. No audio and no transcribed text, so this stays inside
/// the data-retention rules in ux-decisions §10.
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
            let speechRatio = pushedSeconds > 0 ? speechSeconds / pushedSeconds : 0
            log.info(
                """
                capture path=\(path, privacy: .public) \
                pushed=\(pushedSeconds, format: .fixed(precision: 2), privacy: .public)s \
                speech=\(speechSeconds, format: .fixed(precision: 2), privacy: .public)s \
                ratio=\(speechRatio, format: .fixed(precision: 3), privacy: .public)
                """
            )
        #endif
    }
}
