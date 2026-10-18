import AppKit

/// Bottom-center level bar while the mic is open: PTT hold and Focus Dictation (ux-decisions Q40).
///
/// Non-activating and click-through so it cannot pull focus off the text field.
/// No transcript and no controls.
final class ListeningIndicator {
    private var panel: NSPanel?
    private var bars: LevelBarsView?
    private var timer: Timer?
    private var appPid: pid_t = 0
    private var level: () -> Float = { 0 }
    private var smoothed: [CGFloat] = []
    private var mode: Mode = .level
    private var wavePhase: CGFloat = 0
    /// Bumped on every show / hide so a stale message timer cannot hide a newer bar.
    private var generation = 0

    private enum Mode {
        case level
        case processing
        case message
    }

    /// Mic open: live level bars.
    func show(appPid: pid_t, level: @escaping () -> Float) {
        onMain {
            self.generation += 1
            self.appPid = appPid
            self.level = level
            self.mode = .level
            self.smoothed = Array(repeating: Self.restingLevel, count: Self.barCount)
            self.present(message: nil)
            CaptureLog.note("bar show pid=\(appPid)")
        }
    }

    /// Mic closed, waiting for insert (Q41): the same bar, as a text-free wave.
    /// No-op when the bar is not up, so a path that never showed it stays quiet.
    func showProcessing() {
        onMain {
            guard let panel = self.panel, panel.isVisible, self.mode == .level else { return }
            self.level = { 0 }
            self.mode = .processing
            self.wavePhase = 0
            CaptureLog.note("bar processing")
        }
    }

    /// Short notice in the bar, then hide (Q43). Replaces whatever the bar showed.
    func flash(_ text: String, seconds: TimeInterval = 2) {
        onMain {
            self.generation += 1
            let shown = self.generation
            self.level = { 0 }
            self.mode = .message
            self.present(message: text)
            CaptureLog.note("bar flash")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if self.generation == shown { self.hide() }
            }
        }
    }

    func hide() {
        onMain {
            self.generation += 1
            self.timer?.invalidate()
            self.timer = nil
            self.level = { 0 }
            self.mode = .level
            if self.panel?.isVisible == true {
                CaptureLog.note("bar hide")
            }
            self.panel?.orderOut(nil)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func present(message: String?) {
        let panel = ensurePanel()
        bars?.message = message
        place(panel)
        panel.orderFrontRegardless()
        startTimer()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = ClickThroughPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityElement(false)

        let bars = LevelBarsView(frame: panel.contentView?.bounds ?? .zero)
        bars.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(bars)
        self.bars = bars
        self.panel = panel
        return panel
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let panel, panel.isVisible else { return }
        place(panel)
        switch mode {
        case .level:
            ingest(level())
        case .processing:
            wavePhase += 0.35
            bars?.levels = Self.wave(phase: wavePhase)
        case .message:
            break
        }
    }

    /// One soft bump travelling left to right across resting bars.
    private static func wave(phase: CGFloat) -> [CGFloat] {
        let span = CGFloat(barCount) + 4
        let center = phase.truncatingRemainder(dividingBy: span) - 2
        return (0..<barCount).map { index in
            let distance = abs(CGFloat(index) - center)
            let bump = max(0, 1 - distance / 2.5)
            return restingLevel + 0.4 * bump * bump
        }
    }

    private func ingest(_ rms: Float) {
        let target = Self.unit(rms: rms)
        let previous = smoothed.last ?? Self.restingLevel
        let next: CGFloat
        if target <= Self.restingLevel + 0.02 {
            next = previous * 0.7 + Self.restingLevel * 0.3
        } else {
            next = previous * 0.35 + target * 0.65
        }
        if !smoothed.isEmpty {
            smoothed.removeFirst()
        }
        smoothed.append(next)
        bars?.levels = smoothed
    }

    /// ~0.05 RMS fills the bars. Silence stays on a low floor.
    private static func unit(rms: Float) -> CGFloat {
        let clamped = CGFloat(min(max(rms, 0), 1))
        let curved = sqrt(clamped / 0.05)
        return min(max(curved, restingLevel), 1)
    }

    private func place(_ panel: NSPanel) {
        let screen = screenForApp() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = bars?.message.map { Self.messageWidth($0) } ?? Self.panelWidth
        let size = NSSize(width: width, height: Self.panelHeight)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 16
        )
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Screen of the dictated-into app. Window list only — no AX probe (that pips).
    private func screenForApp() -> NSScreen? {
        guard appPid != 0 else { return nil }
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        var underMouse: CGRect?
        var underMouseArea = CGFloat.greatestFiniteMagnitude
        var largest = CGRect.null
        var largestArea: CGFloat = 0
        for window in info {
            guard Self.ownerPid(window) == appPid else { continue }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0, let rect = Self.nsRect(window[kCGWindowBounds as String]) else { continue }
            let area = rect.width * rect.height
            guard area > 8_000 else { continue }
            if rect.contains(mouse), area < underMouseArea {
                underMouse = rect
                underMouseArea = area
            }
            if area > largestArea {
                largest = rect
                largestArea = area
            }
        }
        let chosen = underMouse ?? (largestArea > 0 ? largest : nil)
        guard let chosen else { return nil }
        return NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(chosen)
            let right = rhs.frame.intersection(chosen)
            return left.width * left.height < right.width * right.height
        }
    }

    private static func ownerPid(_ window: [String: Any]) -> pid_t? {
        if let number = window[kCGWindowOwnerPID as String] as? NSNumber {
            return pid_t(number.int32Value)
        }
        return nil
    }

    /// CGWindow bounds are top-left origin. Flip against the primary display.
    private static func nsRect(_ bounds: Any?) -> CGRect? {
        guard let dict = bounds as? NSDictionary else { return nil }
        var rect = CGRect.null
        guard CGRectMakeWithDictionaryRepresentation(dict, &rect),
              rect.width > 1, rect.height > 1
        else { return nil }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        guard let primary else { return nil }
        rect.origin.y = primary.frame.height - rect.origin.y - rect.height
        return rect
    }

    private static func messageWidth(_ text: String) -> CGFloat {
        let textWidth = (text as NSString).size(withAttributes: [.font: LevelBarsView.messageFont]).width
        return max(panelWidth, ceil(textWidth) + 32)
    }

    private static let barCount = 9
    private static let restingLevel: CGFloat = 0.12
    private static let panelWidth: CGFloat = 132
    private static let panelHeight: CGFloat = 28
}

private final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LevelBarsView: NSView {
    static let messageFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    var levels: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }
    var message: String? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.black.withAlphaComponent(0.82).setFill()
        pill.fill()

        if let message {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.messageFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            let size = (message as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            (message as NSString).draw(at: origin, withAttributes: attributes)
            return
        }

        guard !levels.isEmpty else { return }
        let barWidth: CGFloat = 3
        let gap: CGFloat = 5
        let count = CGFloat(levels.count)
        let total = count * barWidth + (count - 1) * gap
        var x = (bounds.width - total) / 2
        let maxH = bounds.height - 12
        let minH: CGFloat = 3
        for level in levels {
            let clamped = min(max(level, 0), 1)
            let height = minH + (maxH - minH) * clamped
            let bar = NSBezierPath(
                roundedRect: NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height),
                xRadius: 1.5,
                yRadius: 1.5
            )
            NSColor.white.withAlphaComponent(0.92).setFill()
            bar.fill()
            x += barWidth + gap
        }
    }
}
