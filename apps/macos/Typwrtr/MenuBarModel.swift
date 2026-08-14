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
    @Published var toolTip = "Typwrtr — idle (hold \(PttHotkey.current.displaySymbol))"
    @Published var hotkeyReady = false
    @Published var hotkeyStatus = "Hotkey: starting…"
    /// Menu accelerator + labels follow Settings → Hotkey.
    @Published var pttHotkey = PttHotkey.current
    @Published var lastTextTitle = "Last: —"
    @Published var canUndo = false
    @Published var setupComplete = false
    @Published var freeArmed = false
    /// Secondary line below the Focus Dictation toggle; hidden while off.
    @Published var focusDictationStatus: String?

    private var idleToolTip: String {
        "Typwrtr — idle (hold \(pttHotkey.displaySymbol))"
    }

    static let freeArmedKey = "typwrtr.freeArmed"

    /// Legacy boolean mirror of Focus Dictation; prefer ``DictationMode.current``.
    static var freeArmedPreference: Bool {
        get { DictationMode.current.isFocusDictation }
        set {
            // Only flip Focus Dictation on/off; do not clobber streaming from this setter.
            if newValue {
                DictationMode.current = .focusDictation
            } else if DictationMode.current.isFocusDictation {
                DictationMode.current = .pushToTalk
            }
        }
    }

    /// Set by PttCoordinator.
    var onUndoRequested: (() -> Void)?
    var onLanguageSelected: ((AppLanguage) -> Void)?
    var onFreeArmChanged: ((Bool) -> Void)?
    /// Called when Settings (or menu) changes the listening mode.
    var onDictationModeChanged: ((DictationMode) -> Void)?

    func setFreeArmed(_ armed: Bool) {
        let apply = {
            self.freeArmed = armed
            if !armed {
                self.focusDictationStatus = nil
                // Restore idle chrome if we were showing Free listening.
                if self.statusTitle == "Status: free listening" {
                    self.symbolName = "mic"
                    self.extraTitle = "Tw"
                    self.statusTitle = "Status: idle"
                    self.toolTip = self.idleToolTip
                }
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setPttHotkey(_ hotkey: PttHotkey) {
        let apply = {
            self.pttHotkey = hotkey
            if self.statusTitle == "Status: idle" {
                self.toolTip = self.idleToolTip
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setDictationMode(_ mode: DictationMode) {
        DictationMode.current = mode
        setFreeArmed(mode.isFocusDictation)
        onDictationModeChanged?(mode)
        onFreeArmChanged?(mode.isFocusDictation)
    }

    func setFocusDictationEnabled(_ enabled: Bool) {
        // Menu toggle only arms/disarms Focus Dictation; streaming stays in Settings.
        setDictationMode(enabled ? .focusDictation : .pushToTalk)
    }

    func setFreeAvailability(_ availability: FreeAvailability) {
        let title: String
        switch availability {
        case .disarmed:
            title = ""
        case .listening:
            title = "Listening"
        case .armedWaitingFocus:
            title = "Waiting for text field"
        case .unavailableExplained:
            title = "Unavailable here"
        }
        DispatchQueue.main.async {
            self.focusDictationStatus = title.isEmpty ? nil : title
        }
    }

    /// Override the Focus Dictation status line (mic / Accessibility failures).
    func setFocusDictationStatus(_ title: String) {
        DispatchQueue.main.async {
            self.focusDictationStatus = title
        }
    }

    /// Menu-bar icon while Free mic is open (distinct from PTT recording).
    func setFreeListeningIcon(_ listening: Bool) {
        let apply = {
            // Do not clobber PTT recording / processing chrome.
            if self.statusTitle == "Status: recording" || self.statusTitle == "Status: processing" {
                return
            }
            if listening {
                self.symbolName = "mic.fill"
                self.extraTitle = "○Tw"
                self.statusTitle = "Status: free listening"
                self.toolTip = "Typwrtr — Free listening"
            } else if self.statusTitle == "Status: free listening" {
                self.symbolName = "mic"
                self.extraTitle = "Tw"
                self.statusTitle = "Status: idle"
                self.toolTip = self.idleToolTip
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setCanUndo(_ enabled: Bool) {
        DispatchQueue.main.async {
            self.canUndo = enabled
        }
    }

    func clearLastText() {
        DispatchQueue.main.async {
            self.lastTextTitle = "Last: —"
            self.canUndo = false
        }
    }

    func setLastText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing was said (ux-decisions Q24). Leave the previous preview
            // alone rather than replacing it with an empty placeholder.
            DispatchQueue.main.async {
                self.canUndo = false
            }
            return
        }
        let short = trimmed.count > 36 ? String(trimmed.prefix(36)) + "…" : trimmed
        DispatchQueue.main.async {
            // Keep the menu narrow: short preview only.
            self.lastTextTitle = "Last: \(short)"
            self.canUndo = true
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
                self.toolTip = self.idleToolTip
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
        let symbol = pttHotkey.displaySymbol
        setHotkeyStatus(ready ? "Hotkey: \(symbol) ready" : "Hotkey: not armed")
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
