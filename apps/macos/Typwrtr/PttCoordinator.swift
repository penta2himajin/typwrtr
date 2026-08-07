import AppKit
import AVFoundation

/// Owns menu-bar UI, hotkey, mic capture, FixedAsr PTT session, and clipboard insert.
final class PttCoordinator {
    private let statusItem = StatusItemController()
    private let hotkey = HotkeyMonitor()
    private let inserter = ClipboardInserter()
    private let mic = MicCapture()
    private var session: PttSession
    private var isPttHeld = false
    private var micAuthorized = false

    init() {
        // Dogfood without models: ASR text is fixed, then euhadra Tier 1+2 runs.
        // Mic path is real — samples are pushed into the session for the next ASR wiring.
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

        mic.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.micAuthorized = granted
                if !granted {
                    self?.statusItem.showError(
                        "Microphone access is required for push-to-talk. Enable it in System Settings → Privacy & Security → Microphone."
                    )
                }
            }
        }

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
        guard micAuthorized || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            statusItem.showError("Microphone permission is not granted.")
            return
        }
        micAuthorized = true
        isPttHeld = true
        do {
            try session.startPtt()
            try mic.start()
            refreshStatus()
        } catch {
            isPttHeld = false
            _ = mic.stop()
            try? session.cancel()
            refreshStatus()
            statusItem.showError("PTT start failed: \(error.localizedDescription)")
        }
    }

    private func endPtt() {
        guard isPttHeld else { return }
        isPttHeld = false
        let captured = mic.stop()
        refreshStatus()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if !captured.samples.isEmpty {
                    try self.session.pushPcmF32(
                        samples: captured.samples,
                        sampleRate: captured.sampleRate
                    )
                } else {
                    // Avoid empty-audio ASR failures once real models land; keep a tiny pad.
                    try self.session.pushPcmF32(
                        samples: [Float](repeating: 0, count: 1600),
                        sampleRate: 16_000
                    )
                }
                let text = try self.session.stopPtt()
                DispatchQueue.main.async {
                    self.refreshStatus()
                    self.statusItem.setLastCapture(
                        samples: self.mic.lastSampleCount,
                        sampleRate: self.mic.lastSampleRate
                    )
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
