import AppKit
import ApplicationServices
import AVFoundation

/// Owns hotkey, Free/VAD, mic capture, ASR session, and clipboard insert.
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
    private let freeController = FreeController()
    private var session: PttSession
    private var backend: AsrBackend
    private var phase: Phase = .idle
    private var micAuthorized = false
    /// Frontmost app at PTT-down / Free segment start — restore before paste.
    private var insertTarget: NSRunningApplication?

    // Free / VAD
    private var freeSuspendedByPtt = false
    private var freeMicOpen = false
    private var freeFinishing = false
    private var freeSegment: [Float] = []
    private var freeVad = SilenceVad()
    private var focusTimer: Timer?
    /// Latched focus so opening the menu bar does not drop Free listening.
    private var latchedFocus: FocusKind?
    private var latchedFocusPid: pid_t?
    private var latchedFocusAt: Date?

    init(menu: MenuBarModel, session: PttSession, backend: AsrBackend) {
        self.menu = menu
        self.session = session
        self.backend = backend
    }

    func start() {
        applyBackendToMenu()
        refreshStatus()
        syncFreeArmFromDefaults()

        mic.requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.micAuthorized = granted
                if !granted {
                    self?.menu.showError(
                        "Microphone access is required for dictation. Enable it in System Settings → Privacy & Security → Microphone."
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
        hotkey.onUndo = { [weak self] in
            self?.undoLast()
        }
        menu.onUndoRequested = { [weak self] in
            self?.undoLast()
        }
        menu.onLanguageSelected = { [weak self] language in
            self?.applyLanguage(language)
        }
        menu.onFreeArmChanged = { [weak self] armed in
            self?.setFreeArmed(armed)
        }
        SetupDialog.onLanguageChanged = { [weak self] language in
            self?.applyLanguage(language)
        }
        SetupDialog.onFreeArmChanged = { [weak self] armed in
            self?.setFreeArmed(armed)
        }
        menu.setCanUndo(session.lastText() != nil)
        hotkey.start()
        startFocusPolling()
        NSLog("Typwrtr: PTT coordinator started, backend=%@", backend.debugLabel)
    }

    /// Recreate the ASR session for a new language (idle only).
    func applyLanguage(_ language: AppLanguage) {
        guard phase == .idle, !freeFinishing else {
            menu.showError("Finish the current dictation before changing language.")
            return
        }
        AppLanguage.current = language
        let made = SessionFactory.makeSession(language: language)
        session = made.0
        backend = made.1
        applyBackendToMenu()
        menu.setCanUndo(session.lastText() != nil)
        menu.refreshSetupStatus()
        NSLog("Typwrtr: language=%@ backend=%@", language.displayName, backend.debugLabel)
    }

    private func applyBackendToMenu() {
        menu.setLanguage(AppLanguage.current)
        menu.setBackendDebug(backend.debugLabel)
    }

    private func syncFreeArmFromDefaults() {
        let armed = MenuBarModel.freeArmedPreference
        if armed {
            freeController.arm()
        } else {
            freeController.disarm()
        }
        menu.setFreeArmed(armed)
        pollFreeFocus()
    }

    private func setFreeArmed(_ armed: Bool) {
        MenuBarModel.freeArmedPreference = armed
        if armed {
            freeController.arm()
            NSLog("Typwrtr: Free armed")
        } else {
            freeController.disarm()
            stopFreeMic(abandon: true)
            NSLog("Typwrtr: Free disarmed")
        }
        menu.setFreeArmed(armed)
        pollFreeFocus()
    }

    private func startFocusPolling() {
        focusTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollFreeFocus()
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
        pollFreeFocus()
    }

    private func pollFreeFocus() {
        if freeSuspendedByPtt || freeFinishing || phase != .idle {
            return
        }

        if freeController.isArmed(), !AXIsProcessTrusted() {
            menu.setFreeAvailability(.unavailableExplained)
            menu.setFreeStatusDetail("Free: needs Accessibility")
            if freeMicOpen {
                stopFreeMic(abandon: true)
            }
            return
        }

        let focus = resolveFocus()
        let availability: FreeAvailability
        if let focus {
            availability = freeController.availability(focus: focus)
        } else {
            availability = freeController.availabilityWithoutFocus()
        }
        menu.setFreeAvailability(availability)

        let shouldListen = focus.map { freeController.shouldListen(focus: $0) } ?? false
        if shouldListen {
            if !freeMicOpen {
                startFreeMic()
            }
            // Menu-bar icon feedback while Free is actively listening.
            if freeMicOpen {
                menu.setFreeListeningIcon(true)
            }
            processFreeAudio()
        } else if freeMicOpen {
            stopFreeMic(abandon: true)
            menu.setFreeListeningIcon(false)
        } else if phase == .idle {
            menu.setFreeListeningIcon(false)
        }
    }

    /// Prefer live AX probe; if the menu-bar agent briefly steals key window, keep
    /// the last text-field focus for the same frontmost app (~2s).
    private func resolveFocus() -> FocusKind? {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let probed = FocusProbe.probe()
        if let live = probed.kind {
            latchedFocus = live
            latchedFocusPid = frontPid
            latchedFocusAt = Date()
            return live
        }
        if let latched = latchedFocus,
           let pid = latchedFocusPid,
           let at = latchedFocusAt,
           frontPid == pid,
           Date().timeIntervalSince(at) < 2.5,
           latched == .textField
        {
            return latched
        }
        return nil
    }

    private func startFreeMic() {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micAuthorized || auth == .authorized else {
            NSLog("Typwrtr: Free mic skipped (auth=%d)", auth.rawValue)
            menu.setFreeStatusDetail("Free: needs Microphone")
            return
        }
        micAuthorized = true
        do {
            try mic.start()
            freeMicOpen = true
            freeSegment.removeAll(keepingCapacity: true)
            freeVad.reset()
            insertTarget = NSWorkspace.shared.frontmostApplication
            menu.setFreeListeningIcon(true)
            NSLog("Typwrtr: Free mic open")
        } catch {
            freeMicOpen = false
            NSLog("Typwrtr: Free mic start failed: %@", error.localizedDescription)
            menu.setFreeStatusDetail("Free: mic failed")
        }
    }

    private func stopFreeMic(abandon: Bool) {
        guard freeMicOpen else { return }
        _ = mic.stop()
        freeMicOpen = false
        if abandon {
            freeSegment.removeAll(keepingCapacity: true)
            freeVad.reset()
        }
        menu.setFreeListeningIcon(false)
        NSLog("Typwrtr: Free mic closed (abandon=%d)", abandon ? 1 : 0)
    }

    private func processFreeAudio() {
        guard freeMicOpen, !freeFinishing else { return }
        let chunk = mic.drain()
        guard !chunk.isEmpty else { return }
        freeSegment.append(contentsOf: chunk)
        switch freeVad.push(samples: chunk) {
        case .none, .speechStarted:
            break
        case .segmentEnded:
            finalizeFreeSegment()
        }
    }

    private func finalizeFreeSegment() {
        guard !freeFinishing else { return }
        freeFinishing = true
        let samples = freeSegment
        freeSegment.removeAll(keepingCapacity: true)
        freeVad.reset()
        stopFreeMic(abandon: false)

        guard !samples.isEmpty else {
            freeFinishing = false
            pollFreeFocus()
            return
        }

        menu.setStatus(.processing)
        let target = insertTarget ?? NSWorkspace.shared.frontmostApplication
        insertTarget = target

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.session.startPtt()
                try self.session.pushPcmF32(samples: samples, sampleRate: 16_000)
                let text = try self.session.stopPtt()
                DispatchQueue.main.async {
                    self.freeFinishing = false
                    self.refreshStatus()
                    self.menu.setLastCapture(samples: samples.count, sampleRate: 16_000)
                    self.menu.setLastText(text)
                    NSLog("Typwrtr: Free segment (%d chars): %@", text.count, text)
                    self.restoreInsertTargetFocus()
                    switch self.inserter.insert(text) {
                    case .emptyText:
                        break
                    case .pasted:
                        self.menu.setCanUndo(true)
                    case .clipboardOnly:
                        self.menu.setCanUndo(true)
                        self.showPasteNeedsAccessibility(text: text)
                    }
                    self.pollFreeFocus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.freeFinishing = false
                    try? self.session.cancel()
                    self.refreshStatus()
                    self.menu.showError("Free dictation failed: \(error)")
                    self.pollFreeFocus()
                }
            }
        }
    }

    func undoLast() {
        guard phase == .idle, !freeFinishing else { return }
        guard let text = session.takeUndoPayload() else {
            menu.setCanUndo(false)
            return
        }
        menu.clearLastText()
        restoreInsertTargetFocus()
        if inserter.undoLastInsertion(text) {
            NSLog("Typwrtr: undo succeeded")
            refreshStatus()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        menu.showError(
            """
            Could not remove the last insert from the field.

            Text is on the clipboard (and was cleared from Typwrtr’s undo buffer):

            \(text)
            """
        )
    }

    func confirmQuitIfBusy() -> NSApplication.TerminateReply {
        if freeFinishing || freeMicOpen {
            let alert = NSAlert()
            alert.messageText = "Discard and quit?"
            alert.informativeText = "Typwrtr Free mode is still listening or processing."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
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
        guard phase == .idle, !freeFinishing else { return }
        guard micAuthorized || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            menu.showError("Microphone permission is not granted.")
            return
        }
        micAuthorized = true

        // Q13 3b: temporary Free suspend for this PTT capture (do not disarm).
        freeSuspendedByPtt = true
        stopFreeMic(abandon: true)

        phase = .recording
        insertTarget = NSWorkspace.shared.frontmostApplication
        menu.setCanUndo(false)
        menu.setStatus(.recording)
        do {
            try session.startPtt()
            try mic.start()
            refreshStatus()
        } catch {
            phase = .idle
            freeSuspendedByPtt = false
            _ = mic.stop()
            try? session.cancel()
            refreshStatus()
            menu.showError("PTT start failed: \(error.localizedDescription)")
            pollFreeFocus()
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
                    self.freeSuspendedByPtt = false
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
                        self.menu.setCanUndo(true)
                    case .clipboardOnly:
                        self.menu.setCanUndo(true)
                        self.showPasteNeedsAccessibility(text: text)
                    }
                    self.pollFreeFocus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .idle
                    self.freeSuspendedByPtt = false
                    self.refreshStatus()
                    self.menu.showError("PTT failed: \(error)")
                    self.pollFreeFocus()
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
