import AppKit

/// Shared Setup UI for first-run and menu → Setup….
/// Fixed-width `NSPanel` (not `NSAlert`) so content height cannot widen the window.
enum SetupDialog {
    /// Called when the user changes language inside the dialog (recreate ASR session).
    static var onLanguageChanged: ((AppLanguage) -> Void)?

    fileprivate enum Metrics {
        /// Body content width (Permission / General columns).
        static let bodyWidth: CGFloat = 236
        static let padding: CGFloat = 16
        static var panelWidth: CGFloat { bodyWidth + padding * 2 }

        /// Space under the transparent titlebar (traffic lights).
        static let titlebarInset: CGFloat = 28
        static let headingHeight: CGFloat = 22
        static let subtitleHeight: CGFloat = 34
        static let buttonRowHeight: CGFloat = 28
        static let chromeGap: CGFloat = 12
        static let rowHeight: CGFloat = 26
        static let gap: CGFloat = 5
        static let sectionGap: CGFloat = 10
        static let markWidth: CGFloat = 20
        static let downloadWidth: CGFloat = 78
        static let blockTitleHeight: CGFloat = 18
        static let ruleHeight: CGFloat = 1
        static let afterRule: CGFloat = 8
        /// `addBlockHeader` trailing `y -= 2`.
        static let headerTail: CGFloat = 2
        static let titleToContent: CGFloat = 6

        static var blockHeader: CGFloat {
            blockTitleHeight + afterRule + ruleHeight + headerTail
        }

        static var section: CGFloat {
            blockTitleHeight + titleToContent + rowHeight
        }

        /// Body height for Permission + General (Language + Auto Launch).
        static var bodyHeight: CGFloat {
            blockHeader
                + rowHeight * 3
                + gap * 2
                + sectionGap
                + blockHeader
                + section
                + sectionGap
                + section
        }

        static var panelHeight: CGFloat {
            titlebarInset
                + padding
                + headingHeight
                + 4
                + subtitleHeight
                + chromeGap
                + bodyHeight
                + chromeGap
                + buttonRowHeight
                + padding
        }
    }

