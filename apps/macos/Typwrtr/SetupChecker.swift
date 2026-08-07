import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

struct SetupStatus {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool
    var languagePackReady: Bool
    var language: AppLanguage
    var launchAtLogin: Bool

    /// Permissions + language pack; launch-at-login is optional.
    var isComplete: Bool {
        microphone && accessibility && inputMonitoring && languagePackReady
    }

    var missingSummary: String {
        var lines: [String] = []
        if !microphone { lines.append("• Microphone — not granted") }
        if !accessibility { lines.append("• Accessibility — not granted") }
        if !inputMonitoring { lines.append("• Input Monitoring — not granted") }
        if !languagePackReady {
            lines.append("• \(language.displayName) language pack — not installed")
        }
        if lines.isEmpty {
            return "All required setup items look ready."
        }
        return lines.joined(separator: "\n")
    }

    var checklistSummary: String {
        """
        Microphone: \(microphone ? "✓" : "✗")
        Accessibility: \(accessibility ? "✓" : "✗")
        Input Monitoring: \(inputMonitoring ? "✓" : "✗")
        Language (\(language.displayName)): \(languagePackReady ? "✓ pack ready" : "✗ pack missing")
        Launch at Login: \(launchAtLogin ? "on" : "off") (optional)
        """
    }
}

enum SetupChecker {
    static func current(language: AppLanguage = .current) -> SetupStatus {
        SetupStatus(
            microphone: microphoneAuthorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(),
            languagePackReady: languagePackReady(for: language),
            language: language,
            launchAtLogin: launchAtLoginEnabled
        )
    }

    static func languagePackReady(for language: AppLanguage) -> Bool {
        ModelLocator.isLanguagePackReady(language)
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func requestMicrophoneIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }
}
