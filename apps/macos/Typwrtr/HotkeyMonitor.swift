import AppKit
import ApplicationServices
import Carbon
import Carbon.HIToolbox
import CoreGraphics

/// Hold-to-talk for the selected ``PttHotkey`` preset (default ⌃⇧D).
///
/// Order: CGEvent tap (best, swallows) → Carbon hotkey (reliable press/release) → NSEvent monitors.
final class HotkeyMonitor {
    var onPttDown: (() -> Void)?
    var onPttUp: (() -> Void)?
    var onUndo: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var carbonHandler: EventHandlerRef?
    private var carbonPttHotKey: EventHotKeyRef?
    private var carbonUndoHotKey: EventHotKeyRef?
    private var pttDown = false
    private var didPrompt = false
    private var preset: PttHotkey = .current

    private let hotKeySignature: OSType = 0x5457_5254 // 'TWRT'
    private let pttHotKeyID: UInt32 = 1
    private let undoHotKeyID: UInt32 = 2

    /// True while the CGEvent tap is swallowing PTT (synthetic modifier-ups are safe).
    private(set) static var eventTapArmed = false

    func start() {
        preset = .current
        requestPermissions()

        if installTap() {
            Self.eventTapArmed = true
            _ = installCarbonUndoHotKey()
            setReadyStatus(via: "event tap")
            return
        }

        Self.eventTapArmed = false
        if installCarbonHotKeys(includePtt: true) {
            setReadyStatus(via: "Carbon")
            showPermissionHelpIfNeeded()
            return
        }

        NSLog("Typwrtr: Carbon hotkey failed — NSEvent monitors")
        installEventMonitors()
        _ = installCarbonUndoHotKey()
        setReadyStatus(via: "monitor")
        showPermissionHelpIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.retryTap()
        }
    }

    /// Tear down listeners and re-bind to ``PttHotkey.current``.
    func restart() {
        stop()
        start()
    }

    private func stop() {
        if pttDown {
            pttDown = false
            onPttUp?()
        }
        removeEventMonitors()
        uninstallCarbonHotKeys()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        Self.eventTapArmed = false
    }

    private func setReadyStatus(via path: String) {
        let symbol = preset.displaySymbol
        MenuBarModel.shared.setHotkeyStatus("Hotkey: \(symbol) ready (\(path)) · Undo ⌃⇧Z")
    }

    private func retryTap() {
        requestPermissions()
        if installTap() {
            removeEventMonitors()
            // Keep undo Carbon; drop PTT Carbon if present to avoid double PTT.
            if let carbonPttHotKey {
                UnregisterEventHotKey(carbonPttHotKey)
                self.carbonPttHotKey = nil
            }
            _ = installCarbonUndoHotKey()
            Self.eventTapArmed = true
            setReadyStatus(via: "event tap")
        }
    }

    /// System prompts only for permissions that are not yet granted.
    private func requestPermissions() {
        // Always (re)register so ad-hoc rebuilds reappear in Privacy panes.
        Permissions.promptAccessibilityIfNeeded()
        Permissions.registerInInputMonitoringList()
        Permissions.registerPostEventIfNeeded()
    }

    /// Custom alert only when something is still missing after system prompts.
    private func showPermissionHelpIfNeeded() {
        guard !didPrompt else { return }

        let listenOK = CGPreflightListenEventAccess()
        let postOK = CGPreflightPostEventAccess()
        let axOK = AXIsProcessTrusted()

        var missing: [String] = []
        if !listenOK { missing.append("Input Monitoring") }
        if !axOK { missing.append("Accessibility") }
        if !postOK { missing.append("Post Event (paste)") }
        guard !missing.isEmpty else { return }

        didPrompt = true
        let names = missing.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Typwrtr needs permission"
        alert.informativeText = """
            Still required: \(names).

            Typwrtr registers with macOS before Settings opens so it can appear in the list. Toggle it ON, then quit and reopen Typwrtr.
            """
        alert.alertStyle = .informational
        let needListen = !listenOK || !postOK
        if needListen {
            alert.addButton(withTitle: "Open Input Monitoring")
        }
        if !axOK {
            alert.addButton(withTitle: "Open Accessibility")
        }
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if needListen {
                Permissions.openInputMonitoringSettings()
            } else {
                Permissions.openAccessibilitySettings()
            }
        case .alertSecondButtonReturn where needListen && !axOK:
            Permissions.openAccessibilitySettings()
        default:
            break
        }
    }

    // MARK: - CGEvent tap

    @discardableResult
    private func installTap() -> Bool {
        if tap != nil { return true }

        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleTap(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - Carbon hotkey (press + release)

    @discardableResult
    private func installCarbonUndoHotKey() -> Bool {
        installCarbonHotKeys(includePtt: false)
    }

    @discardableResult
    private func installCarbonHotKeys(includePtt: Bool) -> Bool {
        if carbonHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            var eventTypeUp = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
            var eventTypes = [eventType, eventTypeUp]
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let userData else { return noErr }
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                    return monitor.handleCarbonEvent(event)
                },
                2,
                &eventTypes,
                selfPtr,
                &carbonHandler
            )
            guard status == noErr else {
                NSLog("Typwrtr: InstallEventHandler failed (%d)", status)
                return false
            }
        }

        if includePtt, carbonPttHotKey == nil {
            let id = EventHotKeyID(signature: hotKeySignature, id: pttHotKeyID)
            let reg = RegisterEventHotKey(
                preset.keyCode,
                preset.carbonModifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &carbonPttHotKey
            )
            guard reg == noErr else {
                NSLog("Typwrtr: RegisterEventHotKey PTT failed (%d)", reg)
                uninstallCarbonHotKeys()
                return false
            }
        }

        if carbonUndoHotKey == nil {
            let id = EventHotKeyID(signature: hotKeySignature, id: undoHotKeyID)
            let reg = RegisterEventHotKey(
                UInt32(kVK_ANSI_Z),
                UInt32(controlKey | shiftKey),
                id,
                GetApplicationEventTarget(),
                0,
                &carbonUndoHotKey
            )
            guard reg == noErr else {
                NSLog("Typwrtr: RegisterEventHotKey Undo failed (%d)", reg)
                if includePtt {
                    uninstallCarbonHotKeys()
                    return false
                }
                // Undo-only failure is non-fatal when PTT uses the event tap.
                return carbonPttHotKey != nil || !includePtt
            }
        }
        return true
    }

    private func uninstallCarbonHotKeys() {
        if let carbonPttHotKey {
            UnregisterEventHotKey(carbonPttHotKey)
            self.carbonPttHotKey = nil
        }
        if let carbonUndoHotKey {
            UnregisterEventHotKey(carbonUndoHotKey)
            self.carbonUndoHotKey = nil
        }
        if let carbonHandler {
            RemoveEventHandler(carbonHandler)
            self.carbonHandler = nil
        }
    }

    private func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        let kind = GetEventKind(event)
        if err == noErr, hotKeyID.signature == hotKeySignature, hotKeyID.id == undoHotKeyID {
            if kind == UInt32(kEventHotKeyPressed) {
                DispatchQueue.main.async { [weak self] in self?.onUndo?() }
            }
            return noErr
        }

        if kind == UInt32(kEventHotKeyPressed) {
            if !pttDown {
                pttDown = true
                DispatchQueue.main.async { [weak self] in self?.onPttDown?() }
            }
        } else if kind == UInt32(kEventHotKeyReleased) {
            if pttDown {
                pttDown = false
                DispatchQueue.main.async { [weak self] in self?.onPttUp?() }
            }
        }
        return noErr
    }

    // MARK: - NSEvent fallback

    private func installEventMonitors() {
        removeEventMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleNSEvent(event)
            if self?.isPttChord(event) == true { return nil }
            if self?.isUndoChord(event) == true { return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleNSEvent(event)
        }
    }

    private func removeEventMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func isPttChord(_ event: NSEvent) -> Bool {
        chordMods(event) && event.keyCode == UInt16(preset.keyCode)
    }

    private func isUndoChord(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && chordMods(event)
            && event.keyCode == UInt16(kVK_ANSI_Z)
            && !event.isARepeat
    }

    private func chordMods(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.control, .option, .command, .shift])
        return mods.contains(.control)
            && mods.contains(.shift)
            && !mods.contains(.command)
            && !mods.contains(.option)
    }

    private func handleNSEvent(_ event: NSEvent) {
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.control, .option, .command, .shift])
        let controlHeld = mods.contains(.control)
        let shiftHeld = mods.contains(.shift)
        let chordMods = controlHeld && shiftHeld && !mods.contains(.command) && !mods.contains(.option)
        let isPttKey = event.keyCode == UInt16(preset.keyCode)
        let isZ = event.keyCode == UInt16(kVK_ANSI_Z)

        switch event.type {
        case .keyDown where isZ && chordMods && !event.isARepeat:
            onUndo?()
        case .keyDown where isPttKey && chordMods && !event.isARepeat:
            if !pttDown {
                pttDown = true
                onPttDown?()
            }
        case .keyUp where isPttKey && (pttDown || chordMods):
            if pttDown {
                pttDown = false
                onPttUp?()
            }
        case .flagsChanged where pttDown && (!controlHeld || !shiftHeld):
            pttDown = false
            onPttUp?()
        default:
            break
        }
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore our own synthetic paste/undo keystrokes.
        if event.getIntegerValueField(.eventSourceUserData) == ClipboardInserter.pasteEventTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isPttKey = keyCode == Int64(preset.keyCode)
        let isZ = keyCode == Int64(kVK_ANSI_Z)
        let mods = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        let controlHeld = mods.contains(.maskControl)
        let shiftHeld = mods.contains(.maskShift)
        let chordMods = controlHeld && shiftHeld && !mods.contains(.maskCommand)
            && !mods.contains(.maskAlternate)

        switch type {
        case .keyDown where isZ && chordMods:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in self?.onUndo?() }
            }
            return nil
        case .keyDown where isPttKey && chordMods:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat, !pttDown {
                pttDown = true
                DispatchQueue.main.async { [weak self] in self?.onPttDown?() }
            }
            return nil
        case .keyUp where isPttKey && (pttDown || chordMods):
            if pttDown {
                pttDown = false
                DispatchQueue.main.async { [weak self] in self?.onPttUp?() }
            }
            return nil
        case .flagsChanged where pttDown && (!controlHeld || !shiftHeld):
            pttDown = false
            DispatchQueue.main.async { [weak self] in self?.onPttUp?() }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