    /// Present the setup dialog. When `isFirstRun`, Later records `setupDismissed`.
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
        PanelController(isFirstRun: isFirstRun).runModal()
    }

    // MARK: - Panel controller

    fileprivate final class PanelController: NSObject, NSWindowDelegate {
        private let isFirstRun: Bool
        private let panel: NSPanel
        /// Host for controls; embedded in Liquid Glass on macOS 26+ (same stack as `NSAlert`).
        private let contentHost: NSView

        init(isFirstRun: Bool) {
            self.isFirstRun = isFirstRun
            let size = NSSize(width: Metrics.panelWidth, height: Metrics.panelHeight)

            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Setup"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            // Match `_NSAlertPanel`: normal level, not a floating utility.
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true

            contentHost = NSView(frame: NSRect(origin: .zero, size: size))
            contentHost.autoresizingMask = [.width, .height]

            if #available(macOS 26.0, *) {
                // Public API for the Liquid Glass used by system alerts.
                let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
                glass.cornerRadius = 12
                glass.style = .regular
                glass.contentView = contentHost
                panel.contentView = glass
            } else {
                let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
                effect.material = .sheet
                effect.blendingMode = .behindWindow
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = 12
                effect.layer?.masksToBounds = true
                effect.addSubview(contentHost)
                panel.contentView = effect
            }

            super.init()
            panel.delegate = self
            rebuildContent()
            panel.setContentSize(size)
            panel.center()
        }

        func runModal() {
            NSApp.activate(ignoringOtherApps: true)
            panel.level = .modalPanel
            panel.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: panel)
            panel.orderOut(nil)
            panel.level = .normal
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isFirstRun {
                ModelLocator.setupDismissed = true
            }
            NSApp.stopModal()
            return true
        }

        private func rebuildContent() {
            contentHost.subviews.forEach { $0.removeFromSuperview() }
            let status = SetupChecker.current()
            var y = contentHost.bounds.height - Metrics.titlebarInset - Metrics.padding

            y -= Metrics.headingHeight
            let heading = NSTextField(labelWithString: "Setup")
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            heading.textColor = .labelColor
            heading.frame = NSRect(
                x: Metrics.padding,
                y: y,
                width: Metrics.bodyWidth,
                height: Metrics.headingHeight
            )
            contentHost.addSubview(heading)

            y -= 4
            y -= Metrics.subtitleHeight
            let subtitle = NSTextField(
                wrappingLabelWithString: status.isComplete
                    ? "Ready. You can close this."
                    : "Open each item that’s missing, then Refresh."
            )
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.maximumNumberOfLines = 2
            subtitle.backgroundColor = .clear
            subtitle.drawsBackground = false
            subtitle.frame = NSRect(
                x: Metrics.padding,
                y: y,
                width: Metrics.bodyWidth,
                height: Metrics.subtitleHeight
            )
            contentHost.addSubview(subtitle)

            y -= Metrics.chromeGap
            y -= Metrics.bodyHeight
            let body = BodyView(
                status: status,
                language: AppLanguage.current,
                onLanguage: { lang in
                    AppLanguage.current = lang
                    SetupDialog.onLanguageChanged?(lang)
                }
            )
            body.frame = NSRect(
                x: Metrics.padding,
                y: y,
                width: Metrics.bodyWidth,
                height: Metrics.bodyHeight
            )
            contentHost.addSubview(body)

            y -= Metrics.chromeGap
            y -= Metrics.buttonRowHeight

            let btnW: CGFloat = 72
            let btnGap: CGFloat = 8
            var bx = Metrics.panelWidth - Metrics.padding - btnW

            let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
            done.bezelStyle = .rounded
            done.keyEquivalent = "\r"
            done.frame = NSRect(x: bx, y: y, width: btnW, height: Metrics.buttonRowHeight)
            contentHost.addSubview(done)

            bx -= btnGap + btnW
            let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
            refresh.bezelStyle = .rounded
            refresh.frame = NSRect(x: bx, y: y, width: btnW, height: Metrics.buttonRowHeight)
            contentHost.addSubview(refresh)

            if isFirstRun {
                bx -= btnGap + btnW
                let later = NSButton(title: "Later", target: self, action: #selector(laterTapped))
                later.bezelStyle = .rounded
                later.frame = NSRect(x: bx, y: y, width: btnW, height: Metrics.buttonRowHeight)
                contentHost.addSubview(later)
            }
        }

        @objc private func doneTapped() {
            if SetupChecker.current().isComplete {
                ModelLocator.setupDismissed = true
            }
            NSApp.stopModal()
        }

        @objc private func refreshTapped() {
            rebuildContent()
        }

        @objc private func laterTapped() {
            ModelLocator.setupDismissed = true
            NSApp.stopModal()
        }
    }

    // MARK: - Body

    fileprivate final class BodyView: NSView {
        private let languagePopup: NSPopUpButton
        private let downloadButton: NSButton
        private let onLanguage: (AppLanguage) -> Void
        private let w = Metrics.bodyWidth

        init(
            status: SetupStatus,
            language: AppLanguage,
            onLanguage: @escaping (AppLanguage) -> Void
        ) {
            self.onLanguage = onLanguage
            self.languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            self.downloadButton = NSButton(title: "Download", target: nil, action: nil)
            super.init(frame: NSRect(x: 0, y: 0, width: w, height: Metrics.bodyHeight))

            var y = Metrics.bodyHeight

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

            y -= Metrics.blockTitleHeight
            let langTitle = NSTextField(labelWithString: "Language")
            langTitle.font = .systemFont(ofSize: 11, weight: .semibold)
            langTitle.textColor = .secondaryLabelColor
            langTitle.frame = NSRect(x: 0, y: y, width: w, height: Metrics.blockTitleHeight)
            addSubview(langTitle)

            y -= Metrics.titleToContent
            y -= Metrics.rowHeight
            languagePopup.frame = NSRect(
                x: 0,
                y: y,
                width: w - Metrics.downloadWidth - 6,
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
                x: w - Metrics.downloadWidth,
                y: y,
                width: Metrics.downloadWidth,
                height: Metrics.rowHeight
            )
            styleOutlineButton(downloadButton)
            addSubview(downloadButton)
            applyPackUI(for: language)

            y -= Metrics.sectionGap
            y -= Metrics.blockTitleHeight
            let autoTitle = NSTextField(labelWithString: "Auto Launch")
            autoTitle.font = .systemFont(ofSize: 11, weight: .semibold)
            autoTitle.textColor = .secondaryLabelColor
            autoTitle.frame = NSRect(x: 0, y: y, width: w, height: Metrics.blockTitleHeight)
            addSubview(autoTitle)

            y -= Metrics.titleToContent
            y -= Metrics.rowHeight
            let login = NSButton(
                checkboxWithTitle: "Launch at Login",
                target: self,
                action: #selector(toggleLogin(_:))
            )
            login.font = .systemFont(ofSize: 12)
            login.state = status.launchAtLogin ? .on : .off
            login.frame = NSRect(x: 0, y: y, width: w, height: Metrics.rowHeight)
            addSubview(login)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

        private func addBlockHeader(_ title: String, y: inout CGFloat) {
            y -= Metrics.blockTitleHeight
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .bold)
            label.textColor = .labelColor
            label.frame = NSRect(x: 0, y: y, width: w, height: Metrics.blockTitleHeight)
            addSubview(label)

            y -= Metrics.afterRule
            y -= Metrics.ruleHeight
            let rule = NSBox(frame: NSRect(x: 0, y: y, width: w, height: Metrics.ruleHeight))
            rule.boxType = .separator
            rule.titlePosition = .noTitle
            addSubview(rule)

            y -= Metrics.headerTail
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
                width: w - Metrics.markWidth - 4,
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

        private func selectedLanguage() -> AppLanguage {
            if let raw = languagePopup.selectedItem?.representedObject as? String,
               let lang = AppLanguage(rawValue: raw)
            {
                return lang
            }
            return AppLanguage.current
        }

        @objc private func installPack() {
            let lang = selectedLanguage()
            if lang != AppLanguage.current {
                onLanguage(lang)
            }

            guard PackDownloader.isInAppDownloadSupported(for: lang) else {
                let alert = NSAlert()
                alert.messageText = "\(lang.displayName) pack"
                alert.informativeText = PackDownloader.DownloadError.unsupported(lang)
                    .errorDescription ?? ""
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            downloadButton.isEnabled = false
            setOutlineAppearance(downloadButton, emphasized: false, title: "0%")

            PackDownloader.download(
                language: lang,
                progress: { fraction in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let pct = Int((fraction * 100).rounded(.down))
                        self.setOutlineAppearance(
                            self.downloadButton,
                            emphasized: false,
                            title: "\(pct)%"
                        )
                    }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .success(let dest):
                            ModelLocator.setModelRoot(ModelLocator.applicationSupportModels)
                            if lang == .japanese {
                                ModelLocator.setParakeetJaDir(dest.path)
                            }
                            self.applyPackUI(for: lang)
                            self.onLanguage(lang)
                        case .failure(let error):
                            self.applyPackUI(for: lang)
                            let alert = NSAlert()
                            alert.messageText = "Download failed"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }
            )
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
