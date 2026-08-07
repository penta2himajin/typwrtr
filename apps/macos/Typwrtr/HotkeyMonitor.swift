import AppKit
import Carbon.HIToolbox

/// Left Option + V hold-to-talk (ux-decisions default hotkey).
final class HotkeyMonitor {
    var onPttDown: (() -> Void)?
    var onPttUp: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var vDown = false

    func start() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handle(event)
            return event
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: handler)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        let isV = event.keyCode == UInt16(kVK_ANSI_V)

        switch event.type {
        case .keyDown where isV && optionHeld && !event.isARepeat:
            if !vDown {
                vDown = true
                onPttDown?()
            }
        case .keyUp where isV:
            if vDown {
                vDown = false
                onPttUp?()
            }
        case .flagsChanged:
            // Option released while V still notionally down.
            if vDown && !optionHeld {
                vDown = false
                onPttUp?()
            }
        default:
            break
        }
    }
}
