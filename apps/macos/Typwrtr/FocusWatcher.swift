import AppKit
import ApplicationServices
import Foundation

/// Quiet focus watching for Free mode.
///
/// Avoids AXObserver on `FocusedUIElementChanged` — Electron apps (Cursor) fire
/// that constantly and each follow-up AX probe makes the assistive “pip” sound.
/// We react to app activation plus a 100 ms timer. Most ticks are `cheap`: the
/// coordinator compares the focused element and probes only if it changed, so a
/// click into a field shows the bar within ~0.1 s and leaving it closes the mic
/// (Q4). Every 30th tick (~3 s) and every activation asks for a full probe.
final class FocusWatcher {
    /// `cheap` = true: compare the focused element, probe only on change.
    var onFocusPossiblyChanged: ((_ cheap: Bool) -> Void)?

    private var workspaceObserver: NSObjectProtocol?
    private var backupTimer: Timer?
    private var debounceWork: DispatchWorkItem?
    private var running = false
    private var tick = 0
    private var pendingFull = false

    func start() {
        guard !running else { return }
        running = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emitDebounced(delay: 0.15, cheap: false)
        }

        backupTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.tick += 1
            self.emitDebounced(delay: 0, cheap: self.tick % 30 != 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        backupTimer = timer

        emitDebounced(delay: 0, cheap: false)
    }

    func stop() {
        running = false
        debounceWork?.cancel()
        debounceWork = nil
        backupTimer?.invalidate()
        backupTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    private func emitDebounced(delay: TimeInterval, cheap: Bool) {
        // A pending full probe is not downgraded by a later cheap tick.
        let cheap = cheap && !pendingFull
        pendingFull = !cheap
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFull = false
            self?.onFocusPossiblyChanged?(cheap)
        }
        debounceWork = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}
