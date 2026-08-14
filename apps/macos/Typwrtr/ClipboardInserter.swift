import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin

/// Insert recognized text into the frontmost (or restored) app.
///
/// Paths (in order):
/// 1. Accessibility `AXSelectedText` (native fields)
/// 2. Clipboard + ⌘V (best for Electron / Cursor / browsers)
/// 3. CGEvent unicode typing
///
/// Text always remains on the pasteboard as a manual recovery path.
final class ClipboardInserter {
    enum Result {
        case emptyText
        case pasted
        case clipboardOnly
    }

    /// How aggressively to insert when the PTT chord may still be held.
    enum Policy {
        /// Batch PTT / Free: wait for Ctrl/Shift/etc. before ⌘V.
        case waitForModifiers
        /// Streaming mid-hold: never bail solely because the hotkey is down.
        case whileModifiersHeld
    }

    /// Marks synthetic paste/type events so our own session tap can ignore them.
    static let pasteEventTag: Int64 = 0x5457_5254 // 'TWRT'

    private static let keyV: CGKeyCode = 0x09
    private static let keyZ: CGKeyCode = 0x06
    private static let leftKeyMarker: CGEventFlags = CGEventFlags(rawValue: 0x000008)
    private static let blockingModifiers: CGEventFlags = [
        .maskControl, .maskShift, .maskAlternate, .maskSecondaryFn,
    ]
    /// Apple documents up to 20 UTF-16 units per keyboardSetUnicodeString call.
    private static let unicodeChunkSize = 16

    private static let electronBundleHints = [
        "cursor", "code", "chrome", "chromium", "edge", "brave", "arc",
        "slack", "discord", "figma", "notion", "spotify", "electron",
    ]

