import Cocoa

@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    private let runtime: LocalASRRuntime
    private var vocabulary: VocabularyDocument?
    private var tokenizer: QwenTokenizer?
    private var converter: PinyinConverter?
    private var visibleRows: [VocabularyDocument.Row] = []
    private var selectedID: UUID?
    private var updating = false
    private let search = NSSearchField()
    private let table = NSTableView()
    private let count = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let word = NSTextField()
    private let pinyin = NSTextField()
    private let contexts = NSTextView()
    private let form = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "Select a word to edit it, or add a new one.")
    private lazy var addButton = NSButton(title: "Add Word", target: self, action: #selector(addWord))
    private lazy var deleteButton = NSButton(title: "Delete Word", target: self, action: #selector(deleteWord))
    private lazy var suggestButton = NSButton(title: "Fill Pinyin", target: self, action: #selector(fillPinyin))
    private lazy var saveButton = NSButton(title: "Save Changes", target: self, action: #selector(saveChanges))
    private lazy var reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadFile))

    init(runtime: LocalASRRuntime) {
        self.runtime = runtime
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "BatEcho · Vocabulary"
        window.minSize = NSSize(width: 800, height: 720)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        if window?.isVisible != true {
            load()
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = label("Your vocabulary", size: 22, weight: .semibold)
        let subtitle = label("Names and terms you want BatEcho to recognize.", secondary: true)
        let header = column([title, subtitle], spacing: 5)
        let body = NSView()
        let sidebar = NSView()
        let detail = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        let bottomLine = NSBox()
        bottomLine.boxType = .separator
        for view in [header, body, bottomLine] { pin(view, to: content) }
        for view in [sidebar, divider, detail] { pin(view, to: body) }

        search.placeholderString = "Search words or pinyin"
        search.setAccessibilityLabel("Search vocabulary")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        count.font = .systemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.rowHeight = 47
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.style = .inset
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Vocabulary words")
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.drawsBackground = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.keyEquivalent = "n"
        addButton.keyEquivalentModifierMask = .command
        let listButtons = NSStackView(views: [addButton, deleteButton])
        listButtons.spacing = 8
        for view in [search, count, list, listButtons] { pin(view, to: sidebar) }

        word.font = .systemFont(ofSize: 19)
        word.placeholderString = "e.g. 青简, Kubernetes"
        word.delegate = self
        word.setAccessibilityLabel("Word or phrase")
        pinyin.placeholderString = "e.g. qing jian"
        pinyin.delegate = self
        pinyin.setAccessibilityLabel("Pinyin")
        contexts.isRichText = false
        contexts.isAutomaticQuoteSubstitutionEnabled = false
        contexts.isAutomaticSpellingCorrectionEnabled = false
        contexts.isAutomaticTextReplacementEnabled = false
        contexts.font = .systemFont(ofSize: 13)
        contexts.textContainerInset = NSSize(width: 6, height: 6)
        contexts.isVerticallyResizable = true
        contexts.isHorizontallyResizable = false
        contexts.autoresizingMask = .width
        contexts.textContainer?.widthTracksTextView = true
        contexts.delegate = self
        contexts.setAccessibilityLabel("Correction contexts, one per line")
        let contextScroll = NSScrollView()
        contextScroll.borderType = .bezelBorder
        contextScroll.documentView = contexts
        contextScroll.hasVerticalScroller = true
        let pinyinRow = NSStackView(views: [pinyin, suggestButton])
        pinyinRow.spacing = 8
        pinyin.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let optionalLine = NSBox()
        optionalLine.boxType = .separator
        let fields: [NSView] = [
            label("Word or phrase", weight: .semibold), word,
            label("Use the spelling you want in your transcription.", secondary: true), optionalLine,
            label("Chinese correction · Optional", weight: .semibold),
            label("Add pinyin and context to correct Chinese homophones. English terms only need a word above.", secondary: true),
            label("Pinyin", weight: .medium), pinyinRow,
            label("One syllable per character, separated by spaces. No tones; use v for ü. Check suggested readings for names.", size: 11, secondary: true),
            label("Correction contexts · One per line", weight: .medium), contextScroll,
            label("For 青简, try 项目 or 输入法. Correction is applied only when a context also appears in the sentence and Chinese correction is enabled in Speech Settings.", size: 11, secondary: true)
        ]
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        for view in fields {
            form.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        form.setCustomSpacing(19, after: fields[2])
        form.setCustomSpacing(18, after: optionalLine)
        word.heightAnchor.constraint(equalToConstant: 32).isActive = true
        contextScroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
        pin(form, to: detail)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        pin(empty, to: detail)

        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityLabel("Vocabulary save status")
        pin(status, to: content)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [reloadButton, saveButton])
        buttons.spacing = 8
        pin(buttons, to: content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -16),
            sidebar.topAnchor.constraint(equalTo: body.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            sidebar.widthAnchor.constraint(equalToConstant: 260),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            divider.topAnchor.constraint(equalTo: body.topAnchor),
            divider.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 24),
            detail.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            detail.topAnchor.constraint(equalTo: body.topAnchor),
            detail.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            search.topAnchor.constraint(equalTo: sidebar.topAnchor),
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            count.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            count.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            count.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            list.topAnchor.constraint(equalTo: count.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -12),
            listButtons.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            form.topAnchor.constraint(equalTo: detail.topAnchor),
            form.bottomAnchor.constraint(lessThanOrEqualTo: detail.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 30),
            empty.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -30),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            status.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
    }

    private func load() {
        do {
            if let vocabulary { try vocabulary.reload() }
            else {
                vocabulary = try VocabularyDocument(url: runtime.vocabulary,
                    seed: Data(contentsOf: LocalASRRuntime.resources.appendingPathComponent("lexicon.json")))
            }
            search.stringValue = ""
            refreshList(selecting: selectedID)
            refreshStatus()
        } catch {
            refreshList(selecting: selectedID)
            refreshStatus()
            showError(error)
        }
    }

    private func refreshList(selecting id: UUID?) {
        updating = true
        visibleRows = vocabulary?.matching(search.stringValue) ?? []
        table.reloadData()
        let index = id.flatMap { id in visibleRows.firstIndex(where: { $0.id == id }) } ?? (visibleRows.isEmpty ? nil : 0)
        if let index {
            selectedID = visibleRows[index].id
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            selectedID = nil
            table.deselectAll(nil)
        }
        updating = false
        showSelection()
    }

    private func showSelection() {
        updating = true
        defer { updating = false }
        let entry = vocabulary?.rows.first(where: { $0.id == selectedID })?.entry
        form.isHidden = entry == nil
        empty.isHidden = entry != nil
        empty.stringValue = vocabulary == nil ? "Your vocabulary could not be opened. Check the message below, then try Reload." :
            (search.stringValue.isEmpty ? "Add a word to help BatEcho recognize names and terms." : "No matching words. Try another search or add a word.")
        word.stringValue = entry?.text ?? ""
        pinyin.stringValue = entry?.pinyin.joined(separator: " ") ?? ""
        contexts.string = entry?.contexts.joined(separator: "\n") ?? ""
        deleteButton.isEnabled = entry != nil
        updatePinyinButton()
    }

    private func captureDraft() {
        guard !updating, let id = selectedID else { return }
        vocabulary?.update(id, entry: .init(
            text: word.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            pinyin: pinyin.stringValue.lowercased().replacingOccurrences(of: "ü", with: "v").split(whereSeparator: \.isWhitespace).map(String.init),
            contexts: contexts.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        // Keep the selected draft visible while typing, even when its name no longer matches the search.
        if let index = visibleRows.firstIndex(where: { $0.id == id }),
           let updated = vocabulary?.rows.first(where: { $0.id == id }) {
            visibleRows[index] = updated
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }
        refreshStatus()
        updatePinyinButton()
    }

    private func updatePinyinButton() {
        let text = word.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestButton.isEnabled = !text.isEmpty && text.unicodeScalars.allSatisfy(HotwordTokenizer.isHanzi)
    }

    private func refreshStatus(_ message: String? = nil) {
        let total = vocabulary?.rows.count ?? 0
        let matches = visibleRows.count == 1 ? "1 match" : "\(visibleRows.count) matches"
        count.stringValue = search.stringValue.isEmpty ? "\(total) / 64 words" : "\(matches) · \(total) / 64 words"
        count.textColor = total > 64 ? .systemRed : .secondaryLabelColor
        addButton.isEnabled = vocabulary != nil && total < 64
        saveButton.isEnabled = vocabulary?.needsSave == true
        window?.isDocumentEdited = vocabulary?.hasChanges == true
        status.textColor = .secondaryLabelColor
        if let message { status.stringValue = message }
        else if vocabulary?.hasChanges == true {
            status.stringValue = "Unsaved changes. Save to use these words in your next phrase."
        } else if vocabulary?.needsSave == true {
            status.stringValue = "Save this vocabulary to use it for recognition. You can edit words before preparing the model."
        } else {
            status.stringValue = "Saved words apply to the next phrase when vocabulary hints are enabled in Speech Settings."
        }
    }

    private func showError(_ error: Error) {
        status.textColor = .systemRed
        status.stringValue = error.localizedDescription
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = visibleRows[row].entry
        let name = label(entry.text.isEmpty ? "New word" : entry.text, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        let detail = label(entry.pinyin.isEmpty ? "Recognition hint" : entry.pinyin.joined(separator: " "), size: 11, secondary: true)
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        let cell = NSTableCellView()
        let stack = column([name, detail], spacing: 3)
        pin(stack, to: cell)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        selectedID = visibleRows.indices.contains(table.selectedRow) ? visibleRows[table.selectedRow].id : nil
        showSelection()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search {
            refreshList(selecting: selectedID)
            refreshStatus()
        } else { captureDraft() }
    }

    func textDidChange(_ notification: Notification) { captureDraft() }

    @objc private func addWord() {
        guard let vocabulary, vocabulary.rows.count < 64 else { return }
        window?.makeFirstResponder(nil)
        let id = vocabulary.add()
        search.stringValue = ""
        refreshList(selecting: id)
        refreshStatus()
        window?.makeFirstResponder(word)
    }

    @objc private func deleteWord() {
        guard let id = selectedID else { return }
        window?.makeFirstResponder(nil)
        vocabulary?.remove(id)
        refreshList(selecting: nil)
        refreshStatus("Word removed from the draft. Save Changes to confirm, or Reload to discard your edits.")
    }

    @objc private func fillPinyin() {
        do {
            if converter == nil { converter = try PinyinConverter() }
            pinyin.stringValue = converter?.syllables(word.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).joined(separator: " ") ?? ""
            captureDraft()
        } catch { showError(error) }
    }

    @objc private func saveChanges() { _ = save() }

    @discardableResult private func save() -> Bool {
        window?.makeFirstResponder(nil)
        guard let vocabulary else { return false }
        do {
            let directory = runtime.models.appendingPathComponent(LocalASRRuntime.modelDirectoryName)
            // Only the tokenizer is needed to check hint length; never load speech weights here.
            if tokenizer == nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocab.json").path) {
                tokenizer = try QwenTokenizer(directory: directory)
            }
            try vocabulary.save(encode: tokenizer.map { tokenizer in { try tokenizer.encode($0) } })
            refreshList(selecting: selectedID)
            refreshStatus(tokenizer == nil ?
                "Saved. After model setup, recognition checks the vocabulary's 512-token limit. Keep your list focused." :
                "Saved. Your vocabulary will be used for the next phrase when vocabulary hints are enabled.")
            return true
        } catch {
            showError(error)
            return false
        }
    }

    @objc private func reloadFile() {
        guard vocabulary?.hasChanges == true, let window else { load(); return }
        let alert = NSAlert()
        alert.messageText = "Discard your vocabulary edits?"
        alert.informativeText = "Reload reads the saved vocabulary. Your unsaved changes will be discarded."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard and Reload")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.load() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        guard vocabulary?.hasChanges == true else { return true }
        confirmClosing { if $0 { sender.close() } }
        return false
    }

    func confirmClosing(_ completion: @escaping (Bool) -> Void) {
        window?.makeFirstResponder(nil)
        guard let window, window.isVisible, vocabulary?.hasChanges == true else { completion(true); return }
        guard window.attachedSheet == nil else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "Save your vocabulary changes?"
        alert.informativeText = "Your edits have not been saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: window) { [weak self] response in
            completion(response == .alertThirdButtonReturn || (response == .alertFirstButtonReturn && self?.save() == true))
        }
    }
}
