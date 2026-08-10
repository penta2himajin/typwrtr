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
    private var freeVad: SilenceVad = {
        var vad = SilenceVad()
        vad.silenceSeconds = focusDictationSilenceSeconds()
        return vad
    }()
    private var focusWatcher = FocusWatcher()
    /// Drains mic / VAD while Free is listening (independent of AX focus watches).
    private var freeAudioTimer: Timer?
    /// Latched focus so opening the menu bar does not drop Free listening.
    private var latchedFocus: FocusKind?
    private var latchedFocusPid: pid_t?
    private var latchedFocusAt: Date?

    /// Push to talk (streaming): Earshot live endpointing while the key is held.
    private var streamingPttActive = false
    private var streamAudioTimer: Timer?
    private var streamInFlight = 0
    private var streamReleasePending = false
    /// Serial ASR for streaming segments (take_stream_segment is blocking).
    private let streamRecognizeQueue = DispatchQueue(label: "app.typwrtr.ptt-stream")

    init(menu: MenuBarModel, session: PttSession, backend: AsrBackend) {
        self.menu = menu
        self.session = session
        self.backend = backend
    }

    func start() {
        applyBackendToMenu()
        refreshStatus()

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
        menu.onDictationModeChanged = { [weak self] mode in
            self?.applyDictationMode(mode)
        }
        SetupDialog.onLanguageChanged = { [weak self] language in
            self?.applyLanguage(language)
        }
        SetupDialog.onDictionaryChanged = { [weak self] in
            self?.applyLanguage(AppLanguage.current)
        }
        SetupDialog.onDictationModeChanged = { [weak self] mode in
            self?.applyDictationMode(mode)
        }
        SetupDialog.onFreeArmChanged = { [weak self] armed in
            self?.setFreeArmed(armed)
        }
        menu.setCanUndo(session.lastText() != nil)
        hotkey.start()
        focusWatcher.onFocusPossiblyChanged = { [weak self] in
            self?.pollFreeFocus()
        }
        applyDictationMode(DictationMode.current)
        NSLog("Typwrtr: PTT coordinator started, backend=%@", backend.debugLabel)
    }

    /// Recreate the ASR session for a new language (idle only).
    func applyLanguage(_ language: AppLanguage) {
        guard phase == .idle, !freeFinishing, streamInFlight == 0, !streamingPttActive else {
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
        applyDictationMode(DictationMode.current)
    }

    private func applyDictationMode(_ mode: DictationMode) {
        DictationMode.current = mode
        setFreeArmed(mode.isFocusDictation)
        NSLog("Typwrtr: dictation mode=%@", mode.rawValue)
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
        updateFocusWatching(armed: armed)
        pollFreeFocus()
    }

    /// AX focus watching only while Free is armed — continuous AX polling
    /// sounds like a screen reader (“pip”) and is unnecessary when disarmed.
    private func updateFocusWatching(armed: Bool) {
        if armed {
            focusWatcher.start()
        } else {
            focusWatcher.stop()
        }
    }

    private func pollFreeFocus() {
        if freeSuspendedByPtt || freeFinishing || phase != .idle {
            return
        }

        guard freeController.isArmed() else {
            focusWatcher.quietWhileListening = false
            menu.setFreeAvailability(.disarmed)
            menu.setFreeListeningIcon(false)
            return
        }

        if !AXIsProcessTrusted() {
            focusWatcher.quietWhileListening = false
            menu.setFreeAvailability(.unavailableExplained)
            menu.setFocusDictationStatus("Needs Accessibility")
            if freeMicOpen {
                stopFreeMic(abandon: true)
            }
            return
        }

        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Already listening in the same app: do not re-probe AX (stops pip spam).
        if freeMicOpen,
           latchedFocus == .textField,
           frontPid != nil,
           frontPid == latchedFocusPid
        {
            focusWatcher.quietWhileListening = true
            menu.setFreeListeningIcon(true)
            menu.setFreeAvailability(.listening)
            return
        }

        // Left the target app while listening — stop mic without a full probe first.
        if freeMicOpen, frontPid != latchedFocusPid {
            stopFreeMic(abandon: true)
            focusWatcher.quietWhileListening = false
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
            focusWatcher.quietWhileListening = freeMicOpen
            if freeMicOpen {
                menu.setFreeListeningIcon(true)
            }
        } else if freeMicOpen {
            stopFreeMic(abandon: true)
            focusWatcher.quietWhileListening = false
            menu.setFreeListeningIcon(false)
        } else {
            focusWatcher.quietWhileListening = false
            if phase == .idle {
                menu.setFreeListeningIcon(false)
            }
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
            menu.setFocusDictationStatus("Needs Microphone")
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
            startFreeAudioTimer()
            NSLog("Typwrtr: Free mic open")
        } catch {
            freeMicOpen = false
            NSLog("Typwrtr: Free mic start failed: %@", error.localizedDescription)
            menu.setFocusDictationStatus("Microphone failed")
        }
    }

    private func stopFreeMic(abandon: Bool) {
        guard freeMicOpen else { return }
        stopFreeAudioTimer()
        _ = mic.stop()
        freeMicOpen = false
        if abandon {
            freeSegment.removeAll(keepingCapacity: true)
            freeVad.reset()
        }
        menu.setFreeListeningIcon(false)
        NSLog("Typwrtr: Free mic closed (abandon=%d)", abandon ? 1 : 0)
    }

    private func startFreeAudioTimer() {
        stopFreeAudioTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.processFreeAudio()
        }
        RunLoop.main.add(timer, forMode: .common)
        freeAudioTimer = timer
    }

    private func stopFreeAudioTimer() {
        freeAudioTimer?.invalidate()
        freeAudioTimer = nil
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
                let metrics = self.session.lastCaptureMetrics()
                CaptureLog.record(metrics, path: "free")
                DispatchQueue.main.async {
                    self.freeFinishing = false
                    self.refreshStatus()
                    self.menu.setLastCapture(samples: samples.count, sampleRate: 16_000)
                    self.insertStreamResult(text: text, path: "free")
                    self.pollFreeFocus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.freeFinishing = false
                    try? self.session.cancel()
                    self.refreshStatus()
                    NSLog("Typwrtr: Free segment failed: %@", "\(error)")
                    self.pollFreeFocus()
                }
            }
        }
    }

    func undoLast() {
        guard phase == .idle, !freeFinishing, streamInFlight == 0 else { return }
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
        if freeFinishing || freeMicOpen || streamingPttActive || streamInFlight > 0 {
            let alert = NSAlert()
            alert.messageText = "Discard and quit?"
            alert.informativeText = "Typwrtr is still listening or processing."
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
        guard phase == .idle, !freeFinishing, streamInFlight == 0 else { return }
        guard micAuthorized || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            menu.showError("Microphone permission is not granted.")
            return
        }
        micAuthorized = true

        // Q13 3b: temporary Free suspend for this PTT capture (do not disarm).
        freeSuspendedByPtt = true
        stopFreeMic(abandon: true)

        if DictationMode.current.isStreamingPtt {
            beginStreamingPtt()
        } else {
            beginBatchPtt()
        }
    }

    private func beginBatchPtt() {
        phase = .recording
        streamingPttActive = false
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

    private func beginStreamingPtt() {
        phase = .recording
        streamingPttActive = true
        streamReleasePending = false
        insertTarget = NSWorkspace.shared.frontmostApplication
        menu.setCanUndo(false)
        menu.setStatus(.recording)
        do {
            try session.startStreamListen()
            try mic.start()
            startStreamAudioTimer()
            refreshStatus()
            NSLog("Typwrtr: streaming PTT started (Earshot live endpoint)")
            CaptureLog.note("streaming PTT started (earshot)")
        } catch {
            phase = .idle
            streamingPttActive = false
            freeSuspendedByPtt = false
            session.finishStreamListen()
            _ = mic.stop()
            refreshStatus()
            menu.showError("PTT start failed: \(error.localizedDescription)")
            pollFreeFocus()
        }
    }

    private func endPtt() {
        if streamingPttActive {
            endStreamingPtt()
            return
        }
        guard phase == .recording else { return }
        endBatchPtt()
    }

    private func endBatchPtt() {
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
                CaptureLog.record(self.session.lastCaptureMetrics(), path: "ptt")
                DispatchQueue.main.async {
                    self.finishBatchPtt(text: text)
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .idle
                    self.freeSuspendedByPtt = false
                    try? self.session.cancel()
                    self.refreshStatus()
                    self.menu.showError("PTT failed: \(error)")
                    self.pollFreeFocus()
                }
            }
        }
    }

    private func finishBatchPtt(text: String) {
        phase = .idle
        freeSuspendedByPtt = false
        refreshStatus()
        menu.setLastCapture(
            samples: mic.lastSampleCount,
            sampleRate: mic.lastSampleRate
        )
        menu.setLastText(text)
        NSLog("Typwrtr: recognized text (%d chars): %@", text.count, text)
        restoreInsertTargetFocus()
        switch inserter.insert(text, into: insertTarget) {
        case .emptyText:
            // ux-decisions Q24: nothing was said.
            break
        case .pasted:
            menu.setCanUndo(true)
        case .clipboardOnly:
            menu.setCanUndo(true)
            showPasteNeedsAccessibility(text: text)
        }
        pollFreeFocus()
    }

    private func startStreamAudioTimer() {
        stopStreamAudioTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.processStreamAudio()
        }
        RunLoop.main.add(timer, forMode: .common)
        streamAudioTimer = timer
    }

    private func stopStreamAudioTimer() {
        streamAudioTimer?.invalidate()
        streamAudioTimer = nil
    }

    private func processStreamAudio() {
        // Keep draining while the key is held, even if a prior segment is recognising.
        guard streamingPttActive else { return }
        let chunk = mic.drain()
        do {
            let event = try session.pushStreamPcmF32(samples: chunk, sampleRate: 16_000)
            switch event {
            case .none:
                break
            case .speechStarted:
                NSLog("Typwrtr: streaming PTT speechStarted (earshot)")
                CaptureLog.note("streaming earshot speechStarted")
            case .segmentEnded:
                CaptureLog.endpoint(reason: "earshot-silence", samples: chunk.count)
                enqueueStreamSegment(reason: "earshot-silence")
            }
        } catch {
            NSLog("Typwrtr: streaming push failed: %@", "\(error)")
            CaptureLog.note("streaming push failed")
        }
    }

    private func endStreamingPtt() {
        stopStreamAudioTimer()
        _ = mic.stop()
        streamingPttActive = false
        streamReleasePending = true
        do {
            let event = try session.stopStreamListen()
            if event == .segmentEnded {
                CaptureLog.endpoint(reason: "earshot-release", samples: 0)
                enqueueStreamSegment(reason: "earshot-release")
            } else {
                CaptureLog.note("streaming release discarded (no open utterance)")
                NSLog("Typwrtr: streaming PTT release discarded (no open utterance)")
            }
        } catch {
            NSLog("Typwrtr: streaming stop failed: %@", "\(error)")
        }
        finishStreamingPttIfIdle()
    }

    private func enqueueStreamSegment(reason: String) {
        streamInFlight += 1
        if !streamingPttActive {
            phase = .finishing
            menu.setStatus(.processing)
        }
        let target = insertTarget ?? NSWorkspace.shared.frontmostApplication
        insertTarget = target
        NSLog("Typwrtr: streaming PTT segment reason=%@", reason)

        streamRecognizeQueue.async { [weak self] in
            guard let self else { return }
            var results: [(text: String, samples: Int)] = []
            while true {
                do {
                    let text = try self.session.takeStreamSegment()
                    let metrics = self.session.lastCaptureMetrics()
                    CaptureLog.record(metrics, path: "ptt-stream")
                    let samples = Int(metrics?.pushedSamples ?? 0)
                    results.append((text, samples))
                } catch {
                    break
                }
            }
            DispatchQueue.main.async {
                if results.isEmpty {
                    self.streamInFlight = max(0, self.streamInFlight - 1)
                    if self.streamingPttActive {
                        self.phase = .recording
                        self.menu.setStatus(.recording)
                    } else {
                        self.finishStreamingPttIfIdle()
                    }
                    return
                }
                if results.count > 1 {
                    self.streamInFlight += results.count - 1
                }
                for item in results {
                    self.completeStreamSegment(
                        text: item.text,
                        samples: item.samples,
                        whileHeld: reason == "earshot-silence"
                    )
                }
            }
        }
    }

    private func completeStreamSegment(text: String, samples: Int, whileHeld: Bool) {
        streamInFlight = max(0, streamInFlight - 1)
        menu.setLastCapture(samples: samples, sampleRate: 16_000)
        insertStreamResult(
            text: text,
            path: "ptt-stream",
            policy: whileHeld ? .whileModifiersHeld : .waitForModifiers
        )
        if streamingPttActive {
            phase = .recording
            menu.setStatus(.recording)
        } else {
            finishStreamingPttIfIdle()
        }
    }

    /// Shared accept/insert path for Free and streaming PTT.
    private func insertStreamResult(
        text: String,
        path: String,
        policy: ClipboardInserter.Policy = .waitForModifiers
    ) {
        guard shouldAcceptStreamResult(text: text) else {
            NSLog("Typwrtr: dropped %@ insert (empty)", path)
            CaptureLog.insert(path: path, outcome: "dropped-empty", chars: 0)
            return
        }
        menu.setLastText(text)
        NSLog("Typwrtr: %@ segment (%d chars): %@", path, text.count, text)
        restoreInsertTargetFocus()
        switch inserter.insert(text, into: insertTarget, policy: policy) {
        case .emptyText:
            CaptureLog.insert(path: path, outcome: "empty", chars: 0)
        case .pasted:
            menu.setCanUndo(true)
            CaptureLog.insert(path: path, outcome: "pasted", chars: text.count)
        case .clipboardOnly:
            menu.setCanUndo(true)
            CaptureLog.insert(path: path, outcome: "clipboard-only", chars: text.count)
            NSLog("Typwrtr: insert clipboard-only (%@) — press ⌘V", path)
            Permissions.registerInAccessibilityList()
        }
    }

    private func finishStreamingPttIfIdle() {
        guard !streamingPttActive, streamInFlight == 0, streamReleasePending else { return }
        streamReleasePending = false
        session.finishStreamListen()
        phase = .idle
        freeSuspendedByPtt = false
        refreshStatus()
        pollFreeFocus()
        NSLog("Typwrtr: streaming PTT idle")
    }

    private func restoreInsertTargetFocus() {
        guard let target = insertTarget,
              target.processIdentifier != getpid(),
              !target.isTerminated
        else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != target.processIdentifier {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.15)
        } else {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func showPasteNeedsAccessibility(text: String) {
        Permissions.registerInAccessibilityList()
        menu.setStatus(.error)
        let alert = NSAlert()
        alert.messageText = "Couldn’t insert into the field"
        alert.informativeText = """
            Dictation worked, but auto-insert into the focused app failed.

            Text is on the clipboard — press ⌘V to paste:

            \(text)

            If this keeps happening in Cursor / browsers, confirm Typwrtr is enabled under
            System Settings → Privacy & Security → Accessibility.
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
