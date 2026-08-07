import AppKit

final class StatusItemController {
    private var item: NSStatusItem?
    private var quitHandler: (() -> Void)?

    func install(quitHandler: @escaping () -> Void) {
        self.quitHandler = quitHandler
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.title = "Tw"
            button.toolTip = "Typwrtr"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Typwrtr (dogfood)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
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

    func showError(_ message: String) {
        setStatus(.error)
        let alert = NSAlert()
        alert.messageText = "Typwrtr"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quitClicked() {
        quitHandler?()
    }
}
