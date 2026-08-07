import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// TCC registration + System Settings deep links for dogfood permissions.
enum Permissions {
    /// Force the app to appear under System Settings → Input Monitoring.
    ///
    /// `CGRequestListenEventAccess()` alone often no-ops after a TCC reset.
    /// Attempting a listen-only session `CGEventTap` is what actually registers
    /// the bundle in the pane (mousehop / community workaround).
    static func registerInInputMonitoringList() {
        _ = CGRequestListenEventAccess()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        // Probe tap: success → tear down; failure → still registers with TCC.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) {
            // Don't add to run loop — creation alone is enough for TCC.
            CFMachPortInvalidate(probe)
        }
    }

    static func registerPostEventIfNeeded() {
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
    }

    static func promptAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        registerInAccessibilityList()
    }

    /// Force Typwrtr to appear under Privacy & Security → Accessibility.
    /// The prompt option plus a harmless AX query is what TCC uses to list us.
    static func registerInAccessibilityList() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
    }

    static func openInputMonitoringSettings() {
        // Register first so Typwrtr shows up in the list when the pane opens.
        registerInInputMonitoringList()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            openPrivacyURLs([
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_ListenEvent",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            ])
        }
    }

    static func openAccessibilitySettings() {
        registerInAccessibilityList()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            openPrivacyURLs([
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ])
        }
    }

    private static func openPrivacyURLs(_ candidates: [String]) {
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Last resort: Privacy & Security root.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
