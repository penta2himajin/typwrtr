import AppKit

/// Shared Setup UI for first-run and menu → Setup….
enum SetupDialog {
    /// Called when the user changes language inside the dialog (recreate ASR session).
    static var onLanguageChanged: ((AppLanguage) -> Void)?

    private enum Metrics {
        static let width: CGFloat = 236
        static let rowHeight: CGFloat = 26
        static let gap: CGFloat = 5
        static let sectionGap: CGFloat = 10
        static let markWidth: CGFloat = 20
        static let downloadWidth: CGFloat = 78
        static let blockTitleHeight: CGFloat = 16
        static let ruleHeight: CGFloat = 1
        static let afterRule: CGFloat = 8
        static let titleToContent: CGFloat = 6
    }

    /// Present the setup dialog. When `isFirstRun`, Dismiss records `setupDismissed`.
    static func present(isFirstRun: Bool = false) {
        if Thread.isMainThread {
            presentOnMain(isFirstRun: isFirstRun)
        } else {
            DispatchQueue.main.sync {
                presentOnMain(isFirstRun: isFirstRun)
            }
        }
    }

    private static func presentOnMain(isFirstRun: Bool) {
        let status = SetupChecker.current()
        let alert = NSAlert()
        alert.messageText = "Setup"
        alert.informativeText = status.isComplete
            ? "Ready. You can close this."
            : "Open each item that’s missing, then Refresh."
        alert.alertStyle = .informational

        let accessory = AccessoryView(status: status, language: AppLanguage.current) { lang in
            AppLanguage.current = lang
            onLanguageChanged?(lang)
        }
        let height = accessory.fittingHeight
        accessory.frame = NSRect(x: 0, y: 0, width: Metrics.width, height: height)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Refresh")
        if isFirstRun {
            alert.addButton(withTitle: "Later")
        }

        loop: while true {
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                if SetupChecker.current().isComplete {
                    ModelLocator.setupDismissed = true
                }
                break loop
            case .alertSecondButtonReturn:
                presentOnMain(isFirstRun: isFirstRun)
                break loop
            default:
                if isFirstRun {
                    ModelLocator.setupDismissed = true
                }
                break loop
            }
        }
    }

    fileprivate final class AccessoryView: NSView {
        private let languagePopup: NSPopUpButton
        private let downloadButton: NSButton
        private let onLanguage: (AppLanguage) -> Void
        let fittingHeight: CGFloat

        init(
            status: SetupStatus,
            language: AppLanguage,
            onLanguage: @escaping (AppLanguage) -> Void
        ) {
            self.onLanguage = onLanguage
            self.languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            self.downloadButton = NSButton(title: "Download", target: nil, action: nil)

            // Permission header+rule + 3 rows
            // General header+rule + Language title + popup row + login
            let blockHeader =
                Metrics.blockTitleHeight + Metrics.afterRule + Metrics.ruleHeight
            let h =
                blockHeader
                + Metrics.rowHeight * 3
                + Metrics.gap * 2
                + Metrics.sectionGap
                + blockHeader
                + Metrics.blockTitleHeight
                + Metrics.titleToContent
                + Metrics.rowHeight
                + Metrics.gap
                + Metrics.rowHeight
            self.fittingHeight = h
            super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: h))

            var y = h

            addBlockHeader("Permission", y: &y)
            addMarkedButton(
                ok: status.microphone,
                title: "Microphone…",
                y: &y,
                action: #selector(openMic)
            )
            y -= Metrics.gap
            addMarkedButton(
                ok: status.accessibility,
                title: "Accessibility…",
                y: &y,
                action: #selector(openAccessibility)
            )
            y -= Metrics.gap
            addMarkedButton(
                ok: status.inputMonitoring,
                title: "Input Monitoring…",
                y: &y,
                action: #selector(openInputMonitoring)
            )

            y -= Metrics.sectionGap

            addBlockHeader("General", y: &y)

            // Language as in-block title (not a side label).
            y -= Metrics.blockTitleHeight
            let langTitle = NSTextField(labelWithString: "Language")
            langTitle.font = .systemFont(ofSize: 11, weight: .semibold)
            langTitle.textColor = .secondaryLabelColor
            langTitle.frame = NSRect(x: 0, y: y, width: Metrics.width, height: Metrics.blockTitleHeight)
            addSubview(langTitle)

            y -= Metrics.titleToContent
            y -= Metrics.rowHeight
            languagePopup.frame = NSRect(
                x: 0,
                y: y,
                width: Metrics.width - Metrics.downloadWidth - 6,
                height: Metrics.rowHeight
            )
            languagePopup.font = .systemFont(ofSize: 12)
            languagePopup.controlSize = .small
            for lang in AppLanguage.allCases {
                languagePopup.addItem(withTitle: lang.displayName)
                languagePopup.lastItem?.representedObject = lang.rawValue
            }
            languagePopup.selectItem(withTitle: language.displayName)
            languagePopup.target = self
            languagePopup.action = #selector(languageChanged(_:))
            addSubview(languagePopup)

            downloadButton.target = self
            downloadButton.action = #selector(installPack)
            downloadButton.frame = NSRect(
                x: Metrics.width - Metrics.downloadWidth,
                y: y,
                width: Metrics.downloadWidth,
                height: Metrics.rowHeight
            )
            styleOutlineButton(downloadButton)
            addSubview(downloadButton)
            applyPackUI(for: language)

            y -= Metrics.gap
            y -= Metrics.rowHeight
            let login = NSButton(
                checkboxWithTitle: "Launch at Login",
                target: self,
                action: #selector(toggleLogin(_:))
            )
            login.font = .systemFont(ofSize: 12)
            login.state = status.launchAtLogin ? .on : .off
            login.frame = NSRect(x: 0, y: y, width: Metrics.width, height: Metrics.rowHeight)
            addSubview(login)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

        private func addBlockHeader(_ title: String, y: inout CGFloat) {
            y -= Metrics.blockTitleHeight
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = .labelColor
            label.frame = NSRect(x: 0, y: y, width: Metrics.width, height: Metrics.blockTitleHeight)
            addSubview(label)

            y -= Metrics.afterRule
            y -= Metrics.ruleHeight
            let rule = NSBox(frame: NSRect(x: 0, y: y, width: Metrics.width, height: Metrics.ruleHeight))
            rule.boxType = .separator
            rule.titlePosition = .noTitle
            addSubview(rule)

            y -= 2
        }

        private func styleOutlineButton(_ button: NSButton) {
            button.bezelStyle = .rounded
            button.isBordered = false
            button.controlSize = .small
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = 1.25
            button.layer?.masksToBounds = true
        }

        private func setOutlineAppearance(_ button: NSButton, emphasized: Bool, title: String) {
            let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .regular)
            let stroke: NSColor
            let fill: NSColor
            let text: NSColor
            if emphasized {
                stroke = .controlAccentColor
                fill = NSColor.textBackgroundColor
                text = .controlAccentColor
            } else {
                stroke = NSColor.separatorColor
                fill = NSColor.textBackgroundColor.withAlphaComponent(0.6)
                text = .tertiaryLabelColor
            }
            button.layer?.backgroundColor = fill.cgColor
            button.layer?.borderColor = stroke.cgColor
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: text,
                    .font: font,
                ]
            )
        }

        /// `✓ [Button…]` on one row.
        private func addMarkedButton(
            ok: Bool,
            title: String,
            y: inout CGFloat,
            action: Selector
        ) {
            y -= Metrics.rowHeight
            let markLabel = NSTextField(labelWithString: mark(ok))
            markLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            markLabel.alignment = .center
            markLabel.textColor = ok ? .secondaryLabelColor : .labelColor
            markLabel.frame = NSRect(
                x: 0,
                y: y + 2,
                width: Metrics.markWidth,
                height: 20
            )
            addSubview(markLabel)

            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
            button.frame = NSRect(
                x: Metrics.markWidth + 4,
                y: y,
                width: Metrics.width - Metrics.markWidth - 4,
                height: Metrics.rowHeight
            )
            addSubview(button)
        }

        private func applyPackUI(for language: AppLanguage) {
            let ready = SetupChecker.languagePackReady(for: language)
            if ready {
                downloadButton.isEnabled = false
                setOutlineAppearance(downloadButton, emphasized: false, title: "Installed")
            } else {
                downloadButton.isEnabled = true
                setOutlineAppearance(downloadButton, emphasized: true, title: "Download")
            }
        }

        @objc private func languageChanged(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let lang = AppLanguage(rawValue: raw)
            else { return }
            applyPackUI(for: lang)
            onLanguage(lang)
        }

        @objc private func openMic() {
            SetupChecker.requestMicrophoneIfNeeded { _ in
                DispatchQueue.main.async {
                    Permissions.openMicrophoneSettings()
                }
            }
        }

        @objc private func openAccessibility() {
            Permissions.openAccessibilitySettings()
        }

        @objc private func openInputMonitoring() {
            Permissions.openInputMonitoringSettings()
        }

        @objc private func installPack() {
            let lang = AppLanguage.current
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(lang.fetchCommand + "\n", forType: .string)

            let models = ModelLocator.applicationSupportModels
            try? FileManager.default.createDirectory(
                atPath: models,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(URL(fileURLWithPath: models, isDirectory: true))

            let alert = NSAlert()
            alert.messageText = "\(lang.displayName) pack"
            alert.informativeText = """
            Fetch command copied. Finder opened models/.

            Run the command in the repo, put the pack in that folder (or Debug → Use model folder…), then Refresh.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        @objc private func toggleLogin(_ sender: NSButton) {
            if let err = SetupChecker.setLaunchAtLogin(sender.state == .on) {
                let alert = NSAlert()
                alert.messageText = "Launch at Login"
                alert.informativeText = err
                alert.alertStyle = .warning
                alert.runModal()
                sender.state = SetupChecker.launchAtLoginEnabled ? .on : .off
            }
        }
    }
}
