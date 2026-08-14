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

    // Free / Focus Dictation (Earshot live endpointing in core)
    private var freeSuspendedByPtt = false
    private var freeMicOpen = false
    private var freeInFlight = 0
    private var focusWatcher = FocusWatcher()
    /// Drains mic / VAD on a dedicated queue so main-thread insert cannot stall endpointing.
    private let audioPumpQueue = DispatchQueue(label: "app.typwrtr.audio-pump")
    private var audioPumpTimer: DispatchSourceTimer?
    private enum AudioPumpKind { case off, stream, focus }
    private var audioPumpKind: AudioPumpKind = .off
    /// Latched focus so opening the menu bar does not drop Free listening.
    private var latchedFocus: FocusKind?
    private var latchedFocusPid: pid_t?
    private var latchedFocusAt: Date?
    /// Drop Focus pastes whose listen generation no longer matches (user left the field).
    private var freeInsertGeneration: UInt64 = 0

    /// Push to talk (streaming): Earshot live endpointing while the key is held.
    private var streamingPttActive = false
    private var streamInFlight = 0
    private var streamReleasePending = false
    /// Physical PTT chord down; used to start a hold that arrived during finishing.
    private var pttHeld = false
    /// Serial ASR for streaming / Focus closed segments (take_stream_segment is blocking).
    private let streamRecognizeQueue = DispatchQueue(label: "app.typwrtr.ptt-stream")
    /// One drain worker at a time so sticky SegmentEnded cannot inflate in-flight.
    private var streamDrainScheduled = false
    private var freeDrainScheduled = false
    /// Close arrived while a drain worker was finishing — take again after it lands.
    private var streamDrainNeeded = false
    private var freeDrainNeeded = false

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
        SetupDialog.onPttHotkeyChanged = { [weak self] hotkey in
            self?.applyPttHotkey(hotkey)
        }
        SetupDialog.onFreeArmChanged = { [weak self] armed in
            self?.setFreeArmed(armed)
        }
        menu.setCanUndo(session.lastText() != nil)
        menu.setPttHotkey(PttHotkey.current)
        hotkey.start()
        focusWatcher.onFocusPossiblyChanged = { [weak self] in
            self?.pollFreeFocus()
        }
        applyDictationMode(DictationMode.current)
        NSLog("Typwrtr: PTT coordinator started, backend=%@", backend.debugLabel)
    }

    /// Re-bind the system-wide PTT chord after Settings changes the preset.
    func applyPttHotkey(_ hotkey: PttHotkey) {
        PttHotkey.current = hotkey
        menu.setPttHotkey(hotkey)
        self.hotkey.restart()
    }

    /// Recreate the ASR session for a new language (idle only).
    func applyLanguage(_ language: AppLanguage) {
        guard phase == .idle,
              freeInFlight == 0,
              streamInFlight == 0,
              !streamingPttActive,
              !freeMicOpen
        else {
            menu.showError("Finish the current dictation before changing language.")
            return
        }
        stopAudioPump()
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
        if freeSuspendedByPtt || phase != .idle {
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
        // Replacing the listen while a drain is in flight would steal the new
        // field's audio into the previous segment's take.
        guard freeInFlight == 0, !freeDrainScheduled else { return }
        micAuthorized = true
        do {
            try session.startFocusListen()
            try mic.start()
            freeMicOpen = true
            insertTarget = NSWorkspace.shared.frontmostApplication
            menu.setFreeListeningIcon(true)
            startAudioPump(.focus)
            NSLog("Typwrtr: Free mic open (Earshot focus listen)")
            CaptureLog.note("focus listen started (earshot)")
        } catch {
            freeMicOpen = false
            session.finishStreamListen()
            NSLog("Typwrtr: Free mic start failed: %@", error.localizedDescription)
            menu.setFocusDictationStatus("Microphone failed")
        }
    }

    private func stopFreeMic(abandon: Bool) {
        guard freeMicOpen else { return }
        stopAudioPump()
        let captured = mic.stop()
        freeMicOpen = false
        if abandon {
            freeInsertGeneration += 1
            insertTarget = nil
        }
        if !captured.samples.isEmpty, !abandon {
            _ = try? session.pushStreamPcmF32(
                samples: captured.samples,
                sampleRate: captured.sampleRate
            )
        }
        if abandon {
            // Keep already-closed buffers for in-flight / scheduled takes.
            if freeInFlight == 0 && !freeDrainScheduled {
                session.finishStreamListen()
            }
        } else {
            _ = try? session.stopStreamListen()
            enqueueFreeSegment()
        }
        menu.setFreeListeningIcon(false)
        NSLog("Typwrtr: Free mic closed (abandon=%d)", abandon ? 1 : 0)
    }

    private func startAudioPump(_ kind: AudioPumpKind) {
        stopAudioPump()
        audioPumpKind = kind
        let timer = DispatchSource.makeTimerSource(queue: audioPumpQueue)
        timer.schedule(deadline: .now(), repeating: 0.08, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.pumpAudio()
        }
        timer.resume()
        audioPumpTimer = timer
    }

    private func stopAudioPump() {
        audioPumpKind = .off
        audioPumpTimer?.cancel()
        audioPumpTimer = nil
        audioPumpQueue.sync {}
    }

    private func pumpAudio() {
        switch audioPumpKind {
        case .off:
            return
        case .stream:
            processStreamAudio()
        case .focus:
            processFreeAudio()
        }
    }

    private func processFreeAudio() {
        let chunk = mic.drain()
        do {
            let event = try session.pushStreamPcmF32(samples: chunk, sampleRate: 16_000)
            switch event {
            case .none:
                break
            case .speechStarted:
                NSLog("Typwrtr: Focus Dictation speechStarted (earshot)")
                CaptureLog.note("focus earshot speechStarted")
            case .segmentEnded:
                CaptureLog.endpoint(reason: "earshot-silence", samples: chunk.count)
                DispatchQueue.main.async { [weak self] in
                    self?.enqueueFreeSegment()
                }
            }
        } catch {
            NSLog("Typwrtr: Focus push failed: %@", "\(error)")
            CaptureLog.note("focus push failed")
        }
    }

    private func enqueueFreeSegment() {
        if freeDrainScheduled {
            freeDrainNeeded = true
            return
        }
        freeDrainScheduled = true
        freeInFlight += 1
        menu.setStatus(.processing)
        let insertGen = freeInsertGeneration
        let target = insertTarget ?? NSWorkspace.shared.frontmostApplication
        NSLog("Typwrtr: Focus Dictation segment")

        streamRecognizeQueue.async { [weak self] in
            guard let self else { return }
            var results: [(text: String, samples: Int)] = []
            while true {
                do {
                    let text = try self.session.takeStreamSegment()
                    let metrics = self.session.lastCaptureMetrics()
                    CaptureLog.record(metrics, path: "free")
                    let samples = Int(metrics?.pushedSamples ?? 0)
                    results.append((text, samples))
                } catch {
                    break
                }
            }
            DispatchQueue.main.async {
                self.freeDrainScheduled = false
                if results.isEmpty {
                    self.freeInFlight = max(0, self.freeInFlight - 1)
                    self.finishFocusListenIfIdle()
                    self.refreshStatus()
                } else {
                    if results.count > 1 {
                        self.freeInFlight += results.count - 1
                    }
                    for item in results {
                        self.completeFreeSegment(
                            text: item.text,
                            samples: item.samples,
                            insertGen: insertGen,
                            target: target
                        )
                    }
                }
                if self.freeDrainNeeded {
                    self.freeDrainNeeded = false
                    self.enqueueFreeSegment()
                }
            }
        }
    }

    private func completeFreeSegment(
        text: String,
        samples: Int,
        insertGen: UInt64,
        target: NSRunningApplication?
    ) {
        freeInFlight = max(0, freeInFlight - 1)
        refreshStatus()
        menu.setLastCapture(samples: samples, sampleRate: 16_000)
        if insertGen != freeInsertGeneration {
            NSLog("Typwrtr: dropped free insert (left field)")
            CaptureLog.insert(path: "free", outcome: "dropped-left-field", chars: text.count)
            if shouldAcceptStreamResult(text: text) {
                menu.setLastText(text)
            }
        } else {
            insertTarget = target
            insertStreamResult(text: text, path: "free")
        }
        if freeMicOpen {
            menu.setStatus(.recording)
        }
        finishFocusListenIfIdle()
    }

    private func finishFocusListenIfIdle() {
        guard !freeMicOpen, freeInFlight == 0, !freeDrainScheduled else { return }
        session.finishStreamListen()
        refreshStatus()
        if !freeSuspendedByPtt {
            pollFreeFocus()
        }
    }

    func undoLast() {
        guard phase == .idle, freeInFlight == 0, streamInFlight == 0 else { return }
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
        if freeInFlight > 0 || freeMicOpen || streamingPttActive || streamInFlight > 0 {
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
        pttHeld = true
        if streamingPttActive || phase == .recording {
            return
        }
        // A previous stream listen still owns the slot until takes finish.
        if phase == .finishing || streamInFlight > 0 || streamDrainScheduled {
            NSLog("Typwrtr: PTT held; starting when previous stream finishes")
            return
        }
        guard micAuthorized || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            pttHeld = false
            menu.showError("Microphone permission is not granted.")
            return
        }
        micAuthorized = true

        // Q13 3b: temporary Free suspend for this PTT capture (do not disarm).
        freeSuspendedByPtt = true
        stopFreeMic(abandon: true)
        session.finishStreamListen()

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
        streamDrainScheduled = false
        insertTarget = NSWorkspace.shared.frontmostApplication
        menu.setCanUndo(false)
        menu.setStatus(.recording)
        do {
            try session.startStreamListen()
            try mic.start()
            startAudioPump(.stream)
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
        pttHeld = false
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
                    if self.pttHeld {
                        self.beginPtt()
                    } else {
                        self.pollFreeFocus()
                    }
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
        if pttHeld {
            beginPtt()
        } else {
            pollFreeFocus()
        }
    }

    private func processStreamAudio() {
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
                DispatchQueue.main.async { [weak self] in
                    self?.enqueueStreamSegment(reason: "earshot-silence")
                }
            }
        } catch {
            NSLog("Typwrtr: streaming push failed: %@", "\(error)")
            CaptureLog.note("streaming push failed")
        }
    }

    private func endStreamingPtt() {
        stopAudioPump()
        let captured = mic.stop()
        streamingPttActive = false
        streamReleasePending = true
        do {
            if !captured.samples.isEmpty {
                let event = try session.pushStreamPcmF32(
                    samples: captured.samples,
                    sampleRate: captured.sampleRate
                )
                if event == .segmentEnded {
                    CaptureLog.endpoint(reason: "earshot-silence", samples: captured.samples.count)
                    enqueueStreamSegment(reason: "earshot-silence")
                }
            }
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
        if streamDrainScheduled {
            streamDrainNeeded = true
            return
        }
        streamDrainScheduled = true
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
                self.streamDrainScheduled = false
                if results.isEmpty {
                    self.streamInFlight = max(0, self.streamInFlight - 1)
                    if self.streamingPttActive {
                        self.phase = .recording
                        self.menu.setStatus(.recording)
                    } else {
                        self.finishStreamingPttIfIdle()
                    }
                } else {
                    if results.count > 1 {
                        self.streamInFlight += results.count - 1
                    }
                    let whileHeld = reason == "earshot-silence" && self.streamingPttActive
                    for item in results {
                        self.completeStreamSegment(
                            text: item.text,
                            samples: item.samples,
                            whileHeld: whileHeld
                        )
                    }
                }
                if self.streamDrainNeeded {
                    self.streamDrainNeeded = false
                    self.enqueueStreamSegment(
                        reason: self.streamingPttActive ? "earshot-silence" : "earshot-release"
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
        guard !streamingPttActive, streamInFlight == 0, streamReleasePending, !streamDrainScheduled else { return }
        streamReleasePending = false
        session.finishStreamListen()
        phase = .idle
        freeSuspendedByPtt = false
        refreshStatus()
        NSLog("Typwrtr: streaming PTT idle")
        if pttHeld {
            beginPtt()
        } else {
            pollFreeFocus()
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
