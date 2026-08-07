import AppKit

final class StatusItemController {
    private var item: NSStatusItem?
    private var quitHandler: (() -> Void)?
    private var lastCaptureTitle = "Last capture: —"

    func install(quitHandler: @escaping () -> Void) {
        self.quitHandler = quitHandler
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.title = "Tw"
            button.toolTip = "Typwrtr"
        }
        rebuildMenu()
        setStatus(.idle)
    }

    func setStatus(_ status: FfiStatus) {
        guard let button = item?.button else { return }
        switch status {
        case .idle:
            button.title = "Tw"
            button.toolTip = "Typwrtr — idle (hold ⌥V)"
        case .recording:
            button.title = "●Tw"
            button.toolTip = "Typwrtr — recording"
        case .processing:
            button.title = "…Tw"
            button.toolTip = "Typwrtr — processing"
        case .error:
            button.title = "!Tw"
            button.toolTip = "Typwrtr — error"
        }
    }

    func setLastCapture(samples: Int, sampleRate: UInt32) {
        let seconds = sampleRate == 0 ? 0 : Double(samples) / Double(sampleRate)
        lastCaptureTitle = String(format: "Last capture: %d samples (%.2fs @ %u Hz)", samples, seconds, sampleRate)
        rebuildMenu()
    }

    func showError(_ message: String) {
        setStatus(.error)
        let alert = NSAlert()
        alert.messageText = "Typwrtr"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func rebuildMenu() {
        guard let item else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Typwrtr (dogfood)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: lastCaptureTitle, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func quitClicked() {
        quitHandler?()
    }
}
