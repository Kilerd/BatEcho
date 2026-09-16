import ApplicationServices
import AVFoundation
import Cocoa
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let fnMonitor = FnKeyMonitor()
    private var transcriber: SpeechTranscribing?
    private let localASR = LocalASRClient()
    private var warmup: Task<Void, Never>?
    private var recordingEngine = SpeechEngine.local
    private var session = UUID()
    private var preparingModel = false
    private var terminating = false
    private let panel = FloatingPanel()
    private let injector = TextInjector()
    private let refiner = LLMRefiner()
    private lazy var settingsController = LLMSettingsWindowController()
    private lazy var speechSettingsController: SpeechSettingsWindowController = {
        let controller = SpeechSettingsWindowController()
        controller.beforeSetup = { [weak self] in
            guard let self, self.state == .idle else { return false }
            self.preparingModel = true
            self.warmup?.cancel()
            await self.localASR.shutdown()
            return true
        }
        controller.onSetupFinished = { [weak self] in
            self?.preparingModel = false
            self?.warmLocalModel()
        }
        return controller
    }()

    private enum State {
        case idle
        case recording
        case finishing
        case refining
    }

    private var state = State.idle
    private var tapRetryTimer: Timer?
    private var fnMonitorActive = false
    private var failedTapAttempts = 0
    private var relaunchAlertShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if Settings.shared.speechEngine == .apple {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
        promptForAccessibility()
        wireCallbacks()
        startFnMonitor()
        warmLocalModel()
        if CommandLine.arguments.contains("--speech-settings") {
            speechSettingsController.show()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        if preparingModel { speechSettingsController.cancelPreparation() }
        transcriber?.cancel()
        warmup?.cancel()
        Task {
            await localASR.shutdown()
            await MainActor.run { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor.stop()
    }

    // MARK: - Setup

    private func wireCallbacks() {
        fnMonitor.onFnDown = { [weak self] in self?.beginRecording() }
        fnMonitor.onFnUp = { [weak self] in self?.endRecording() }
    }

    private func warmLocalModel() {
        guard !terminating, Settings.shared.speechEngine == .local, LocalASRRuntime().isPrepared else { return }
        warmup?.cancel()
        warmup = Task { [weak self] in
            do { try await self?.localASR.warmUp() }
            catch is CancellationError { }
            catch { NSLog("Local speech warmup failed: %@", error.localizedDescription) }
        }
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startFnMonitor() {
        if fnMonitor.start() {
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            if !fnMonitorActive {
                fnMonitorActive = true
                failedTapAttempts = 0
                NSLog("Fn event tap installed.")
                refreshStatusIcon()
                refreshMenu()
            }
            return
        }

        failedTapAttempts += 1
        let trusted = AXIsProcessTrusted()
        if failedTapAttempts == 1 || failedTapAttempts % 5 == 0 {
            NSLog("Fn event tap creation failed (attempt \(failedTapAttempts), accessibility trusted: \(trusted)).")
        }
        if trusted && failedTapAttempts == 3 {
            // Accessibility looks granted but the tap still fails. Either Input
            // Monitoring is also required on this system, or the grant belongs
            // to a previous build of the binary (stale ad-hoc signature).
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            } else {
                suggestRelaunch()
            }
        }

        guard tapRetryTimer == nil else { return }
        // The event tap cannot be created until permissions are granted; keep retrying.
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startFnMonitor() }
        }
    }

    private func suggestRelaunch() {
        guard !relaunchAlertShown else { return }
        relaunchAlertShown = true
        let alert = NSAlert()
        alert.messageText = "BatEcho cannot listen to the Fn key yet"
        alert.informativeText = """
        Accessibility looks granted, but the Fn listener still cannot start. \
        This usually happens after rebuilding the app: macOS keeps the old \
        binary's permission. In System Settings > Privacy & Security > \
        Accessibility, toggle BatEcho off and on (or remove and re-add it), \
        then relaunch.
        """
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            Task { @MainActor in
                if app != nil && error == nil { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - Recording flow

    private func beginRecording() {
        guard state == .idle, !injector.isBusy else { return }
        guard !preparingModel else {
            panel.flash("The local speech model is being prepared")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            panel.flash("Allow microphone access, then hold Fn again")
            return
        }
        let settings = Settings.shared
        recordingEngine = settings.speechEngine
        let selected: SpeechTranscribing
        if recordingEngine == .local {
            guard LocalASRRuntime().isPrepared else {
                speechSettingsController.show()
                return
            }
            selected = LocalSpeechTranscriber(client: localASR, hotwords: settings.hotwordsEnabled,
                                              correction: settings.pinyinCorrectionEnabled)
        } else {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                SFSpeechRecognizer.requestAuthorization { _ in }
                panel.flash("Allow speech recognition, then hold Fn again")
                return
            }
            selected = SpeechTranscriber()
        }
        let token = UUID()
        session = token
        selected.onPartial = { [weak self] text in
            guard let self, self.session == token else { return }
            self.panel.setText(text)
        }
        selected.onLevel = { [weak self] level in
            guard let self, self.session == token else { return }
            self.panel.setLevel(level)
        }
        selected.onFinal = { [weak self] text in
            guard let self, self.session == token else { return }
            self.handleFinal(text)
        }
        selected.onError = { [weak self] error in
            guard let self, self.session == token else { return }
            self.transcriber?.cancel()
            self.transcriber = nil
            self.state = .idle
            self.panel.flash(error.localizedDescription)
        }
        transcriber = selected
        do {
            try selected.start(localeID: settings.languageID)
            state = .recording
            panel.show()
        } catch {
            selected.cancel()
            transcriber = nil
            NSLog("Failed to start transcription: \(error.localizedDescription)")
            panel.flash(error.localizedDescription)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .finishing
        // Audio capture is over; let the bars decay while we wait for the final result.
        panel.setLevel(0)
        if recordingEngine == .local { panel.showTranscribing() }
        transcriber?.stop()
    }

    private func handleFinal(_ text: String) {
        switch state {
        case .idle, .refining:
            return
        case .recording:
            // The recognizer died while Fn is still held; abort this session.
            transcriber?.cancel()
            transcriber = nil
            state = .idle
            panel.hide()
        case .finishing:
            transcriber = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .idle
                panel.hide()
                return
            }
            if Settings.shared.llmEnabled && refiner.isConfigured {
                state = .refining
                panel.setText(trimmed)
                panel.showRefining()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let refined = await self.refiner.refine(trimmed)
                    self.state = .idle
                    self.panel.hide()
                    self.injector.inject(refined)
                }
            } else {
                state = .idle
                panel.hide()
                injector.inject(trimmed)
            }
        }
    }

    // MARK: - Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        refreshStatusIcon()
        item.menu = buildMenu()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        if fnMonitorActive,
           let url = Bundle.main.url(forResource: "BatEcho", withExtension: "icns"),
           let logo = NSImage(contentsOf: url) {
            logo.size = NSSize(width: 18, height: 18)
            logo.isTemplate = false
            button.image = logo
        } else {
            button.image = NSImage(systemSymbolName: fnMonitorActive ? "mic.fill" : "mic.slash.fill",
                                   accessibilityDescription: "BatEcho")
            button.image?.isTemplate = true
        }
        button.setAccessibilityLabel("BatEcho")
        button.toolTip = fnMonitorActive ? "BatEcho · Hold Fn to Dictate" : "BatEcho · Accessibility Permission Needed"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(NSMenuItem(title: "About BatEcho", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(.separator())

        if fnMonitorActive {
            let hint = NSMenuItem(title: "Hold Fn to Dictate", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else {
            let warning = NSMenuItem(
                title: "Accessibility Permission Needed...",
                action: #selector(openAccessibilitySettings(_:)),
                keyEquivalent: ""
            )
            warning.target = self
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        let engineItem = NSMenuItem(title: "Speech Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        engineMenu.autoenablesItems = false
        for engine in SpeechEngine.allCases {
            let item = NSMenuItem(title: engine.title, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.rawValue
            item.state = Settings.shared.speechEngine == engine ? .on : .off
            engineMenu.addItem(item)
        }
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        let speechSettings = NSMenuItem(title: "Speech Settings…", action: #selector(openSpeechSettings(_:)), keyEquivalent: "")
        speechSettings.target = self
        menu.addItem(speechSettings)

        let languageItem = NSMenuItem(title: "Apple Speech Language", action: nil, keyEquivalent: "")
        languageItem.isEnabled = Settings.shared.speechEngine == .apple
        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        for language in Languages.all {
            let item = NSMenuItem(title: language.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.localeID
            item.state = language.localeID == Settings.shared.languageID ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        llmMenu.autoenablesItems = false
        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleLLM(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = Settings.shared.llmEnabled ? .on : .off
        llmMenu.addItem(toggle)
        llmMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings...", action: #selector(openLLMSettings(_:)), keyEquivalent: "")
        settings.target = self
        llmMenu.addItem(settings)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BatEcho", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let localeID = sender.representedObject as? String else { return }
        Settings.shared.languageID = localeID
        refreshMenu()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard state == .idle, !preparingModel,
              let value = sender.representedObject as? String,
              let engine = SpeechEngine(rawValue: value) else { return }
        Settings.shared.speechEngine = engine
        if engine == .local {
            warmLocalModel()
        } else {
            warmup?.cancel()
            Task { await localASR.shutdown() }
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
        refreshMenu()
    }

    @objc private func openSpeechSettings(_ sender: NSMenuItem) {
        speechSettingsController.show()
    }

    @objc private func toggleLLM(_ sender: NSMenuItem) {
        Settings.shared.llmEnabled.toggle()
        refreshMenu()
    }

    @objc private func openLLMSettings(_ sender: NSMenuItem) {
        settingsController.show()
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
