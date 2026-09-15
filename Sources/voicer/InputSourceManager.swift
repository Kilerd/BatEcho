import Carbon
import Foundation

/// Temporarily switches a CJK input method to an ASCII keyboard layout so a
/// simulated Cmd+V is not intercepted by the IME, then restores the original
/// source afterwards.
final class InputSourceManager {
    private var original: TISInputSource?

    /// Returns true when the current source is a CJK input method and the
    /// switch to an ASCII-capable layout succeeded.
    func switchToASCIIIfCJK() -> Bool {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.isCJKInputMethod(current),
              let ascii = Self.findASCIISource()
        else {
            return false
        }
        original = current
        return TISSelectInputSource(ascii) == noErr
    }

    func restoreOriginal() {
        if let original {
            TISSelectInputSource(original)
        }
        original = nil
    }

    private static func isCJKInputMethod(_ source: TISInputSource) -> Bool {
        // Plain keyboard layouts never intercept Cmd+V.
        if sourceID(of: source)?.hasPrefix("com.apple.keylayout.") == true {
            return false
        }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return false
        }
        let cfLanguages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        guard let languages = cfLanguages as NSArray as? [String],
              let primary = languages.first
        else {
            return false
        }
        return primary.hasPrefix("zh") || primary.hasPrefix("ja") || primary.hasPrefix("ko")
    }

    private static func sourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func findASCIISource() -> TISInputSource? {
        for id in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            if let unmanaged = TISCreateInputSourceList(filter, false) {
                let list = unmanaged.takeRetainedValue() as NSArray
                if list.count > 0 {
                    return (list[0] as! TISInputSource)
                }
            }
        }
        return TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
    }
}
