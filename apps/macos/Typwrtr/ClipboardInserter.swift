import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin

/// Insert recognized text into the frontmost app.
///
/// Paths (in order):
/// 1. Accessibility `AXSelectedText` (direct, no keystrokes)
/// 2. CGEvent unicode typing (direct keystrokes, no clipboard ⌘V)
/// 3. Clipboard + Maccy-style ⌘V
///
/// Text always remains on the pasteboard as a manual recovery path.
final class ClipboardInserter {
    enum Result {
        case emptyText
        case pasted
        case clipboardOnly
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

    @discardableResult
    func insert(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }

        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(trimmed, forType: .string)

        let ax = AXIsProcessTrusted()
        let post = CGPreflightPostEventAccess()
        let secure = IsSecureEventInputEnabled()
        let front = NSWorkspace.shared.frontmostApplication
        let flagsBefore = CGEventSource.flagsState(.combinedSessionState)
        NSLog(
            "Typwrtr: insert target frontmost=%@ pid=%d ax=%d post=%d secure=%d flags=0x%llx",
            front?.bundleIdentifier ?? "(nil)",
            front?.processIdentifier ?? -1,
            ax ? 1 : 0,
            post ? 1 : 0,
            secure ? 1 : 0,
            flagsBefore.rawValue
        )

        if secure {
            NSLog("Typwrtr: Secure Event Input enabled — clipboard only")
            return .clipboardOnly
        }

        // 1) Direct AX write (native text fields).
        if ax, insertViaAccessibility(trimmed) {
            NSLog("Typwrtr: inserted via AXSelectedText")
            return .pasted
        }

        if !waitForModifiersReleased(timeout: 0.6) {
            NSLog("Typwrtr: modifiers still held — clipboard only")
            return .clipboardOnly
        }

        // 2) Direct unicode typing (no ⌘V).
        if typeViaUnicode(trimmed) {
            NSLog("Typwrtr: typed via CGEvent unicode")
            return .pasted
        }

        // 3) Clipboard + ⌘V (Maccy recipe).
        if synthesizeCommandVMaccy() {
            NSLog("Typwrtr: posted Maccy-style ⌘V")
            return .pasted
        }

        return .clipboardOnly
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

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return false
        }
        let focused = focusedRef as! AXUIElement

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) != .success || !settable.boolValue {
            return false
        }

        return AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    /// Select the trailing UTF-16 span matching `text` and delete it via AX.
    private func undoViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return false
        }
        let focused = focusedRef as! AXUIElement

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

        // Prefer a match ending at the current caret / selection start.
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
            // Fallback: last occurrence in the whole string.
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

    private func undoViaBackspace(utf16Count: Int) -> Bool {
        guard CGPreflightPostEventAccess() || AXIsProcessTrusted() else { return false }
        let n = min(utf16Count, 500)
        guard n > 0 else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyDelete: CGKeyCode = 0x33 // kVK_Delete (backward delete / Backspace)
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
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            ts &+= 1_500_000
            usleep(1_500)
        }
        return true
    }

    /// Type text with `keyboardSetUnicodeString` — no clipboard, no ⌘V.
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
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            offset = end
            baseTs &+= 2_000_000
            usleep(2_000)
        }
        return true
    }

    private func synthesizeCommandVMaccy() -> Bool {
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
        keyVDown.post(tap: .cgSessionEventTap)
        keyVUp.post(tap: .cgSessionEventTap)
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
        keyZDown.post(tap: .cgSessionEventTap)
        keyZUp.post(tap: .cgSessionEventTap)
        return true
    }
}
