import AppKit
import ApplicationServices
import Foundation

/// Quiet focus watching for Free mode.
///
/// Avoids AXObserver on `FocusedUIElementChanged` — Electron apps (Cursor) fire
/// that constantly and each follow-up AX probe makes the assistive “pip” sound.
/// We only react to app activation plus a slow backup while **not** already listening.
final class FocusWatcher {
    var onFocusPossiblyChanged: (() -> Void)?

    /// When true, skip backup probes (mic already open for a text field).
    var quietWhileListening = false

    private var workspaceObserver: NSObjectProtocol?
    private var backupTimer: Timer?
    private var debounceWork: DispatchWorkItem?
    private var running = false

    func start() {
        guard !running else { return }
        running = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emitDebounced(delay: 0.15)
        }

        // Slow backup only when waiting for a field — not while already listening.
        backupTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self, self.running, !self.quietWhileListening else { return }
            self.emitDebounced(delay: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        backupTimer = timer

        emitDebounced(delay: 0)
    }

    func stop() {
        running = false
        quietWhileListening = false
        debounceWork?.cancel()
        debounceWork = nil
        backupTimer?.invalidate()
        backupTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    private func emitDebounced(delay: TimeInterval) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onFocusPossiblyChanged?()
        }
        debounceWork = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}
