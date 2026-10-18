import AppKit
import ApplicationServices
import Foundation

/// Quiet focus watching for Free mode.
///
/// Avoids AXObserver on `FocusedUIElementChanged` — Electron apps (Cursor) fire
/// that constantly and each follow-up AX probe makes the assistive “pip” sound.
/// We react to app activation plus a backup timer: a full probe every ~3 s while
/// waiting for a field, and a cheap focused-element comparison every 200 ms while
/// listening (a move inside the same app must close the mic and bar, Q4).
final class FocusWatcher {
    var onFocusPossiblyChanged: (() -> Void)?

    /// True while the mic is open: every 200 ms tick reaches the coordinator so it can
    /// compare the focused element; otherwise every 15th tick (~3 s) runs a full probe.
    var quietWhileListening = false

    private var workspaceObserver: NSObjectProtocol?
    private var backupTimer: Timer?
    private var debounceWork: DispatchWorkItem?
    private var running = false
    private var tick = 0

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

        backupTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.tick += 1
            guard self.quietWhileListening || self.tick % 15 == 0 else { return }
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
