import Cocoa

if !FileTranscriptionCommand.runIfRequested(Array(CommandLine.arguments.dropFirst())) {
    // Top-level AppKit startup runs on the main thread.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
