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
        registerInInputMonitoringList()
        // Slight delay so TCC has registered us before the pane lists apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openPrivacyPane(query: "Privacy_ListenEvent")
        }
    }

    static func openAccessibilitySettings() {
        registerInAccessibilityList()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openPrivacyPane(query: "Privacy_Accessibility")
        }
    }

    /// System Settings → Privacy & Security → Microphone.
    static func openMicrophoneSettings() {
        openPrivacyPane(query: "Privacy_Microphone")
    }

    /// Open a Privacy & Security sub-pane.
    ///
    /// Prefer lowercase `com.apple.settings.PrivacySecurity.extension` — the
    /// capital-`Settings` form often only opens System Settings root / General
    /// while still returning success from `NSWorkspace.open`.
    private static func openPrivacyPane(query: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(query)",
            "x-apple.systempreferences:com.apple.preference.security?\(query)",
        ]
        for s in candidates {
            guard let url = URL(string: s) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
