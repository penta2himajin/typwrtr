import Foundation
import os

/// Optional latency tracing for dogfood (ux-decisions Q27 extension).
///
/// Numbers only: timestamps and millisecond deltas from PTT release (or segment
/// end) through ASR finalize and text insert. No audio, no transcript.
///
/// Enable via menu **Debug → Latency logs** (stored in UserDefaults). Works in
/// Release dogfood builds — not gated on `#if DEBUG`.
///
/// Read with:
///
///     log show --predicate 'subsystem == "app.typwrtr.macos.menuextra" AND category == "latency"' --last 30m
enum LatencyLog {
    static let userDefaultsKey = "typwrtr.latencyLogging"

    private static let log = Logger(
        subsystem: "app.typwrtr.macos.menuextra",
        category: "latency"
    )

    private static let lock = NSLock()
    private static var nextTraceId: UInt64 = 1

    /// When true, latency traces and related capture metrics are emitted.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    /// One end-to-end measurement for a PTT release or streaming/Free segment.
    final class Trace {
        let id: UInt64
        let path: String
        let trigger: String
        private let originNs: UInt64

        private var asrStartNs: UInt64?
        private var asrEndNs: UInt64?
        private var insertStartNs: UInt64?
        private var insertEndNs: UInt64?
        private var insertMethod: String?
        private var outcome: String?
        private var chars: Int = 0
        private var emitted = false

        init(path: String, trigger: String) {
            lock.lock()
            id = nextTraceId
            nextTraceId += 1
            lock.unlock()
            self.path = path
            self.trigger = trigger
            originNs = Self.nowNs()
        }

        func markAsrStart() {
            asrStartNs = Self.nowNs()
        }

        func markAsrEnd() {
            asrEndNs = Self.nowNs()
        }

        func markInsertStart() {
            insertStartNs = Self.nowNs()
        }

        func finishInsert(method: String, outcome: String, chars: Int) {
            insertEndNs = Self.nowNs()
            insertMethod = method
            self.outcome = outcome
            self.chars = chars
            emitIfNeeded()
        }

        /// Log a trace that never reached insert (dropped / empty / error).
        func finishWithoutInsert(outcome: String, chars: Int = 0) {
            self.outcome = outcome
            self.chars = chars
            emitIfNeeded()
        }

        private func emitIfNeeded() {
            guard LatencyLog.isEnabled, !emitted else { return }
            emitted = true
            LatencyLog.emit(
                id: id,
                path: path,
                trigger: trigger,
                originNs: originNs,
                asrStartNs: asrStartNs,
                asrEndNs: asrEndNs,
                insertStartNs: insertStartNs,
                insertEndNs: insertEndNs,
                insertMethod: insertMethod,
                outcome: outcome ?? "unknown",
                chars: chars
            )
        }

        private static func nowNs() -> UInt64 {
            DispatchTime.now().uptimeNanoseconds
        }
    }

    private static func emit(
        id: UInt64,
        path: String,
        trigger: String,
        originNs: UInt64,
        asrStartNs: UInt64?,
        asrEndNs: UInt64?,
        insertStartNs: UInt64?,
        insertEndNs: UInt64?,
        insertMethod: String?,
        outcome: String,
        chars: Int
    ) {
        let totalMs = ms(from: originNs, to: insertEndNs ?? asrEndNs ?? originNs)
        let toAsrMs = ms(from: originNs, to: asrStartNs)
        let asrMs = ms(from: asrStartNs, to: asrEndNs)
        let toInsertMs = ms(from: asrEndNs, to: insertStartNs)
        let insertMs = ms(from: insertStartNs, to: insertEndNs)
        let method = insertMethod ?? "none"

        log.info(
            """
            latency id=\(id, privacy: .public) \
            path=\(path, privacy: .public) \
            trigger=\(trigger, privacy: .public) \
            outcome=\(outcome, privacy: .public) \
            chars=\(chars, privacy: .public) \
            total_ms=\(totalMs, privacy: .public) \
            release_to_asr_ms=\(toAsrMs, privacy: .public) \
            asr_ms=\(asrMs, privacy: .public) \
            asr_to_insert_ms=\(toInsertMs, privacy: .public) \
            insert_ms=\(insertMs, privacy: .public) \
            insert_via=\(method, privacy: .public)
            """
        )
    }

    private static func ms(from start: UInt64?, to end: UInt64?) -> Int {
        guard let start, let end, end >= start else { return -1 }
        return Int((end - start) / 1_000_000)
    }
}
