import AppKit

/// Owns menu-bar UI, hotkey, FixedAsr PTT session, and clipboard insert.
final class PttCoordinator {
    private let statusItem = StatusItemController()
    private let hotkey = HotkeyMonitor()
    private let inserter = ClipboardInserter()
    private var session: PttSession
    private var isPttHeld = false

    init() {
        // Dogfood without models: ASR text is fixed, then euhadra Tier 1+2 runs.
        session = try! PttSession.withFixedTranscript(
            language: .english,
            fixedTranscript: "um hello from typwrtr"
        )
    }

    func start() {
        statusItem.install(quitHandler: { [weak self] in
            NSApp.terminate(self)
        })
        refreshStatus()

        hotkey.onPttDown = { [weak self] in
            self?.beginPtt()
        }
        hotkey.onPttUp = { [weak self] in
            self?.endPtt()
        }
        hotkey.start()
    }

    func confirmQuitIfBusy() -> NSApplication.TerminateReply {
        switch session.status() {
        case .recording, .processing:
            let alert = NSAlert()
            alert.messageText = "Discard and quit?"
            alert.informativeText = "Typwrtr is still recording or processing."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        case .idle, .error:
            return .terminateNow
        }
    }

    private func beginPtt() {
        guard !isPttHeld else { return }
        isPttHeld = true
        do {
            try session.startPtt()
            refreshStatus()
        } catch {
            isPttHeld = false
            statusItem.showError("PTT start failed: \(error)")
        }
    }

    private func endPtt() {
        guard isPttHeld else { return }
        isPttHeld = false
        refreshStatus() // processing once stop begins
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // FixedAsr ignores samples; still exercise the audio path.
                try self.session.pushPcmF32(samples: [Float](repeating: 0, count: 1600), sampleRate: 16_000)
                let text = try self.session.stopPtt()
                DispatchQueue.main.async {
                    self.refreshStatus()
                    let ok = self.inserter.insert(text)
                    if !ok {
                        self.statusItem.showError("Inserted to clipboard only — paste manually (⌘V).")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.refreshStatus()
                    self.statusItem.showError("PTT failed: \(error)")
                }
            }
        }
    }

    private func refreshStatus() {
        statusItem.setStatus(session.status())
    }
}
