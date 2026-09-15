import Cocoa

/// Injects text into the focused app via pasteboard + simulated Cmd+V,
/// preserving the user's clipboard and input method.
final class TextInjector {
    private(set) var isBusy = false
    private let inputSourceManager = InputSourceManager()

    func inject(_ text: String) {
        guard !text.isEmpty, !isBusy else { return }
        isBusy = true

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)
        let switchedInputSource = inputSourceManager.switchToASCIIIfCJK()

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the input-source switch and the pasteboard write a moment to settle.
        let pasteDelay: TimeInterval = switchedInputSource ? 0.15 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            Self.postCmdV()
            // Wait for the paste to be consumed before restoring anything.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if switchedInputSource {
                    self?.inputSourceManager.restoreOriginal()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    Self.restore(saved, to: pasteboard)
                    self?.isBusy = false
                }
            }
        }
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
