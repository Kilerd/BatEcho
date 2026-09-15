import Carbon.HIToolbox
import Cocoa

/// Watches the Fn key globally through a CGEvent tap.
///
/// The bare Fn `flagsChanged` events are swallowed (the callback returns nil)
/// so that the system emoji picker / dictation shortcut never triggers while
/// the key is used for push-to-talk. Key events pressed together with Fn are
/// not affected: they arrive as separate events that still carry the Fn flag.
final class FnKeyMonitor {
    var onFnDown: (@MainActor () -> Void)?
    var onFnUp: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false

    /// Returns false when the tap cannot be created, which usually means the
    /// Accessibility permission has not been granted yet.
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function)
        else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = event.flags.contains(.maskSecondaryFn)
        if isDown != fnIsDown {
            fnIsDown = isDown
            let callback = isDown ? onFnDown : onFnUp
            // Leave the tap callback quickly; heavy work happens on the next runloop turn.
            DispatchQueue.main.async { callback?() }
        }

        // Swallow the bare Fn event so the system emoji picker never fires.
        return nil
    }
}
