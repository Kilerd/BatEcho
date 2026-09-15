import ApplicationServices
import Cocoa
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let fnMonitor = FnKeyMonitor()
    private let transcriber = SpeechTranscriber()
    private let panel = FloatingPanel()
    private let injector = TextInjector()
    private let refiner = LLMRefiner()
    private lazy var settingsController = LLMSettingsWindowController()

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
        transcriber.requestAuthorization()
        promptForAccessibility()
        wireCallbacks()
        startFnMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor.stop()
    }

    // MARK: - Setup

    private func wireCallbacks() {
        fnMonitor.onFnDown = { [weak self] in self?.beginRecording() }
        fnMonitor.onFnUp = { [weak self] in self?.endRecording() }
        transcriber.onPartial = { [weak self] text in self?.panel.setText(text) }
        transcriber.onLevel = { [weak self] level in self?.panel.setLevel(level) }
        transcriber.onFinal = { [weak self] text in self?.handleFinal(text) }
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
            self?.startFnMonitor()
        }
    }

    private func suggestRelaunch() {
        guard !relaunchAlertShown else { return }
        relaunchAlertShown = true
        let alert = NSAlert()
        alert.messageText = "voicer cannot listen to the Fn key yet"
        alert.informativeText = """
        Accessibility looks granted, but the Fn listener still cannot start. \
        This usually happens after rebuilding the app: macOS keeps the old \
        binary's permission. In System Settings > Privacy & Security > \
        Accessibility, toggle voicer off and on (or remove and re-add it), \
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
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.3; /usr/bin/open '\(bundlePath)'"]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Recording flow

    private func beginRecording() {
        guard state == .idle, !injector.isBusy else { return }
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        guard speechAuth == .authorized || speechAuth == .notDetermined else {
            panel.flash("Speech recognition permission denied")
            return
        }
        do {
            try transcriber.start(localeID: Settings.shared.languageID)
            state = .recording
            panel.show()
        } catch {
            NSLog("Failed to start transcription: \(error.localizedDescription)")
            panel.flash(error.localizedDescription)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .finishing
        // Audio capture is over; let the bars decay while we wait for the final result.
        panel.setLevel(0)
        transcriber.stop()
    }

    private func handleFinal(_ text: String) {
        switch state {
        case .idle, .refining:
            return
        case .recording:
            // The recognizer died while Fn is still held; abort this session.
            transcriber.cancel()
            state = .idle
            panel.hide()
        case .finishing:
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
        let symbol = fnMonitorActive ? "mic.fill" : "mic.slash.fill"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "voicer")
        statusItem?.button?.image?.isTemplate = true
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

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

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
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
        menu.addItem(NSMenuItem(title: "Quit voicer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
