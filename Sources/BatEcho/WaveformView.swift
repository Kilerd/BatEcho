import Cocoa

/// Five vertical bars driven by the live audio level. Each bar chases
/// `level * weight` with a fast attack / slow release envelope plus a small
/// random jitter, so loud speech visibly pumps the bars while silence lets
/// them settle into small dots.
final class WaveformView: NSView {
    /// Live input level in 0...1, fed from audio RMS.
    var level: Float = 0

    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private static let attack: CGFloat = 0.4
    private static let release: CGFloat = 0.15
    private static let barWidth: CGFloat = 5
    private static let minBarHeight: CGFloat = 4

    private var heights = [CGFloat](repeating: 0, count: 5)
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        level = 0
        heights = [CGFloat](repeating: 0, count: 5)
        needsDisplay = true
    }

    private func step() {
        let input = CGFloat(min(max(level, 0), 1))
        for i in 0..<heights.count {
            let jitter = CGFloat.random(in: 0.96...1.04)
            let target = min(1, input * Self.weights[i] * jitter)
            let coefficient = target > heights[i] ? Self.attack : Self.release
            heights[i] += (target - heights[i]) * coefficient
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = heights.count
        let gap = (bounds.width - CGFloat(count) * Self.barWidth) / CGFloat(count - 1)
        NSColor.white.withAlphaComponent(0.92).setFill()
        for (i, value) in heights.enumerated() {
            let height = max(Self.minBarHeight, value * bounds.height)
            let x = CGFloat(i) * (Self.barWidth + gap)
            let y = (bounds.height - height) / 2
            let rect = NSRect(x: x, y: y, width: Self.barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
    }

    deinit {
        timer?.invalidate()
    }
}
