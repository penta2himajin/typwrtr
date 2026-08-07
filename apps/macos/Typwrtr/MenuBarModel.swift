import AppKit
import SwiftUI
import Combine

/// Shared menu-bar state for SwiftUI `MenuBarExtra` (right side of the menu bar).
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()

    @Published var languageTitle = "Language: —"
    @Published var backendDebugTitle = "Backend: —"
    @Published var lastCaptureTitle = "Last capture: —"
    @Published var statusTitle = "Status: idle"
    @Published var extraTitle = "Tw"
    @Published var symbolName = "mic"
    @Published var toolTip = "Typwrtr — idle (hold ⌃⇧D)"
    @Published var hotkeyReady = false
    @Published var hotkeyStatus = "Hotkey: starting…"
    @Published var lastTextTitle = "Last text: —"
    @Published var canUndo = false
    @Published var setupComplete = false

    /// Set by PttCoordinator.
    var onUndoRequested: (() -> Void)?
    var onLanguageSelected: ((AppLanguage) -> Void)?

    func setCanUndo(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.canUndo = enabled
        }
    }

    func clearLastText() {
        DispatchQueue.main.async {
            self.lastTextTitle = "Last text: —"
            self.canUndo = false
        }
    }

    func setLastText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "(empty)" : trimmed
        let short = display.count > 80 ? String(display.prefix(80)) + "…" : display
        DispatchQueue.main.async {
            self.lastTextTitle = "Last text: \(short)"
            self.canUndo = !trimmed.isEmpty
        }
    }

    func setLanguage(_ language: AppLanguage) {
        DispatchQueue.main.async {
            self.languageTitle = "Language: \(language.displayName)"
        }
    }

    func setBackendDebug(_ label: String) {
        DispatchQueue.main.async {
            self.backendDebugTitle = label
        }
    }

    func setStatus(_ status: FfiStatus) {
        let apply = {
            switch status {
            case .idle:
                self.symbolName = "mic"
                self.extraTitle = "Tw"
                self.statusTitle = "Status: idle"
                self.toolTip = "Typwrtr — idle (hold ⌃⇧D)"
            case .recording:
                self.symbolName = "mic.fill"
                self.extraTitle = "●Tw"
                self.statusTitle = "Status: recording"
                self.toolTip = "Typwrtr — recording"
            case .processing:
                self.symbolName = "ellipsis.circle"
                self.extraTitle = "…Tw"
                self.statusTitle = "Status: processing"
                self.toolTip = "Typwrtr — processing"
            case .error:
                self.symbolName = "exclamationmark.triangle.fill"
                self.extraTitle = "!Tw"
                self.statusTitle = "Status: error"
                self.toolTip = "Typwrtr — error"
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setLastCapture(samples: Int, sampleRate: UInt32) {
        let seconds = sampleRate == 0 ? 0 : Double(samples) / Double(sampleRate)
        let title = String(
            format: "Last capture: %d samples (%.2fs @ %u Hz)",
            samples,
            seconds,
            sampleRate
        )
        DispatchQueue.main.async {
            self.lastCaptureTitle = title
        }
    }

    func setHotkeyStatus(_ text: String) {
        DispatchQueue.main.async {
            self.hotkeyStatus = text
            self.hotkeyReady = text.contains("ready")
        }
    }

    func setHotkeyReady(_ ready: Bool) {
        setHotkeyStatus(ready ? "Hotkey: ⌃⇧D ready" : "Hotkey: not armed")
    }

    func showError(_ message: String) {
        setStatus(.error)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Typwrtr"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func refreshSetupStatus() {
        let apply = {
            self.setupComplete = SetupChecker.current().isComplete
            self.setLanguage(AppLanguage.current)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func openSetup(isFirstRun: Bool = false) {
        refreshSetupStatus()
        SetupDialog.present(isFirstRun: isFirstRun)
        refreshSetupStatus()
    }

    func presentSetupIfNeeded() {
        refreshSetupStatus()
        let status = SetupChecker.current()
        guard !status.isComplete, !ModelLocator.setupDismissed else { return }
        openSetup(isFirstRun: true)
    }

    func pickModelFolder() {
        guard ModelLocator.pickParakeetFolder() != nil else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Typwrtr"
            alert.informativeText =
                "Model folder saved. Quit and relaunch Typwrtr so ASR picks up the new path."
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    func copyFetchCommand() {
        let lang = AppLanguage.current
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lang.fetchCommand + "\n", forType: .string)
    }
}
