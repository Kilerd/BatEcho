import Cocoa

@MainActor
final class SpeechSettingsWindowController: NSWindowController {
    var beforeSetup: (@MainActor () async -> Bool)?
    var onSetupFinished: (@MainActor () -> Void)?
    private let runtime = LocalASRRuntime()
    private let status = NSTextField(labelWithString: "")
    private let hotwords = NSButton(checkboxWithTitle: "Use vocabulary as recognition hints", target: nil, action: nil)
    private let correction = NSButton(checkboxWithTitle: "Correct Chinese homophones using vocabulary context", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private lazy var prepareButton = NSButton(title: "Prepare Local Model…", target: self, action: #selector(prepareModel))
    private lazy var vocabularyButton = NSButton(title: "Edit Vocabulary…", target: self, action: #selector(editVocabulary))
    private lazy var logButton = NSButton(title: "View Setup Log", target: self, action: #selector(viewLog))
    private var setup: Task<Void, Never>?
    private var startingSetup = false

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "BatEcho · Speech Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        hotwords.state = Settings.shared.hotwordsEnabled ? .on : .off
        correction.state = Settings.shared.pinyinCorrectionEnabled ? .on : .off
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
        let title = NSTextField(labelWithString: "Qwen3-ASR-0.6B · Chinese and English")
        title.font = .boldSystemFont(ofSize: 14)
        let detail = NSTextField(wrappingLabelWithString:
            "Recognition runs on this Mac. The local model needs about 1 GB of storage. Hold Fn to dictate continuously; release it to finish and insert your text.")
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 510
        hotwords.target = self
        hotwords.action = #selector(saveOptions)
        correction.target = self
        correction.action = #selector(saveOptions)
        let note = NSTextField(wrappingLabelWithString:
            "Keep up to 64 relevant names and terms in your vocabulary. Unrelated hints can reduce accuracy. Vocabulary changes apply to the next phrase.")
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
        let stack = NSStackView(views: [title, detail, hotwords, correction, note, statusRow, buttons])
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