    @discardableResult
    func insert(
        _ text: String,
        into target: NSRunningApplication? = nil,
        policy: Policy = .waitForModifiers
    ) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }

        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(trimmed, forType: .string)

        activateForInsert(target)

        let ax = AXIsProcessTrusted()
        let post = CGPreflightPostEventAccess()
        let secure = IsSecureEventInputEnabled()
        let front = NSWorkspace.shared.frontmostApplication
        let flagsBefore = CGEventSource.flagsState(.combinedSessionState)
        let electron = isElectronLike(front)
        NSLog(
            "Typwrtr: insert target frontmost=%@ pid=%d ax=%d post=%d secure=%d electron=%d flags=0x%llx policy=%@",
            front?.bundleIdentifier ?? "(nil)",
            front?.processIdentifier ?? -1,
            ax ? 1 : 0,
            post ? 1 : 0,
            secure ? 1 : 0,
            electron ? 1 : 0,
            flagsBefore.rawValue,
            policy == .whileModifiersHeld ? "whileHeld" : "waitMods"
        )

        if secure {
            NSLog("Typwrtr: Secure Event Input enabled — clipboard only")
            return .clipboardOnly
        }

        let before = focusedFieldSnapshot()
        if policy == .whileModifiersHeld {
            return insertWhileModifiersHeld(
                trimmed,
                ax: ax,
                preferPaste: electron,
                before: before
            )
        }

        let preferPaste = electron

        // 1) Direct AX write for native fields only. Electron often partially
        // applies AX then we also ⌘V → doubled text.
        if ax, !preferPaste, insertViaAccessibility(trimmed) {
            if verifyWithRetries(before: before, expected: trimmed) {
                NSLog("Typwrtr: inserted via AXSelectedText")
                return .pasted
            }
            NSLog("Typwrtr: AXSelectedText set but field unchanged")
        }

        if !waitForModifiersReleased(timeout: 0.6) {
            NSLog("Typwrtr: modifiers still held — clipboard only")
            return .clipboardOnly
        }

        // 2) Clipboard + ⌘V (single tap — posting HID+session doubles paste).
        if synthesizeCommandV(preferHID: true) {
            if verifyWithRetries(before: before, expected: trimmed) {
                NSLog("Typwrtr: pasted via ⌘V (verified)")
            } else {
                NSLog("Typwrtr: pasted via ⌘V (unverified AX — assuming OK)")
            }
            return .pasted
        }

        // 3) Direct unicode typing (native apps; skip when we already prefer paste).
        if !preferPaste, typeViaUnicode(trimmed) {
            if verifyWithRetries(before: before, expected: trimmed) {
                NSLog("Typwrtr: typed via CGEvent unicode")
                return .pasted
            }
        }

        // 4) System Events keystroke fallback.
        if pasteViaSystemEvents() {
            if verifyWithRetries(before: before, expected: trimmed) {
                NSLog("Typwrtr: pasted via System Events")
                return .pasted
            }
            NSLog("Typwrtr: System Events paste posted — assuming OK")
            return .pasted
        }

        NSLog("Typwrtr: insert failed — clipboard only")
        return .clipboardOnly
    }

    /// Streaming mid-hold: Ctrl/Shift stay down, so the normal wait→clipboard-only
    /// path never pastes. Match the normal path's Electron rule: never AX/unicode
    /// then ⌘V (partial AX + paste doubles text in Cursor / browsers).
    private func insertWhileModifiersHeld(
        _ text: String,
        ax: Bool,
        preferPaste: Bool,
        before: FieldSnapshot
    ) -> Result {
        if ax, !preferPaste, insertViaAccessibility(text) {
            if verifyWithRetries(before: before, expected: text) {
                NSLog("Typwrtr: inserted via AXSelectedText (while held)")
                return .pasted
            }
            NSLog("Typwrtr: AXSelectedText set but field unchanged (while held)")
        }

        let allowUnicode = !preferPaste || !HotkeyMonitor.eventTapArmed
        if allowUnicode, typeViaUnicode(text) {
            if verifyWithRetries(before: before, expected: text) || !canVerifyInsert() {
                NSLog("Typwrtr: typed via CGEvent unicode (while held)")
                return .pasted
            }
        }

        // Tell the event system Ctrl/Shift are up so ⌘V is not delivered as
        // ⌃⇧⌘V. Tagged so HotkeyMonitor's tap ignores them (won't end PTT).
        synthesizeBlockingModifierUps()
        if synthesizeCommandV(preferHID: true) {
            if verifyWithRetries(before: before, expected: text) {
                NSLog("Typwrtr: pasted via ⌘V (while held, verified)")
                return .pasted
            }
            if canVerifyInsert() {
                NSLog("Typwrtr: ⌘V while held did not land — clipboard only")
                return .clipboardOnly
            }
            NSLog("Typwrtr: pasted via ⌘V (while held, unverified)")
            return .pasted
        }

        NSLog("Typwrtr: insert while held failed — clipboard only")
        return .clipboardOnly
    }

    /// Best-effort: tell the event system Ctrl/Shift are up so ⌘V is not
    /// delivered as ⌃⇧⌘V while the physical PTT chord is still held.
    private func synthesizeBlockingModifierUps() {
        // Carbon / NSEvent cannot ignore tagged synthetic ups; they would end PTT.
        guard HotkeyMonitor.eventTapArmed else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let pairs: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, 0x3B), // left control
            (.maskShift, 0x38), // left shift
            (.maskAlternate, 0x3A),
        ]
        var ts = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for (mask, key) in pairs where !flags.intersection(mask).isEmpty {
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { continue }
            up.flags = []
            up.timestamp = ts
            up.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
            up.post(tap: .cghidEventTap)
            ts &+= 200_000
        }
        usleep(5_000)
    }

    private func verifyWithRetries(before: FieldSnapshot, expected: String) -> Bool {
        for _ in 0..<5 {
            if verifiedInsert(before: before, expected: expected) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Best-effort removal of the last inserted `text` (ux-decisions Undo).
    /// Order: AX select+delete → Backspace N → ⌘Z.
    @discardableResult
    func undoLastInsertion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if IsSecureEventInputEnabled() {
            NSLog("Typwrtr: undo blocked — Secure Event Input")
            return false
        }

        _ = waitForModifiersReleased(timeout: 0.4)

        if undoViaAccessibility(trimmed) {
            NSLog("Typwrtr: undo via AXSelectedText")
            return true
        }
        if undoViaBackspace(utf16Count: trimmed.utf16.count) {
            NSLog("Typwrtr: undo via Backspace x%d", trimmed.utf16.count)
            return true
        }
        if synthesizeCommandZMaccy() {
            NSLog("Typwrtr: undo via ⌘Z fallback")
            return true
        }
        return false
    }

    // MARK: - Focus / verify

    private func activateForInsert(_ target: NSRunningApplication?) {
        guard let target, !target.isTerminated, target.processIdentifier != getpid() else {
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != target.processIdentifier {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.12)
        }
        // Nudge the focused window forward via AX when possible.
        let appEl = AXUIElementCreateApplication(target.processIdentifier)
        if let window = copyAXElement(appEl, kAXFocusedWindowAttribute as String)
            ?? copyAXElement(appEl, kAXMainWindowAttribute as String)
        {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    private func isElectronLike(_ app: NSRunningApplication?) -> Bool {
        let id = (app?.bundleIdentifier ?? "").lowercased()
        let name = (app?.localizedName ?? "").lowercased()
        return Self.electronBundleHints.contains { id.contains($0) || name.contains($0) }
    }

    private struct FieldSnapshot {
        var value: String?
        var selected: String?
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if let el = copyAXElement(systemWide, kAXFocusedUIElementAttribute as String) {
            return el
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid()
        else { return nil }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        return copyAXElement(appEl, kAXFocusedUIElementAttribute as String)
            ?? {
                guard let window = copyAXElement(appEl, kAXFocusedWindowAttribute as String)
                    ?? copyAXElement(appEl, kAXMainWindowAttribute as String)
                else { return nil }
                return copyAXElement(window, kAXFocusedUIElementAttribute as String)
            }()
    }

    private func focusedFieldSnapshot() -> FieldSnapshot {
        guard let el = focusedElement() else {
            return FieldSnapshot(value: nil, selected: nil)
        }
        return FieldSnapshot(
            value: stringAttribute(el, kAXValueAttribute as String),
            selected: stringAttribute(el, kAXSelectedTextAttribute as String)
        )
    }

    private func canVerifyInsert() -> Bool {
        focusedFieldSnapshot().value != nil
    }

    private func verifiedInsert(before: FieldSnapshot, expected: String) -> Bool {
        let after = focusedFieldSnapshot()
        if let afterValue = after.value {
            if afterValue.contains(expected) { return true }
            if let beforeValue = before.value, afterValue != beforeValue,
               afterValue.count >= beforeValue.count
            {
                return true
            }
        }
        if let afterSel = after.selected, afterSel.contains(expected) {
            return true
        }
        return false
    }

    @discardableResult
    private func waitForModifiersReleased(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(Self.blockingModifiers).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    // MARK: - AX insert

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focused = focusedElement() else { return false }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue {
            if AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            ) == .success {
                return true
            }
        }

        // Fallback: replace entire AXValue when settable (some Electron fields).
        settable = false
        if AXUIElementIsAttributeSettable(
            focused,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue {
            let existing = stringAttribute(focused, kAXValueAttribute as String) ?? ""
            let combined = existing + text
            return AXUIElementSetAttributeValue(
                focused,
                kAXValueAttribute as CFString,
                combined as CFTypeRef
            ) == .success
        }
        return false
    }

    /// Select the trailing UTF-16 span matching `text` and delete it via AX.
    private func undoViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), let focused = focusedElement() else { return false }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
            let value = valueRef as? String
        else {
            return false
        }

        let needle = Array(text.utf16)
        let hay = Array(value.utf16)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }

        var rangeRef: CFTypeRef?
        var caret = hay.count
        if AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
            let rangeRef
        {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {
                caret = cfRange.location
            }
        }

        let end = min(caret, hay.count)
        guard end >= needle.count else { return false }
        let start = end - needle.count
        if Array(hay[start..<end]) != needle {
            guard let found = value.range(of: text, options: .backwards) else {
                return false
            }
            let ns = NSRange(found, in: value)
            return deleteAXRange(focused, location: ns.location, length: ns.length)
        }
        return deleteAXRange(focused, location: start, length: needle.count)
    }

    private func deleteAXRange(_ focused: AXUIElement, location: Int, length: Int) -> Bool {
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        guard AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        ) == .success else {
            return false
        }
        return AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            "" as CFTypeRef
        ) == .success
    }

    // MARK: - Key synthesis

    private func undoViaBackspace(utf16Count: Int) -> Bool {
        guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else { return false }
        let n = min(utf16Count, 500)
        guard n > 0 else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyDelete: CGKeyCode = 0x33
        var ts = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<n {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyDelete, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyDelete, keyDown: false)
            else {
                return false
            }
            down.flags = []
            up.flags = []
            down.timestamp = ts
            up.timestamp = ts &+ 400_000
            down.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
            postKeyboard(down, up)
            ts &+= 1_500_000
            usleep(1_500)
        }
        return true
    }

    private func typeViaUnicode(_ text: String) -> Bool {
        guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
            NSLog("Typwrtr: skip unicode type — AX/PostEvent not granted")
            return false
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }

        var offset = 0
        var baseTs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while offset < units.count {
            let end = min(offset + Self.unicodeChunkSize, units.count)
            var chunk = Array(units[offset..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }
            down.flags = []
            up.flags = []
            down.timestamp = baseTs
            up.timestamp = baseTs &+ 500_000
            down.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            postKeyboard(down, up)
            offset = end
            baseTs &+= 2_000_000
            usleep(2_000)
        }
        return true
    }

    private func synthesizeCommandV(preferHID: Bool) -> Bool {
        guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
            return false
        }

        let cmdFlag = CGEventFlags.maskCommand.union(Self.leftKeyMarker)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: true),
              let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: false)
        else {
            return false
        }

        let ts = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        keyVDown.timestamp = ts
        keyVUp.timestamp = ts &+ 1_000_000
        keyVDown.flags = cmdFlag
        keyVUp.flags = cmdFlag
        keyVDown.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
        keyVUp.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
        postKeyboard(keyVDown, keyVUp, preferHID: preferHID)
        return true
    }

    private func synthesizeCommandZMaccy() -> Bool {
        guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else {
            return false
        }
        let cmdFlag = CGEventFlags.maskCommand.union(Self.leftKeyMarker)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let keyZDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyZ, keyDown: true),
              let keyZUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyZ, keyDown: false)
        else {
            return false
        }
        let ts = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        keyZDown.timestamp = ts
        keyZUp.timestamp = ts &+ 1_000_000
        keyZDown.flags = cmdFlag
        keyZUp.flags = cmdFlag
        keyZDown.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
        keyZUp.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
        postKeyboard(keyZDown, keyZUp, preferHID: true)
        return true
    }

    private func pasteViaSystemEvents() -> Bool {
        let script = """
            tell application "System Events" to keystroke "v" using command down
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("Typwrtr: System Events paste failed: %@", error)
            return false
        }
        return result != nil
    }

    private func postKeyboard(
        _ down: CGEvent,
        _ up: CGEvent,
        preferHID: Bool = true
    ) {
        // Post to exactly one tap. HID + session both deliver → doubled characters / paste.
        if preferHID {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - AX helpers

    private func copyAXElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref
        else { return nil }
        return ref as? String
    }
}
