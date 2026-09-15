import Cocoa
import QuartzCore

/// Frameless capsule HUD shown near the bottom of the active screen while
/// recording. Non-activating, so keyboard focus stays in the target app.
final class FloatingPanel: NSPanel {
    private let root = NSView()
    private let effectView = NSVisualEffectView()
    private let waveform = WaveformView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    private let panelHeight: CGFloat = 56
    private let capsuleRadius: CGFloat = 28
    private let sidePadding: CGFloat = 18
    private let waveSize = NSSize(width: 44, height: 32)
    private let waveTextGap: CGFloat = 12
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let bottomOffset: CGFloat = 48

    /// Bumped on every show/hide so stale animation completions can bail out.
    private var generation = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        root.wantsLayer = true
        contentView = root

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        // A resizable mask image (instead of layer corner clipping) keeps the
        // window shadow matching the capsule shape.
        effectView.maskImage = Self.capsuleMask(radius: capsuleRadius)
        effectView.frame = root.bounds
        effectView.autoresizingMask = [.width, .height]
        root.addSubview(effectView)

        waveform.frame = NSRect(
            x: sidePadding,
            y: (panelHeight - waveSize.height) / 2,
            width: waveSize.width,
            height: waveSize.height
        )
        root.addSubview(waveform)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .vibrantDark)
        spinner.frame = NSRect(
            x: sidePadding + (waveSize.width - 16) / 2,
            y: (panelHeight - 16) / 2,
            width: 16,
            height: 16
        )
        root.addSubview(spinner)

        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        label.drawsBackground = false
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingHead
        label.frame = NSRect(
            x: textOriginX,
            y: (panelHeight - 22) / 2,
            width: minTextWidth,
            height: 22
        )
        label.autoresizingMask = [.width]
        root.addSubview(label)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var textOriginX: CGFloat { sidePadding + waveSize.width + waveTextGap }

    // MARK: - Public API

    func show() {
        generation += 1
        setPlaceholder("Listening...")
        spinner.stopAnimation(nil)
        waveform.isHidden = false
        waveform.reset()
        waveform.start()

        setFrame(targetFrame(forTextWidth: minTextWidth), display: true)
        alphaValue = 0
        orderFrontRegardless()

        springIn()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func setLevel(_ level: Float) {
        waveform.level = level
    }

    func setText(_ text: String) {
        guard !text.isEmpty else { return }
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        label.stringValue = text
        adjustWidth(for: text)
    }

    func showRefining() {
        waveform.stopAnimating()
        waveform.isHidden = true
        spinner.startAnimation(nil)
        label.textColor = NSColor.white.withAlphaComponent(0.55)
        if label.stringValue.isEmpty {
            label.stringValue = "Refining..."
        }
    }

    /// Shows a transient message capsule (no waveform), auto-hiding shortly.
    func flash(_ message: String) {
        generation += 1
        let currentGeneration = generation
        spinner.stopAnimation(nil)
        waveform.stopAnimating()
        waveform.isHidden = true
        setPlaceholder(message)

        setFrame(targetFrame(forTextWidth: textWidth(for: message)), display: true)
        alphaValue = 0
        orderFrontRegardless()
        springIn()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        let currentGeneration = generation
        springOut()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.orderOut(nil)
            self.waveform.stopAnimating()
            self.spinner.stopAnimation(nil)
        })
    }

    // MARK: - Layout

    private func setPlaceholder(_ text: String) {
        label.textColor = NSColor.white.withAlphaComponent(0.45)
        label.stringValue = text
    }

    private func textWidth(for text: String) -> CGFloat {
        let font = label.font ?? NSFont.systemFont(ofSize: 16, weight: .medium)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8
        return min(max(measured, minTextWidth), maxTextWidth)
    }

    private func adjustWidth(for text: String) {
        let target = targetFrame(forTextWidth: textWidth(for: text))
        guard abs(target.width - frame.width) > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }

    private func targetFrame(forTextWidth textWidth: CGFloat) -> NSRect {
        let screen = activeScreenFrame()
        let width = textOriginX + textWidth + sidePadding
        return NSRect(
            x: screen.midX - width / 2,
            y: screen.minY + bottomOffset,
            width: width,
            height: panelHeight
        )
    }

    private func activeScreenFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - Animations

    private func springIn() {
        guard let layer = root.layer else { return }
        layer.removeAllAnimations()
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: Self.centeredScale(0.7, bounds: layer.bounds))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 22
        spring.initialVelocity = 2
        spring.duration = 0.35
        layer.add(spring, forKey: "capsule")
    }

    private func springOut() {
        guard let layer = root.layer else { return }
        layer.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.toValue = NSValue(caTransform3D: Self.centeredScale(0.88, bounds: layer.bounds))
        animation.duration = 0.22
        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "capsule")
    }

    /// Scale around the layer center without touching its anchor point, so
    /// AppKit-managed layer geometry stays intact.
    private static func centeredScale(_ scale: CGFloat, bounds: CGRect) -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var transform = CATransform3DMakeTranslation(cx, cy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -cx, -cy, 0)
        return transform
    }

    private static func capsuleMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
