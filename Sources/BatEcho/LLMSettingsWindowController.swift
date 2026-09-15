import Cocoa

final class LLMSettingsWindowController: NSWindowController {
    private let baseURLField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: " ")
    private lazy var testButton = NSButton(title: "Test", target: self, action: #selector(runTest))
    private lazy var saveButton = NSButton(title: "Save", target: self, action: #selector(save))

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "BatEcho · LLM Refinement"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        loadValues()
        statusLabel.stringValue = " "
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func loadValues() {
        let settings = Settings.shared
        baseURLField.stringValue = settings.llmBaseURL
        apiKeyField.stringValue = settings.llmAPIKey
        modelField.stringValue = settings.llmModel
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        baseURLField.placeholderString = "https://api.openai.com/v1"
        apiKeyField.placeholderString = "sk-... (leave empty to clear)"
        modelField.placeholderString = "gpt-4o-mini"

        let grid = NSGridView(views: [
            [Self.makeLabel("API Base URL"), baseURLField],
            [Self.makeLabel("API Key"), apiKeyField],
            [Self.makeLabel("Model"), modelField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 320

        saveButton.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [statusLabel, spacer, testButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [grid, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            buttonRow.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        window?.setContentSize(stack.fittingSize)
    }

    @objc private func runTest() {
        let config = currentConfig()
        guard config.isUsable else {
            statusLabel.stringValue = "Base URL and model are required."
            return
        }
        testButton.isEnabled = false
        statusLabel.stringValue = "Testing..."
        Task { [weak self] in
            let result = await LLMRefiner.test(config: config)
            await MainActor.run {
                guard let self else { return }
                self.testButton.isEnabled = true
                switch result {
                case .success:
                    self.statusLabel.stringValue = "Connection OK."
                case .failure(let error):
                    self.statusLabel.stringValue = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func save() {
        let settings = Settings.shared
        settings.llmBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stored verbatim: an emptied field clears the saved key.
        settings.llmAPIKey = apiKeyField.stringValue
        settings.llmModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = "Saved."
    }

    private func currentConfig() -> LLMConfig {
        LLMConfig(
            baseURL: baseURLField.stringValue,
            apiKey: apiKeyField.stringValue,
            model: modelField.stringValue
        )
    }

    private static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }
}
