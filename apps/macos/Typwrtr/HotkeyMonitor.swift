import AppKit
import ApplicationServices
import Carbon
import Carbon.HIToolbox
import CoreGraphics

/// Control + Shift + D hold-to-talk (ux-decisions default hotkey).
///
/// Order: CGEvent tap (best, swallows) → Carbon hotkey (reliable press/release) → NSEvent monitors.
final class HotkeyMonitor {
    var onPttDown: (() -> Void)?
    var onPttUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var carbonHandler: EventHandlerRef?
    private var carbonHotKey: EventHotKeyRef?
    private var dDown = false
    private var didPrompt = false

    private let hotKeySignature: OSType = 0x5457_5254 // 'TWRT'
    private let hotKeyID: UInt32 = 1

    func start() {
        requestPermissions()

        if installTap() {
            MenuBarModel.shared.setHotkeyStatus("Hotkey: ⌃⇧D ready (event tap)")
            return
        }

        if installCarbonHotKey() {
            MenuBarModel.shared.setHotkeyStatus("Hotkey: ⌃⇧D ready (Carbon)")
            showPermissionHelpIfNeeded()
            return
        }

        NSLog("Typwrtr: Carbon hotkey failed — NSEvent monitors")
        installEventMonitors()
        MenuBarModel.shared.setHotkeyStatus("Hotkey: ⌃⇧D ready (monitor)")
        showPermissionHelpIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.retryTap()
        }
    }

    private func retryTap() {
        requestPermissions()
        if installTap() {
            removeEventMonitors()
            uninstallCarbonHotKey()
            MenuBarModel.shared.setHotkeyStatus("Hotkey: ⌃⇧D ready (event tap)")
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
    private func installCarbonHotKey() -> Bool {
        if carbonHotKey != nil { return true }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var eventTypeUp = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
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

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let reg = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(controlKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKey
        )
        guard reg == noErr else {
            NSLog("Typwrtr: RegisterEventHotKey failed (%d)", reg)
            uninstallCarbonHotKey()
            return false
        }
        return true
    }

    private func uninstallCarbonHotKey() {
        if let carbonHotKey {
            UnregisterEventHotKey(carbonHotKey)
            self.carbonHotKey = nil
        }
        if let carbonHandler {
            RemoveEventHandler(carbonHandler)
            self.carbonHandler = nil
        }
    }

    private func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        let kind = GetEventKind(event)
        if kind == UInt32(kEventHotKeyPressed) {
            if !dDown {
                dDown = true
                DispatchQueue.main.async { [weak self] in self?.onPttDown?() }
            }
        } else if kind == UInt32(kEventHotKeyReleased) {
            if dDown {
                dDown = false
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
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.control, .option, .command, .shift])
        return event.keyCode == UInt16(kVK_ANSI_D)
            && mods.contains(.control)
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
        let isD = event.keyCode == UInt16(kVK_ANSI_D)

        switch event.type {
        case .keyDown where isD && chordMods && !event.isARepeat:
            if !dDown {
                dDown = true
                onPttDown?()
            }
        case .keyUp where isD && (dDown || chordMods):
            if dDown {
                dDown = false
                onPttUp?()
            }
        case .flagsChanged where dDown && (!controlHeld || !shiftHeld):
            dDown = false
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

        // Ignore our own synthetic ⌘V so a future configurable hotkey can't loop.
        if event.getIntegerValueField(.eventSourceUserData) == ClipboardInserter.pasteEventTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isD = keyCode == Int64(kVK_ANSI_D)
        let mods = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        let controlHeld = mods.contains(.maskControl)
        let shiftHeld = mods.contains(.maskShift)
        let chordMods = controlHeld && shiftHeld && !mods.contains(.maskCommand)
            && !mods.contains(.maskAlternate)

        switch type {
        case .keyDown where isD && chordMods:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat, !dDown {
                dDown = true
                DispatchQueue.main.async { [weak self] in self?.onPttDown?() }
            }
            return nil
        case .keyUp where isD && (dDown || chordMods):
            if dDown {
                dDown = false
                DispatchQueue.main.async { [weak self] in self?.onPttUp?() }
            }
            return nil
        case .flagsChanged where dDown && (!controlHeld || !shiftHeld):
            dDown = false
            DispatchQueue.main.async { [weak self] in self?.onPttUp?() }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
