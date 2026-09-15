import Cocoa

@MainActor
final class SpeechSettingsWindowController: NSWindowController {
    var beforeSetup: (@MainActor () async -> Bool)?
    var onSetupFinished: (@MainActor () -> Void)?
    private let runtime = LocalASRRuntime()
    private let status = NSTextField(labelWithString: "")
    private let hotwords = NSButton(checkboxWithTitle: "Use vocabulary during recognition (experimental)", target: nil, action: nil)
    private let correction = NSButton(checkboxWithTitle: "Correct Chinese homophones using vocabulary context", target: nil, action: nil)
    private let strength = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spinner = NSProgressIndicator()
    private lazy var prepareButton = NSButton(title: "Prepare Local Model…", target: self, action: #selector(prepareModel))
    private lazy var vocabularyButton = NSButton(title: "Edit Vocabulary…", target: self, action: #selector(editVocabulary))
    private lazy var logButton = NSButton(title: "View Setup Log", target: self, action: #selector(viewLog))
    private var setup: Task<Void, Never>?
    private var startingSetup = false

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Speech Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        hotwords.state = Settings.shared.hotwordsEnabled ? .on : .off
        correction.state = Settings.shared.pinyinCorrectionEnabled ? .on : .off
        strength.selectItem(withTag: Int(Settings.shared.hotwordScore))
        refreshStatus()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func cancelPreparation() {
        setup?.cancel()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "FireRedASR2-AED · Chinese and English")
        title.font = .boldSystemFont(ofSize: 14)
        let detail = NSTextField(wrappingLabelWithString:
            "Recognition runs on this Mac. The local model needs about 4.6 GB of storage. Hold Fn to speak for up to 30 seconds; release it to transcribe.")
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 510
        hotwords.target = self
        hotwords.action = #selector(saveOptions)
        correction.target = self
        correction.action = #selector(saveOptions)
        for (label, score) in [("Low · 2", 2), ("Normal · 4", 4), ("High · 6", 6), ("Maximum · 8", 8)] {
            strength.addItem(withTitle: label)
            strength.lastItem?.tag = score
        }
        strength.target = self
        strength.action = #selector(saveOptions)
        let strengthRow = NSStackView(views: [NSTextField(labelWithString: "Hotword strength"), strength])
        strengthRow.orientation = .horizontal
        strengthRow.spacing = 10
        let note = NSTextField(wrappingLabelWithString:
            "Select up to 64 relevant words. Higher strength can introduce words you did not say. Vocabulary changes apply to the next phrase.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        note.preferredMaxLayoutWidth = 510
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.orientation = .horizontal
        let buttons = NSStackView(views: [prepareButton, vocabularyButton, logButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, detail, hotwords, strengthRow, correction, note, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.widthAnchor.constraint(equalToConstant: 510),
            note.widthAnchor.constraint(equalToConstant: 510)
        ])
        window?.setContentSize(stack.fittingSize)
    }

    private func refreshStatus() {
        let busy = setup != nil || startingSetup
        prepareButton.isEnabled = !busy
        vocabularyButton.isEnabled = !busy && FileManager.default.fileExists(atPath: runtime.vocabulary.path)
        strength.isEnabled = hotwords.state == .on
        logButton.isHidden = !FileManager.default.fileExists(atPath: runtime.directory.appendingPathComponent("setup.log").path)
        if busy {
            status.stringValue = "Preparing the local speech model…"
            spinner.startAnimation(nil)
        } else {
            status.stringValue = runtime.isPrepared ? "Local model is prepared." : "Prepare the model before using local recognition."
            spinner.stopAnimation(nil)
        }
    }

    @objc private func saveOptions() {
        Settings.shared.hotwordsEnabled = hotwords.state == .on
        Settings.shared.pinyinCorrectionEnabled = correction.state == .on
        Settings.shared.hotwordScore = Double(strength.selectedItem?.tag ?? 4)
        strength.isEnabled = hotwords.state == .on
    }

    @objc private func editVocabulary() {
        NSWorkspace.shared.open(runtime.vocabulary)
    }

    @objc private func viewLog() {
        NSWorkspace.shared.open(runtime.directory.appendingPathComponent("setup.log"))
    }

    @objc private func prepareModel() {
        guard setup == nil, !startingSetup else { return }
        startingSetup = true
        refreshStatus()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.beforeSetup?() ?? true else {
                self.startingSetup = false
                self.refreshStatus()
                self.status.stringValue = "Finish dictating before preparing the model."
                return
            }
            self.runSetup()
        }
    }

    private func runSetup() {
        let runtime = self.runtime
        startingSetup = false
        setup = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await runtime.prepare { message in
                    Task { @MainActor in self.status.stringValue = message }
                }
                self.setup = nil
                self.refreshStatus()
            } catch {
                self.setup = nil
                self.refreshStatus()
                self.status.stringValue = error.localizedDescription
                let message = "Model setup failed: \(error.localizedDescription)\n"
                try? Data(message.utf8).write(to: runtime.directory.appendingPathComponent("setup.log"), options: .atomic)
                self.logButton.isHidden = false
            }
            self.onSetupFinished?()
        }
        refreshStatus()
    }
}
