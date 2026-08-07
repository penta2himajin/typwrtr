import AppKit
import AVFoundation

/// Owns hotkey, mic capture, ASR session, and clipboard insert.
final class PttCoordinator {
    private enum Phase {
        case idle
        case recording
        case finishing
    }

    private let menu: MenuBarModel
    private let hotkey = HotkeyMonitor()
    private let inserter = ClipboardInserter()
    private let mic = MicCapture()
    private var session: PttSession
    private let backend: AsrBackend
    private var phase: Phase = .idle
    private var micAuthorized = false
    /// Frontmost app at PTT-down — restore focus here before paste (ASR may steal focus).
    private var insertTarget: NSRunningApplication?

    init(menu: MenuBarModel, session: PttSession, backend: AsrBackend) {
        self.menu = menu
        self.session = session
        self.backend = backend
    }

    func start() {
        menu.setBackend(backend.menuLabel)
        refreshStatus()

        mic.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.micAuthorized = granted
                if !granted {
                    self?.menu.showError(
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
        NSLog("Typwrtr: PTT coordinator started, backend=%@", backend.menuLabel)
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
        // Ignore duplicate Carbon presses while already recording / finishing ASR.
        guard phase == .idle else { return }
        guard micAuthorized || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            menu.showError("Microphone permission is not granted.")
            return
        }
        micAuthorized = true
        phase = .recording
        insertTarget = NSWorkspace.shared.frontmostApplication
        menu.setStatus(.recording)
        do {
            try session.startPtt()
            try mic.start()
            refreshStatus()
        } catch {
            phase = .idle
            _ = mic.stop()
            try? session.cancel()
            refreshStatus()
            menu.showError("PTT start failed: \(error.localizedDescription)")
        }
    }

    private func endPtt() {
        guard phase == .recording else { return }
        phase = .finishing
        let captured = mic.stop()
        menu.setStatus(.processing)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if !captured.samples.isEmpty {
                    try self.session.pushPcmF32(
                        samples: captured.samples,
                        sampleRate: captured.sampleRate
                    )
                } else {
                    try self.session.pushPcmF32(
                        samples: [Float](repeating: 0, count: 1600),
                        sampleRate: 16_000
                    )
                }
                let text = try self.session.stopPtt()
                DispatchQueue.main.async {
                    self.phase = .idle
                    self.refreshStatus()
                    self.menu.setLastCapture(
                        samples: self.mic.lastSampleCount,
                        sampleRate: self.mic.lastSampleRate
                    )
                    self.menu.setLastText(text)
                    NSLog("Typwrtr: recognized text (%d chars): %@", text.count, text)
                    self.restoreInsertTargetFocus()
                    switch self.inserter.insert(text) {
                    case .emptyText:
                        self.menu.showError(
                            "No text recognized. Speak longer, or check that ASR is Parakeet ja / Whisper."
                        )
                    case .pasted:
                        break
                    case .clipboardOnly:
                        self.showPasteNeedsAccessibility(text: text)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .idle
                    self.refreshStatus()
                    self.menu.showError("PTT failed: \(error)")
                }
            }
        }
    }

    private func restoreInsertTargetFocus() {
        guard let target = insertTarget,
              target.processIdentifier != getpid(),
              !target.isTerminated
        else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != target.processIdentifier {
            // Avoid re-activating if already frontmost (Chromium can drop first responder).
            _ = target.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    private func showPasteNeedsAccessibility(text: String) {
        Permissions.registerInAccessibilityList()
        menu.setStatus(.error)
        let alert = NSAlert()
        alert.messageText = "Typwrtr needs Accessibility"
        alert.informativeText = """
            Dictation worked, but auto-paste needs Accessibility.

            1. Open Accessibility settings
            2. Enable Typwrtr (toggle off→on if it was already listed)
            3. Quit and reopen Typwrtr

            Text is on the clipboard — you can ⌘V now:

            \(text)
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    private func refreshStatus() {
        menu.setStatus(session.status())
    }
}
