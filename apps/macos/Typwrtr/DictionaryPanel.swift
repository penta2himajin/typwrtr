import AppKit

/// Settings CRUD for the speaker term dictionary (ux-decisions §9a).
///
/// Saves go through UniFFI `saveTermDictionary`; the shell recreates the
/// ASR session so the next utterance sees the change (Q34).
enum DictionaryPanel {
    /// Present a modal editor for `language`. Returns after the panel closes.
    static func runModal(language: AppLanguage, onSaved: @escaping () -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Dictionary — \(language.displayName)"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        let host = EditorView(language: language, onSaved: onSaved) {
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
    }

    fileprivate final class EditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
        private let language: AppLanguage
        private let onSaved: () -> Void
        private let onClose: () -> Void
        private var entries: [FfiTermEntry] = []
        private var loadFailedMessage: String?
        private let table = NSTableView()
        private let statusLabel = NSTextField(labelWithString: "")
        private let scroll = NSScrollView()

        init(language: AppLanguage, onSaved: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.language = language
            self.onSaved = onSaved
            self.onClose = onClose
            super.init(frame: .zero)
            wantsLayer = true
            build()
            reloadFromDisk()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:)") }

        private func build() {
            let pad: CGFloat = 14
            var y: CGFloat = 360 - pad

            y -= 36
            statusLabel.font = .systemFont(ofSize: 11)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.maximumNumberOfLines = 2
            statusLabel.lineBreakMode = .byWordWrapping
            statusLabel.frame = NSRect(x: pad, y: y, width: 392, height: 36)
            addSubview(statusLabel)

            y -= 8
            let tableHeight: CGFloat = 220
            y -= tableHeight
            scroll.frame = NSRect(x: pad, y: y, width: 392, height: tableHeight)
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = table
            table.headerView = nil
            table.allowsMultipleSelection = false
            table.rowHeight = 22
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
            col.width = 370
            table.addTableColumn(col)
            table.dataSource = self
            table.delegate = self
            addSubview(scroll)

            y -= 40
            let add = NSButton(title: "Add…", target: self, action: #selector(addEntry))
            add.bezelStyle = .rounded
            add.frame = NSRect(x: pad, y: y, width: 72, height: 28)
            addSubview(add)

            let edit = NSButton(title: "Edit…", target: self, action: #selector(editEntry))
            edit.bezelStyle = .rounded
            edit.frame = NSRect(x: pad + 80, y: y, width: 72, height: 28)
            addSubview(edit)

            let remove = NSButton(title: "Delete", target: self, action: #selector(deleteEntry))
            remove.bezelStyle = .rounded
            remove.frame = NSRect(x: pad + 160, y: y, width: 72, height: 28)
            addSubview(remove)

            let done = NSButton(title: "Done", target: self, action: #selector(close))
            done.bezelStyle = .rounded
            done.keyEquivalent = "\r"
            done.frame = NSRect(x: 420 - pad - 72, y: y, width: 72, height: 28)
            addSubview(done)
        }

        private func reloadFromDisk() {
            let snap = loadTermDictionary(language: language.ffi)
            if snap.loadFailed {
                entries = []
                loadFailedMessage = snap.failureMessage
                    ?? "This language’s dictionary file could not be loaded."
                statusLabel.stringValue =
                    "Could not load dictionary — file left on disk for repair.\n\(loadFailedMessage!)"
                statusLabel.textColor = .systemOrange
            } else {
                entries = snap.entries
                loadFailedMessage = nil
                let path = termDictionaryPath(language: language.ffi)
                statusLabel.stringValue =
                    entries.isEmpty
                    ? "No terms yet. Add spellings the recogniser gets wrong.\n\(path)"
                    : "\(entries.count) term(s). File: \(path)"
                statusLabel.textColor = .secondaryLabelColor
            }
            table.reloadData()
        }

        private func persist(_ next: [FfiTermEntry]) -> Bool {
            do {
                try saveTermDictionary(language: language.ffi, entries: next)
                entries = next
                loadFailedMessage = nil
                onSaved()
                reloadFromDisk()
                return true
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not save dictionary"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.runModal()
                return false
            }
        }

        @objc private func addEntry() {
            guard let draft = prompt(term: "", aliases: "") else { return }
            var next = entries
            next.append(draft)
            _ = persist(next)
        }

        @objc private func editEntry() {
            let row = table.selectedRow
            guard row >= 0, row < entries.count else { return }
            let current = entries[row]
            guard let draft = prompt(
                term: current.term,
                aliases: current.aliases.joined(separator: ", ")
            ) else { return }
            var next = entries
            next[row] = draft
            _ = persist(next)
        }

        @objc private func deleteEntry() {
            let row = table.selectedRow
            guard row >= 0, row < entries.count else { return }
            var next = entries
            next.remove(at: row)
            _ = persist(next)
        }

        @objc private func close() {
            onClose()
        }

        private func prompt(term: String, aliases: String) -> FfiTermEntry? {
            let alert = NSAlert()
            alert.messageText = term.isEmpty ? "Add term" : "Edit term"
            alert.informativeText = "Preferred spelling, then aliases the ASR may produce (comma-separated)."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: 280, height: 54)

            let termField = NSTextField(string: term)
            termField.placeholderString = "term (e.g. typwrtr)"
            termField.frame.size.height = 24

            let aliasField = NSTextField(string: aliases)
            aliasField.placeholderString = "aliases (e.g. タイプライター, typewriter)"
            aliasField.frame.size.height = 24

            stack.addArrangedSubview(termField)
            stack.addArrangedSubview(aliasField)
            alert.accessoryView = stack

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let t = termField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliasList = aliasField.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !t.isEmpty else { return nil }
            return FfiTermEntry(term: t, aliases: aliasList)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
            -> NSView?
        {
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField)
                ?? {
                    let t = NSTextField(labelWithString: "")
                    t.identifier = id
                    t.font = .systemFont(ofSize: 12)
                    return t
                }()
            let e = entries[row]
            let aliases = e.aliases.joined(separator: ", ")
            cell.stringValue = aliases.isEmpty ? e.term : "\(e.term)  ←  \(aliases)"
            return cell
        }
    }
}
