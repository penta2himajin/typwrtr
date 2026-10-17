import AppKit

/// Bottom-center level bar while Focus Dictation's mic is open (ux-decisions Q40).
///
/// Non-activating and click-through so it cannot pull focus off the text field.
/// No transcript and no controls.
final class FocusListeningIndicator {
    private var panel: NSPanel?
    private var bars: LevelBarsView?
    private var timer: Timer?
    private var appPid: pid_t = 0
    private var level: () -> Float = { 0 }
    private var smoothed: [CGFloat] = []

    func show(appPid: pid_t, level: @escaping () -> Float) {
        let present = {
            self.appPid = appPid
            self.level = level
            self.smoothed = Array(repeating: Self.restingLevel, count: Self.barCount)
            let panel = self.ensurePanel()
            self.place(panel)
            panel.orderFrontRegardless()
            self.startTimer()
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    func hide() {
        let dismiss = {
            self.timer?.invalidate()
            self.timer = nil
            self.level = { 0 }
            self.panel?.orderOut(nil)
        }
        if Thread.isMainThread {
            dismiss()
        } else {
            DispatchQueue.main.async(execute: dismiss)
        }
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
        ingest(level())
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
        let size = NSSize(width: Self.panelWidth, height: Self.panelHeight)
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
    var levels: [CGFloat] = [] {
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
