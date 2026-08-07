import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Strict AX role probe for Free focus gate (ux-decisions Q4).
///
/// Intentionally **does not** walk the full window tree. Deep AX walks make
/// macOS treat us like a screen reader (focus “pip” sounds) and are unnecessary
/// for Free — we only need the focused element (plus a short parent climb).
///
/// Typwrtr needs **Accessibility** permission, not VoiceOver / Screen Reader.
enum FocusProbe {
    private static var lastFingerprint: String?
    private static let debugURL: URL = {
        let root = URL(
            fileURLWithPath: NSString(string: "~/Library/Application Support/Typwrtr")
                .expandingTildeInPath,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("free-focus-debug.txt")
    }()

    struct ProbeResult {
        var kind: FocusKind?
        var detail: String
    }

    static func current() -> FocusKind? { probe().kind }

    static func probe() -> ProbeResult {
        let trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication
        let frontName = front?.localizedName ?? "(none)"
        let frontPid = front?.processIdentifier ?? 0

        guard trusted else {
            let result = ProbeResult(kind: nil, detail: "ax-untrusted front=\(frontName)")
            writeDebug(result.detail)
            return result
        }

        if let appEl = focusedApplicationElement() {
            if let result = resolve(from: appEl, via: "focusedApp", front: frontName) {
                return result
            }
        }

        if let front, front.processIdentifier != getpid() {
            let appEl = AXUIElementCreateApplication(front.processIdentifier)
            if let result = resolve(from: appEl, via: "frontmost", front: frontName) {
                return result
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        if let el = copyAXElement(systemWide, kAXFocusedUIElementAttribute as String) {
            return finish(classify(el), via: "systemWide", element: el, front: frontName)
        }

        let result = ProbeResult(
            kind: nil,
            detail: "via=none front=\(frontName) pid=\(frontPid) self=\(getpid()) trusted=\(trusted)"
        )
        writeDebug(result.detail)
        logOnce(result.detail, result.detail)
        return result
    }

    /// Focused element only — no window-wide AXChildren walk.
    private static func resolve(
        from appEl: AXUIElement,
        via: String,
        front: String
    ) -> ProbeResult? {
        guard let el = copyAXElement(appEl, kAXFocusedUIElementAttribute as String)
            ?? focusedViaWindow(appEl)
        else {
            return nil
        }
        return finish(classify(el), via: via, element: el, front: front)
    }

    private static func finish(
        _ kind: FocusKind,
        via: String,
        element: AXUIElement,
        front: String
    ) -> ProbeResult {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? "?"
        let desc = stringAttribute(element, kAXRoleDescriptionAttribute as String) ?? ""
        let result = ProbeResult(
            kind: kind,
            detail: "via=\(via) role=\(role) desc=\(desc) kind=\(label(kind)) front=\(front)"
        )
        writeDebug(result.detail)
        logOnce(result.detail, result.detail)
        return result
    }

    private static func focusedApplicationElement() -> AXUIElement? {
        copyAXElement(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as String
        )
    }

    private static func focusedViaWindow(_ appEl: AXUIElement) -> AXUIElement? {
        if let window = copyAXElement(appEl, kAXFocusedWindowAttribute as String)
            ?? copyAXElement(appEl, kAXMainWindowAttribute as String)
        {
            return copyAXElement(window, kAXFocusedUIElementAttribute as String)
        }
        return nil
    }

    private static func copyAXElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    private static func classify(_ element: AXUIElement) -> FocusKind {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String) ?? ""
        if isSecure(role: role, subrole: subrole) { return .secureField }
        if isTextField(role: role, element: element) { return .textField }
        var current = element
        for _ in 0..<8 {
            guard let parent = copyAXElement(current, kAXParentAttribute as String) else { break }
            let parentRole = stringAttribute(parent, kAXRoleAttribute as String) ?? ""
            let parentSub = stringAttribute(parent, kAXSubroleAttribute as String) ?? ""
            if isSecure(role: parentRole, subrole: parentSub) { return .secureField }
            if isTextField(role: parentRole, element: parent) { return .textField }
            current = parent
        }
        return .other
    }

    private static func isSecure(role: String, subrole: String) -> Bool {
        role == "AXSecureTextField" || subrole.localizedCaseInsensitiveContains("Secure")
    }

    /// Native text roles plus Electron/Chromium composers (Cursor, browsers).
    private static func isTextField(role: String, element: AXUIElement) -> Bool {
        switch role {
        case "AXTextField", "AXTextArea":
            return true
        case "AXComboBox":
            return boolAttribute(element, "AXEditable") == true
        default:
            if boolAttribute(element, "AXEditable") == true {
                return true
            }
            let desc = (stringAttribute(element, kAXRoleDescriptionAttribute as String) ?? "")
                .lowercased()
            if desc.contains("text field")
                || desc.contains("text area")
                || desc.contains("textarea")
                || desc.contains("search field")
                || desc.contains("テキスト")
                || desc.contains("編集")
            {
                return true
            }
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &settable
            ) == .success, settable.boolValue {
                return true
            }
            return false
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref
        else { return nil }
        return ref as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref
        else { return nil }
        if let b = ref as? Bool { return b }
        if let n = ref as? NSNumber { return n.boolValue }
        return nil
    }

    private static func label(_ kind: FocusKind) -> String {
        switch kind {
        case .textField: return "textField"
        case .secureField: return "secureField"
        case .other: return "other"
        }
    }

    private static func logOnce(_ fingerprint: String, _ message: String) {
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        NSLog("Typwrtr: %@", message)
    }

    private static func writeDebug(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        try? text.write(to: debugURL, atomically: true, encoding: .utf8)
    }
}
