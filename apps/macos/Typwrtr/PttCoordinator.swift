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
    // ponytail: nil only until the launch load lands; every path that starts dictation
    // checks `sessionLoading` first, so call sites stay unchanged.
    private var session: PttSession!
    private var backend: AsrBackend!
    /// A `SessionFactory` load is running (launch, language switch, dictionary save).
    /// Dictation does not start; the previous session, if any, stays until the swap.
    private var sessionLoading = false
    private var sessionLoadGeneration: UInt64 = 0
    // ponytail: serial, so a switch during a cold ja load waits for it rather than
    // compiling into the same ANE cache twice. Cancel the stale load if that wait matters.
    private let sessionLoadQueue = DispatchQueue(label: "app.typwrtr.session-load", qos: .userInitiated)
    /// Main-run-loop tick while a load runs, so the capture log shows the main thread
    /// stayed free (`scripts/check-cold-load.sh`). A blocked main thread logs no ticks.
    private var loadHeartbeat: Timer?
    private var loadHeartbeatTicks = 0
    private var phase: Phase = .idle
    private var micAuthorized = false
    /// Frontmost app at PTT-down / Free segment start — restore before paste.
    private var insertTarget: NSRunningApplication?

    // Free / Focus Dictation (Earshot live endpointing in core)
    private var freeSuspendedByPtt = false
    private var freeMicOpen = false
    private var freeInFlight = 0
    private var focusWatcher = FocusWatcher()
    private let listeningIndicator = ListeningIndicator()
    /// Batch PTT key-down time, so a quick tap is not judged a dead mic (Q43).
    private var pttStartedAt = Date.distantPast
    /// First ~2 s of a Focus listen, checked once for a dead mic (Q43). Audio pump queue only.
    private var focusProbe: [Float] = []
    private var focusProbeDone = true
    private var focusProbeStartedAt = Date.distantPast
    /// Focus capture-log window (pump queue only): samples and start of the current 2 s.
    private var focusStatsSamples: [Float] = []
    private var focusStatsAt = Date.distantPast
    /// Drains mic / VAD on a dedicated queue so main-thread insert cannot stall endpointing.
    private let audioPumpQueue = DispatchQueue(label: "app.typwrtr.audio-pump")
    private var audioPumpTimer: DispatchSourceTimer?
    private enum AudioPumpKind { case off, stream, focus }
    private var audioPumpKind: AudioPumpKind = .off
    /// Latched focus so opening the menu bar does not drop Free listening.
    private var latchedFocus: FocusKind?
    private var latchedFocusPid: pid_t?
    /// Element the latched probe saw; compared every 100 ms while listening.
    private var latchedElement: AXUIElement?
    /// Field the user left with Esc (Q46): no relisten until focus moves off it.
    private var escapedFocus: (pid: pid_t, element: AXUIElement?)?
    /// Element the last full probe saw, so 100 ms waiting ticks can skip re-probing.
    private var lastProbe: (pid: pid_t, element: AXUIElement?)?
    private var latchedFocusAt: Date?
    /// Drop Focus pastes whose listen generation no longer matches (user left the field).
    private var freeInsertGeneration: UInt64 = 0

    /// Hands-free (Q45): Earshot live endpointing, toggled by double-tap and the key.
    private var handsFreeActive = false
    private var streamInFlight = 0
    private var streamReleasePending = false
    /// Physical PTT chord down; used to start a hold that arrived during finishing.
    private var pttHeld = false
    /// Serial ASR for hands-free / Focus closed segments (take_stream_segment is blocking).
    private let streamRecognizeQueue = DispatchQueue(label: "app.typwrtr.ptt-stream")
    /// One drain worker at a time so sticky SegmentEnded cannot inflate in-flight.
    private var streamDrainScheduled = false
    private var freeDrainScheduled = false
    /// Close arrived while a drain worker was finishing — take again after it lands.
    private var streamDrainNeeded = false
    private var freeDrainNeeded = false

    init(menu: MenuBarModel) {
        self.menu = menu
    }

    func start() {
        loadSession(AppLanguage.current)

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
            self?.pttKeyDown()
        }
        hotkey.onPttUp = { [weak self] in
            self?.pttKeyUp()
        }
        // Q45: switching apps ends hands-free and drops the open segment (inserting it
        // would pull the user back to the app they left).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.handsFreeActive,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid(),
                  app.processIdentifier != self.insertTarget?.processIdentifier
            else { return }
            self.cancelHandsFree(reason: "left-app")
        }
        hotkey.onEscape = { [weak self] in
            self?.escapePressed()
        }
        hotkey.shouldSwallowEscape = { [weak self] in
            guard let self else { return false }
            let reason: String
            if self.pendingTap != nil {
                reason = "pending-tap"
            } else if self.handsFreeCancelable {
                reason = "hands-free"
            } else if self.batchPttCancelable {
                reason = "ptt"
            } else if self.focusEscapable {
                reason = "focus-listening"
            } else {
                CaptureLog.note("esc passed reason=\(self.escapedFocus != nil ? "focus-held" : "other")")
                return false
            }
            CaptureLog.note("esc swallowed reason=\(reason)")
            return true
        }
        hotkey.onMouseDown = { [weak self] in
            self?.clearEscapeHoldOnClick()
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
        SetupDialog.onDictionaryChanged = { [weak self] in
            self?.applyLanguage(AppLanguage.current)
        }
        SetupDialog.onPttHotkeyChanged = { [weak self] hotkey in
            self?.applyPttHotkey(hotkey)
        }
        SetupDialog.onFreeArmChanged = { [weak self] armed in
            self?.setFreeArmed(armed)
        }
        menu.setPttHotkey(PttHotkey.current)
        hotkey.start()
        focusWatcher.onFocusPossiblyChanged = { [weak self] cheap in
            self?.pollFreeFocus(cheap: cheap)
        }
        setFreeArmed(MenuBarModel.freeArmedPreference)
        NSLog("Typwrtr: PTT coordinator started")
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
              !handsFreeActive,
              !freeMicOpen
        else {
            menu.showError("Finish the current dictation before changing language.")
            return
        }
        stopAudioPump()
        AppLanguage.current = language
        loadSession(language)
    }

    /// Build the ASR session off the main thread; a cold FluidAudio load takes ~60 s.
    /// The newest request wins: an older load that lands late is dropped.
    private func loadSession(_ language: AppLanguage) {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration
        sessionLoading = true
        menu.setLanguage(language)
        menu.setBackendDebug("Backend: loading…")
        refreshStatus()
        startLoadHeartbeat()
        let started = Date()
        sessionLoadQueue.async { [weak self] in
            let made = SessionFactory.makeSession(language: language)
            DispatchQueue.main.async {
                guard let self, generation == self.sessionLoadGeneration else { return }
                self.loadHeartbeat?.invalidate()
                self.loadHeartbeat = nil
                CaptureLog.note(String(
                    format: "asr load done language=%@ ms=%.0f heartbeats=%d",
                    language.rawValue,
                    Date().timeIntervalSince(started) * 1000,
                    self.loadHeartbeatTicks
                ))
                self.session = made.0
                self.backend = made.1
                self.sessionLoading = false
                self.applyBackendToMenu()
                self.menu.setCanUndo(self.session.lastText() != nil)
                self.menu.refreshSetupStatus()
                self.refreshStatus()
                NSLog("Typwrtr: language=%@ backend=%@", language.displayName, made.1.debugLabel)
                // Full probe: cheap ticks would see unchanged focus and leave the field closed.
                self.lastProbe = nil
                self.pollFreeFocus()
            }
        }
    }

    private func startLoadHeartbeat() {
        loadHeartbeat?.invalidate()
        loadHeartbeatTicks = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.loadHeartbeatTicks += 1
            CaptureLog.note("asr load heartbeat n=\(self.loadHeartbeatTicks)")
        }
        // .common: keeps ticking while the menu is open (event tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        loadHeartbeat = timer
    }

    private func applyBackendToMenu() {
        menu.setLanguage(AppLanguage.current)
        menu.setBackendDebug(backend.debugLabel)
    }

    private static let preparingMessage = "Preparing speech model…"

    private func syncFreeArmFromDefaults() {
        setFreeArmed(MenuBarModel.freeArmedPreference)
    }

    private func setFreeArmed(_ armed: Bool) {
        MenuBarModel.freeArmedPreference = armed
        if armed {
            freeController.arm()
            NSLog("Typwrtr: Free armed")
        } else {
            freeController.disarm()
            escapedFocus = nil
            stopFreeMic(abandon: true, reason: "disarmed")
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

    /// `cheap`: a 100 ms watcher tick. While waiting for a field it skips the full
    /// probe when the focused element is the one last probed (pip spam, cost).
    private func pollFreeFocus(cheap: Bool = false) {
        if freeSuspendedByPtt || phase != .idle {
            return
        }

        guard freeController.isArmed() else {
            menu.setFreeAvailability(.disarmed)
            menu.setFreeListeningIcon(false)
            return
        }

        if !AXIsProcessTrusted() {
            menu.setFreeAvailability(.unavailableExplained)
            menu.setFocusDictationStatus("Needs Accessibility")
            if freeMicOpen {
                stopFreeMic(abandon: true, reason: "ax-untrusted")
            }
            return
        }

        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if escapeStillHolds(frontPid: frontPid) {
            menu.setFreeListeningIcon(false)
            return
        }

        // Already listening in the same app: skip the full probe (pip spam) unless the
        // focused element changed. Without this check, leaving the field for another
        // part of the same app kept the mic and bar open (dogfood 2026-10-18).
        if freeMicOpen,
           latchedFocus == .textField,
           let frontPid,
           frontPid == latchedFocusPid
        {
            if !focusMovedWithinApp(pid: frontPid) {
                menu.setFreeListeningIcon(true)
                menu.setFreeAvailability(.listening)
                return
            }
            CaptureLog.note("focus moved within app; re-probing")
        }

        if cheap, !freeMicOpen, let frontPid, waitingFocusUnchanged(pid: frontPid) {
            return
        }

        // Left the target app while listening — stop mic without a full probe first.
        if freeMicOpen, frontPid != latchedFocusPid {
            stopFreeMic(abandon: true, reason: "left-app")
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
            if freeMicOpen {
                menu.setFreeListeningIcon(true)
            }
        } else if freeMicOpen {
            stopFreeMic(abandon: true, reason: "not-text-field")
            menu.setFreeListeningIcon(false)
        } else {
            if phase == .idle {
                menu.setFreeListeningIcon(false)
            }
        }
    }

    /// Q46, Focus Dictation: Esc is swallowed while the mic is open, ends the listen
    /// and hides the bar. Focus stays put, and the next Esc reaches the app. The same
    /// field does not reopen until a click, a tap of the key, or focus moving elsewhere.
    private var focusEscapable: Bool {
        freeMicOpen && phase == .idle && latchedFocusPid != nil
    }

    private func escapePressed() {
        if pendingTap != nil {
            cancelPendingTap()
            return
        }
        if handsFreeCancelable {
            cancelHandsFree(reason: "esc")
            return
        }
        if batchPttCancelable {
            cancelBatchPtt()
            return
        }
        guard focusEscapable, let pid = latchedFocusPid else { return }
        escapedFocus = (pid, latchedElement)
        stopFreeMic(abandon: true, reason: "esc")
        menu.setFreeListeningIcon(false)
    }

    /// A click after Esc is intent: back into the same field, or into another one.
    /// Clear the hold; the next 100 ms tick probes and relistens if it is a field.
    private func clearEscapeHoldOnClick() {
        guard escapedFocus != nil else { return }
        clearEscapeHold(reason: "click")
    }

    private func clearEscapeHold(reason: String) {
        escapedFocus = nil
        lastProbe = nil
        CaptureLog.note("focus esc hold cleared (\(reason))")
    }

    /// True until focus actually leaves text fields after Esc. Element identity alone
    /// cannot tell: Electron (Claude) hands out a new element for the same composer,
    /// which cleared the hold the instant Esc was pressed (dogfood 2026-10-18). So a
    /// changed element is classified, and only a non-text focus, an app switch, or
    /// disarming clears it. An unreadable element counts as unchanged.
    /// Keyboard moves (Tab into another field) stay held; a click clears it.
    private func escapeStillHolds(frontPid: pid_t?) -> Bool {
        guard let escaped = escapedFocus else { return false }
        if let frontPid, frontPid == escaped.pid {
            guard let element = escaped.element,
                  let current = FocusProbe.focusedElement(pid: frontPid)
            else { return true }
            if CFEqual(element, current) { return true }
            if FocusProbe.probe().kind == .textField {
                escapedFocus = (frontPid, current)
                return true
            }
        }
        escapedFocus = nil
        CaptureLog.note("focus esc hold cleared")
        return false
    }

    /// Waiting for a field: is focus still on the element the last full probe saw?
    /// An unreadable element counts as unchanged; the ~3 s full probe catches up.
    private func waitingFocusUnchanged(pid: pid_t) -> Bool {
        guard let last = lastProbe, last.pid == pid else { return false }
        guard let current = FocusProbe.focusedElement(pid: pid) else { return true }
        guard let element = last.element else { return false }
        return CFEqual(element, current)
    }

    /// Cheap check: has the focused element changed since the probe that opened the
    /// mic? An unreadable element counts as unchanged, so a flaky AX read cannot
    /// cut a phrase off.
    private func focusMovedWithinApp(pid: pid_t) -> Bool {
        guard let latched = latchedElement else { return false }
        let started = DispatchTime.now().uptimeNanoseconds
        let current = FocusProbe.focusedElement(pid: pid)
        noteFocusCheckCost(nanos: DispatchTime.now().uptimeNanoseconds - started)
        guard let current else { return false }
        return !CFEqual(latched, current)
    }

    /// Cost of the 100 ms focus check, logged every 50 calls (~5 s): max and mean.
    private var focusCheckNanos: [UInt64] = []
    private func noteFocusCheckCost(nanos: UInt64) {
        focusCheckNanos.append(nanos)
        guard focusCheckNanos.count >= 50 else { return }
        let maxMs = Double(focusCheckNanos.max() ?? 0) / 1e6
        let meanMs = Double(focusCheckNanos.reduce(0, +)) / Double(focusCheckNanos.count) / 1e6
        CaptureLog.note(String(format: "focus check calls=%d max_ms=%.2f mean_ms=%.2f",
                               focusCheckNanos.count, maxMs, meanMs))
        focusCheckNanos.removeAll(keepingCapacity: true)
    }

    /// Prefer live AX probe; if the menu-bar agent briefly steals key window, keep
    /// the last text-field focus for the same frontmost app (~2s).
    private func resolveFocus() -> FocusKind? {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let probed = FocusProbe.probe()
        if let frontPid {
            lastProbe = (frontPid, probed.element)
        }
        if let live = probed.kind {
            latchedFocus = live
            latchedElement = probed.element
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
        guard !sessionLoading else {
            menu.setFocusDictationStatus(Self.preparingMessage)
            return
        }
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
            showListeningIndicator()
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

    private func stopFreeMic(abandon: Bool, reason: String) {
        guard freeMicOpen else { return }
        CaptureLog.note("focus listen stopped reason=\(reason) abandon=\(abandon ? 1 : 0)")
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
        listeningIndicator.hide()
        NSLog("Typwrtr: Free mic closed (abandon=%d)", abandon ? 1 : 0)
    }

    /// Level bar on the dictated-into app's screen while the mic is open (Q40).
    private func showListeningIndicator() {
        listeningIndicator.show(appPid: insertTarget?.processIdentifier ?? 0) { [weak self] in
            self?.mic.recentRms ?? 0
        }
    }

    private func startAudioPump(_ kind: AudioPumpKind) {
        stopAudioPump()
        // The old pump has drained (stopAudioPump syncs the queue), so this is race-free.
        focusProbe.removeAll(keepingCapacity: true)
        focusProbeDone = kind == .off
        handsFreeSpeaking = false
        handsFreeLastVoiceAt = Date()
        handsFreeIdleFired = false
        focusProbeStartedAt = Date()
        focusStatsSamples.removeAll(keepingCapacity: true)
        focusStatsAt = Date()
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
            processHandsFreeAudio()
        case .focus:
            processFreeAudio()
        }
    }

    private func processFreeAudio() {
        let chunk = mic.drain()
        probeFocusInput(chunk)
        defer { logFocusStats(chunk) }
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

    /// Q43: a Focus listen whose first ~2 s carry no signal ends and disarms, so the
    /// next focus does not reopen a dead mic. Runs on the audio pump queue.
    private func probeFocusInput(_ chunk: [Float]) {
        guard !focusProbeDone else { return }
        focusProbe.append(contentsOf: chunk)
        // The pump ticks even when the device delivers nothing, so the clock also
        // ends the probe: a stalled mic judges on what little arrived (empty = dead).
        let full = focusProbe.count >= Int(deadInputProbeSamples())
        guard full || Date().timeIntervalSince(focusProbeStartedAt) >= 2.5 else { return }
        focusProbeDone = true
        let dead = isDeadInput(samples: focusProbe)
        CaptureLog.note(String(
            format: "input probe %.1f dBFS over %d samples dead=%d",
            inputLevelDbfs(samples: focusProbe), focusProbe.count, dead ? 1 : 0
        ))
        focusProbe.removeAll()
        guard dead else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.handsFreeActive {
                self.cancelHandsFree(reason: "dead-mic")
                self.listeningIndicator.flash(Self.noInputMessage)
                return
            }
            guard self.freeMicOpen else { return }
            self.stopFreeMic(abandon: true, reason: "dead-mic")
            self.setFreeArmed(false)
            self.listeningIndicator.flash(Self.noInputMessage)
        }
    }

    private static let noInputMessage = "No microphone input"

    /// Every ~2 s while Focus listens: input level and how many frames scored as
    /// speech. A run of `above>0` windows after the speaker stopped means the room
    /// keeps resetting the 1.5 s silence run; no lines at all means the pump stopped.
    private func logFocusStats(_ chunk: [Float]) {
        focusStatsSamples.append(contentsOf: chunk)
        guard Date().timeIntervalSince(focusStatsAt) >= 2 else { return }
        focusStatsAt = Date()
        let stats = session.takeStreamVadStats()
        CaptureLog.note(String(
            format: "focus vad frames=%d above=%d peak=%.2f speaking=%d input=%.1f dBFS samples=%d resume=1:%d 2:%d 3-7:%d 8+:%d",
            stats?.frames ?? 0, stats?.aboveThreshold ?? 0, stats?.peak ?? 0,
            (stats?.speaking ?? false) ? 1 : 0,
            inputLevelDbfs(samples: focusStatsSamples), focusStatsSamples.count,
            stats?.resumeRun1 ?? 0, stats?.resumeRun2 ?? 0,
            stats?.resumeRun3To7 ?? 0, stats?.resumeRun8Plus ?? 0
        ))
        focusStatsSamples.removeAll(keepingCapacity: true)
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

        let segmentTrace = LatencyLog.isEnabled
            ? LatencyLog.Trace(path: "free", trigger: "earshot-silence")
            : nil

        streamRecognizeQueue.async { [weak self] in
            guard let self else { return }
            var results: [(text: String, samples: Int, trace: LatencyLog.Trace?)] = []
            var firstSegment = true
            while true {
                let trace: LatencyLog.Trace?
                if firstSegment {
                    trace = segmentTrace
                    firstSegment = false
                } else {
                    trace = LatencyLog.isEnabled
                        ? LatencyLog.Trace(path: "free", trigger: "earshot-silence")
                        : nil
                }
                trace?.markAsrStart()
                do {
                    let text = try self.session.takeStreamSegment()
                    trace?.markAsrEnd()
                    let metrics = self.session.lastCaptureMetrics()
                    CaptureLog.record(metrics, path: "free")
                    let samples = Int(metrics?.pushedSamples ?? 0)
                    results.append((text, samples, trace))
                } catch {
                    trace?.finishWithoutInsert(outcome: "asr-empty")
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
                            target: target,
                            trace: item.trace
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
        target: NSRunningApplication?,
        trace: LatencyLog.Trace?
    ) {
        freeInFlight = max(0, freeInFlight - 1)
        refreshStatus()
        menu.setLastCapture(samples: samples, sampleRate: 16_000)
        if insertGen != freeInsertGeneration {
            NSLog("Typwrtr: dropped free insert (left field)")
            CaptureLog.insert(path: "free", outcome: "dropped-left-field", chars: text.count)
            trace?.finishWithoutInsert(outcome: "dropped-left-field", chars: text.count)
            if shouldAcceptStreamResult(text: text) {
                menu.setLastText(text)
            }
        } else {
            insertTarget = target
            insertStreamResult(text: text, path: "free", trace: trace)
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
        guard !sessionLoading, phase == .idle, freeInFlight == 0, streamInFlight == 0 else { return }
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
        if freeInFlight > 0 || freeMicOpen || handsFreeActive || streamInFlight > 0 {
            let alert = NSAlert()
            alert.messageText = "Discard and quit?"
            alert.informativeText = "Typwrtr is still listening or processing."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        switch session?.status() ?? .idle {
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

    /// Set when a key-down started or stopped hands-free, so its key-up is ignored.
    private var consumeKeyUp = false
    /// A short first tap waiting up to the double-tap window (Q44). Its capture is
    /// processed as batch PTT if no second press comes.
    private var pendingTap: (releasedAt: Date, work: DispatchWorkItem)?

    /// The PTT chord is physically down (between key-down and key-up callbacks).
    private var chordHeld = false

    /// Focus Dictation at the key-down that started this batch capture (Q46). PTT
    /// closes the Focus mic at once, so a lone tap decides from this 400 ms later.
    private var focusAtPress: (listening: Bool, held: Bool, pid: pid_t?, element: AXUIElement?) =
        (false, false, nil, nil)

    /// A press cancelled with Esc stops Focus Dictation too: hold it as Esc would,
    /// or the next 100 ms tick reopens the mic the user just tried to silence.
    private func holdFocusAfterCancelledPress() {
        guard focusAtPress.listening || focusAtPress.held, let pid = focusAtPress.pid else { return }
        escapedFocus = (pid, focusAtPress.element)
    }

    private func pttKeyDown() {
        chordHeld = true
        if handsFreeActive {
            consumeKeyUp = true
            CaptureLog.note("hands-free stopped (key)")
            endHandsFree()
            return
        }
        if let tap = pendingTap,
           isDoubleTap(gapMs: UInt64(max(0, Date().timeIntervalSince(tap.releasedAt)) * 1000))
        {
            tap.work.cancel()
            pendingTap = nil
            try? session.cancel()
            phase = .idle
            consumeKeyUp = true
            beginHandsFree()
            return
        }
        beginPtt()
    }

    private func pttKeyUp() {
        chordHeld = false
        if consumeKeyUp {
            consumeKeyUp = false
            pttHeld = false
            return
        }
        endPtt()
    }

    private func cancelPendingTap() {
        pendingTap?.work.cancel()
        pendingTap = nil
        CaptureLog.note("ptt cancelled (esc) phase=pending-tap")
        try? session.cancel()
        holdFocusAfterCancelledPress()
        phase = .idle
        freeSuspendedByPtt = false
        refreshStatus()
        pollFreeFocus()
    }

    private func beginPtt() {
        guard !sessionLoading else {
            listeningIndicator.flash(Self.preparingMessage)
            return
        }
        pttHeld = true
        if handsFreeActive || phase == .recording || pendingTap != nil {
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

        focusAtPress = (
            freeMicOpen && phase == .idle,
            escapedFocus != nil,
            escapedFocus?.pid ?? latchedFocusPid,
            escapedFocus?.element ?? latchedElement
        )
        let pressFocus = focusAtPress.listening ? "listening" : focusAtPress.held ? "held" : "none"
        CaptureLog.note("ptt press focus=\(pressFocus)")
        // Q13 3b: temporary Free suspend for this PTT capture (do not disarm).
        freeSuspendedByPtt = true
        stopFreeMic(abandon: true, reason: "ptt")
        session.finishStreamListen()

        beginBatchPtt()
    }

    /// Q46: Esc cancels batch PTT while it records or processes, and is swallowed so
    /// the app under it never sees that Esc.
    private var batchPttCancelable: Bool {
        !handsFreeActive && (phase == .recording || phase == .finishing) && !batchPttDiscarded
    }

    /// Set while a cancelled capture is still being processed; its result is dropped.
    private var batchPttDiscarded = false

    private func cancelBatchPtt() {
        CaptureLog.note("ptt cancelled (esc) phase=\(phase == .recording ? "recording" : "processing")")
        listeningIndicator.hide()
        holdFocusAfterCancelledPress()
        if phase == .recording {
            _ = mic.stop()
            try? session.cancel()
            phase = .idle
            freeSuspendedByPtt = false
            refreshStatus()
            return
        }
        // Processing runs off the main queue and owns the session until it returns;
        // finishBatchPtt drops the result.
        batchPttDiscarded = true
    }

    private func beginBatchPtt() {
        phase = .recording
        handsFreeActive = false
        insertTarget = NSWorkspace.shared.frontmostApplication
        menu.setCanUndo(false)
        menu.setStatus(.recording)
        pttStartedAt = Date()
        do {
            try session.startPtt()
            try mic.start()
            showListeningIndicator()
            refreshStatus()
        } catch {
            phase = .idle
            freeSuspendedByPtt = false
            _ = mic.stop()
            listeningIndicator.hide()
            try? session.cancel()
            refreshStatus()
            menu.showError("PTT start failed: \(error.localizedDescription)")
            pollFreeFocus()
        }
    }

    /// Q45: double-tap opens a listen with Focus Dictation's 1.5 s segment end and
    /// no focus gate. Inserts at each pause; ends on the key, Esc, an app switch,
    /// 20 s of silence, or a dead mic.
    private func beginHandsFree() {
        guard micAuthorized || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            menu.showError("Microphone permission is not granted.")
            return
        }
        micAuthorized = true
        // One stream slot: Focus Dictation steps aside, as for PTT (Q13).
        freeSuspendedByPtt = true
        stopFreeMic(abandon: true, reason: "hands-free")
        session.finishStreamListen()
        phase = .recording
        handsFreeActive = true
        streamReleasePending = false
        streamDrainScheduled = false
        insertTarget = NSWorkspace.shared.frontmostApplication
        menu.setCanUndo(false)
        menu.setStatus(.recording)
        do {
            try session.startFocusListen()
            try mic.start()
            showListeningIndicator()
            startAudioPump(.stream)
            refreshStatus()
            CaptureLog.note("hands-free started")
        } catch {
            phase = .idle
            handsFreeActive = false
            freeSuspendedByPtt = false
            session.finishStreamListen()
            _ = mic.stop()
            listeningIndicator.hide()
            refreshStatus()
            menu.showError("PTT start failed: \(error.localizedDescription)")
            pollFreeFocus()
        }
    }

    private func endPtt() {
        pttHeld = false
        guard phase == .recording else { return }
        let held = Date().timeIntervalSince(pttStartedAt)
        let captured = mic.stop()
        // Q44: a short press may be the first tap of a double-tap. Hold its capture
        // for the window; if no second press came it toggles Focus Dictation (Q46)
        // or, with nothing to toggle, is processed as batch PTT.
        if isPossibleFirstTap(heldMs: UInt64(max(0, held) * 1000)) {
            phase = .finishing
            listeningIndicator.hide()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingTap != nil else { return }
                self.pendingTap = nil
                self.endSingleTap(captured: captured, held: held)
            }
            pendingTap = (Date(), work)
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindowSeconds(), execute: work)
            return
        }
        endBatchPtt(captured: captured, held: held)
    }

    /// Q46: a lone tap stops or resumes Focus Dictation. Its own audio is discarded.
    private func endSingleTap(captured: (samples: [Float], sampleRate: UInt32), held: TimeInterval) {
        let action = singleTapAction(
            focusListening: focusAtPress.listening,
            focusHeld: focusAtPress.held
        )
        switch action {
        case .batchPtt:
            CaptureLog.note("single tap: ptt (not focus)")
            endBatchPtt(captured: captured, held: held)
            return
        case .stopFocus:
            CaptureLog.note("single tap: focus toggle stop")
            holdFocusAfterCancelledPress()
        case .resumeFocus:
            CaptureLog.note("single tap: focus toggle resume")
            clearEscapeHold(reason: "tap")
        }
        try? session.cancel()
        phase = .idle
        freeSuspendedByPtt = false
        menu.setCanUndo(session.lastText() != nil)
        refreshStatus()
        pollFreeFocus()
    }

    private func endBatchPtt(captured: (samples: [Float], sampleRate: UInt32), held: TimeInterval) {
        phase = .finishing
        // Q43: a hold long enough to say something, with no signal at all.
        let heldLongEnough = held >= 0.5
        let dead = heldLongEnough && isDeadInput(samples: captured.samples)
        CaptureLog.note(String(
            format: "ptt input %.1f dBFS over %d samples dead=%d",
            inputLevelDbfs(samples: captured.samples), captured.samples.count, dead ? 1 : 0
        ))
        if dead {
            NSLog("Typwrtr: PTT saw no microphone input")
            listeningIndicator.flash(Self.noInputMessage)
            phase = .idle
            freeSuspendedByPtt = false
            try? session.cancel()
            refreshStatus()
            pollFreeFocus()
            return
        }
        listeningIndicator.showProcessing()
        menu.setStatus(.processing)
        let trace = LatencyLog.isEnabled
            ? LatencyLog.Trace(path: "ptt", trigger: "release")
            : nil

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
                trace?.markAsrStart()
                let text = try self.session.stopPtt()
                trace?.markAsrEnd()
                CaptureLog.record(self.session.lastCaptureMetrics(), path: "ptt")
                DispatchQueue.main.async {
                    self.finishBatchPtt(text: text, trace: trace)
                }
            } catch {
                trace?.finishWithoutInsert(outcome: "error")
                DispatchQueue.main.async {
                    self.listeningIndicator.hide()
                    self.phase = .idle
                    self.freeSuspendedByPtt = false
                    try? self.session.cancel()
                    self.refreshStatus()
                    // A capture cancelled with Esc fails quietly: the user already gave up on it.
                    if self.batchPttDiscarded {
                        self.batchPttDiscarded = false
                    } else {
                        self.menu.showError("PTT failed: \(error)")
                    }
                    if self.pttHeld {
                        self.beginPtt()
                    } else {
                        self.pollFreeFocus()
                    }
                }
            }
        }
    }

    private func finishBatchPtt(text: String, trace: LatencyLog.Trace?) {
        phase = .idle
        freeSuspendedByPtt = false
        refreshStatus()
        if batchPttDiscarded {
            batchPttDiscarded = false
            // Nothing was inserted, so Undo must have nothing to reverse.
            session.clearBuffer()
            trace?.finishWithoutInsert(outcome: "cancelled")
            if pttHeld { beginPtt() } else { pollFreeFocus() }
            return
        }
        menu.setLastCapture(
            samples: mic.lastSampleCount,
            sampleRate: mic.lastSampleRate
        )
        menu.setLastText(text)
        NSLog("Typwrtr: recognized text (%d chars): %@", text.count, text)
        listeningIndicator.hide()
        restoreInsertTargetFocus()
        trace?.markInsertStart()
        let result = inserter.insert(text, into: insertTarget)
        recordInsert(path: "ptt", result: result, chars: text.count, trace: trace)
        switch result {
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

    /// Hands-free idle tracking (audio pump queue only).
    private var handsFreeSpeaking = false
    private var handsFreeLastVoiceAt = Date.distantPast
    private var handsFreeIdleFired = false

    private func processHandsFreeAudio() {
        let chunk = mic.drain()
        probeFocusInput(chunk)
        defer { checkHandsFreeIdle() }
        do {
            let event = try session.pushStreamPcmF32(samples: chunk, sampleRate: 16_000)
            switch event {
            case .none:
                break
            case .speechStarted:
                handsFreeSpeaking = true
                handsFreeLastVoiceAt = Date()
                CaptureLog.note("hands-free earshot speechStarted")
            case .segmentEnded:
                handsFreeSpeaking = false
                handsFreeLastVoiceAt = Date()
                CaptureLog.endpoint(reason: "earshot-silence", samples: chunk.count)
                DispatchQueue.main.async { [weak self] in
                    self?.enqueueStreamSegment(reason: "earshot-silence")
                }
            }
        } catch {
            CaptureLog.note("hands-free push failed")
        }
    }

    /// Q45: 20 s without speech ends hands-free (threshold in core).
    private func checkHandsFreeIdle() {
        guard !handsFreeSpeaking, !handsFreeIdleFired else { return }
        let idleMs = UInt64(max(0, Date().timeIntervalSince(handsFreeLastVoiceAt)) * 1000)
        guard handsFreeIdleExpired(idleMs: idleMs) else { return }
        handsFreeIdleFired = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handsFreeActive else { return }
            CaptureLog.note("hands-free stopped (idle)")
            self.endHandsFree()
        }
    }

    /// Esc while listening or while the last segment processes (Q46).
    private var handsFreeCancelable: Bool {
        handsFreeActive || (streamReleasePending && phase == .finishing)
    }

    /// Bumped on cancel so segments already being transcribed are dropped, not inserted.
    private var handsFreeGeneration: UInt64 = 0

    /// Esc, an app switch or a dead mic: drop the open segment and anything in
    /// flight. Text already inserted stays (⌃⇧Z removes it).
    private func cancelHandsFree(reason: String) {
        CaptureLog.note("hands-free cancelled reason=\(reason)")
        handsFreeGeneration += 1
        if handsFreeActive {
            stopAudioPump()
            _ = mic.stop()
            handsFreeActive = false
        }
        streamReleasePending = true
        session.finishStreamListen()
        listeningIndicator.hide()
        finishHandsFreeIfIdle()
    }

    private func endHandsFree() {
        stopAudioPump()
        let captured = mic.stop()
        listeningIndicator.showProcessing()
        handsFreeActive = false
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
                CaptureLog.note("hands-free stop: no open utterance")
            }
        } catch {
            CaptureLog.note("hands-free stop failed")
        }
        finishHandsFreeIfIdle()
    }

    private func enqueueStreamSegment(reason: String) {
        if streamDrainScheduled {
            streamDrainNeeded = true
            return
        }
        streamDrainScheduled = true
        streamInFlight += 1
        if !handsFreeActive {
            phase = .finishing
            menu.setStatus(.processing)
        }
        let target = insertTarget ?? NSWorkspace.shared.frontmostApplication
        insertTarget = target
        let generation = handsFreeGeneration

        let segmentTrace = LatencyLog.isEnabled
            ? LatencyLog.Trace(path: "hands-free", trigger: reason)
            : nil

        streamRecognizeQueue.async { [weak self] in
            guard let self else { return }
            var results: [(text: String, samples: Int, trace: LatencyLog.Trace?)] = []
            var firstSegment = true
            while true {
                let trace: LatencyLog.Trace?
                if firstSegment {
                    trace = segmentTrace
                    firstSegment = false
                } else {
                    trace = LatencyLog.isEnabled
                        ? LatencyLog.Trace(path: "hands-free", trigger: reason)
                        : nil
                }
                trace?.markAsrStart()
                do {
                    let text = try self.session.takeStreamSegment()
                    trace?.markAsrEnd()
                    let metrics = self.session.lastCaptureMetrics()
                    CaptureLog.record(metrics, path: "hands-free")
                    let samples = Int(metrics?.pushedSamples ?? 0)
                    results.append((text, samples, trace))
                } catch {
                    trace?.finishWithoutInsert(outcome: "asr-empty")
                    break
                }
            }
            DispatchQueue.main.async {
                self.streamDrainScheduled = false
                if results.isEmpty {
                    self.streamInFlight = max(0, self.streamInFlight - 1)
                    if self.handsFreeActive {
                        self.phase = .recording
                        self.menu.setStatus(.recording)
                    } else {
                        self.finishHandsFreeIfIdle()
                    }
                } else {
                    if results.count > 1 {
                        self.streamInFlight += results.count - 1
                    }
                    for item in results {
                        self.completeStreamSegment(
                            text: item.text,
                            samples: item.samples,
                            generation: generation,
                            trace: item.trace
                        )
                    }
                }
                if self.streamDrainNeeded {
                    self.streamDrainNeeded = false
                    self.enqueueStreamSegment(
                        reason: self.handsFreeActive ? "earshot-silence" : "earshot-release"
                    )
                }
            }
        }
    }

    private func completeStreamSegment(
        text: String,
        samples: Int,
        generation: UInt64,
        trace: LatencyLog.Trace?
    ) {
        streamInFlight = max(0, streamInFlight - 1)
        menu.setLastCapture(samples: samples, sampleRate: 16_000)
        if generation != handsFreeGeneration {
            CaptureLog.insert(path: "hands-free", outcome: "dropped-cancelled", chars: text.count)
            trace?.finishWithoutInsert(outcome: "dropped-cancelled", chars: text.count)
        } else {
            // A segment can land while the user presses the key to stop. Waiting for
            // ⌃⇧ to release timed out to clipboard-only (dogfood 13:47:34), so use the
            // insert path built for a held chord.
            insertStreamResult(
                text: text,
                path: "hands-free",
                policy: chordHeld ? .whileModifiersHeld : .waitForModifiers,
                trace: trace
            )
        }
        if handsFreeActive {
            phase = .recording
            menu.setStatus(.recording)
        } else {
            finishHandsFreeIfIdle()
        }
    }

    /// Shared accept/insert path for Focus Dictation and hands-free.
    private func insertStreamResult(
        text: String,
        path: String,
        policy: ClipboardInserter.Policy = .waitForModifiers,
        trace: LatencyLog.Trace? = nil
    ) {
        guard shouldAcceptStreamResult(text: text) else {
            NSLog("Typwrtr: dropped %@ insert (empty)", path)
            CaptureLog.insert(path: path, outcome: "dropped-empty", chars: 0)
            trace?.finishWithoutInsert(outcome: "dropped-empty")
            return
        }
        menu.setLastText(text)
        NSLog("Typwrtr: %@ segment (%d chars): %@", path, text.count, text)
        restoreInsertTargetFocus()
        trace?.markInsertStart()
        let result = inserter.insert(text, into: insertTarget, policy: policy)
        recordInsert(path: path, result: result, chars: text.count, trace: trace)
        switch result {
        case .emptyText:
            break
        case .pasted:
            menu.setCanUndo(true)
        case .clipboardOnly:
            menu.setCanUndo(true)
            NSLog("Typwrtr: insert clipboard-only (%@) — press ⌘V", path)
            Permissions.registerInAccessibilityList()
        }
    }

    private func recordInsert(
        path: String,
        result: ClipboardInserter.Result,
        chars: Int,
        trace: LatencyLog.Trace?
    ) {
        switch result {
        case .emptyText:
            CaptureLog.insert(path: path, outcome: "empty", chars: 0)
            trace?.finishWithoutInsert(outcome: "empty")
        case .pasted(let via):
            CaptureLog.insert(path: path, outcome: "pasted", chars: chars)
            trace?.finishInsert(method: via.rawValue, outcome: "pasted", chars: chars)
        case .clipboardOnly:
            CaptureLog.insert(path: path, outcome: "clipboard-only", chars: chars)
            trace?.finishInsert(
                method: ClipboardInserter.InsertVia.none.rawValue,
                outcome: "clipboard-only",
                chars: chars
            )
        }
    }

    private func finishHandsFreeIfIdle() {
        guard !handsFreeActive, streamInFlight == 0, streamReleasePending, !streamDrainScheduled else { return }
        streamReleasePending = false
        session.finishStreamListen()
        phase = .idle
        freeSuspendedByPtt = false
        listeningIndicator.hide()
        refreshStatus()
        CaptureLog.note("hands-free idle")
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
        if sessionLoading {
            menu.setPreparing(AppLanguage.current)
        } else {
            menu.setStatus(session.status())
        }
    }
}
