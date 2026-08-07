import AppKit

/// Clipboard write + synthetic ⌘V (ux-decisions B path). AX insert comes later.
final class ClipboardInserter {
    /// Returns true if pasteboard write + paste synthesis were attempted without throwing.
    @discardableResult
    func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        guard ok else { return false }

        // Give the pasteboard a beat, then paste.
        usleep(30_000)
        synthesizeCommandV()

        // Best-effort restore after a short delay so the target app can read.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
