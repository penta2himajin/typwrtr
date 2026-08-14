import SwiftUI

@main
struct TypwrtrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var menu = MenuBarModel.shared

    var body: some Scene {
        MenuBarExtra {
            Text(menu.statusTitle)
            Text(menu.lastTextTitle)
            Divider()
            Button("Push to talk") {}
                .keyboardShortcut(menu.pttHotkey.menuKeyEquivalent, modifiers: [.control, .shift])
                .disabled(true)
            Button("Undo last insert") {
                menu.onUndoRequested?()
            }
            .disabled(!menu.canUndo)
            .keyboardShortcut("z", modifiers: [.control, .shift])
            Divider()
            Toggle(
                "Focus Dictation",
                isOn: Binding(
                    get: { menu.freeArmed },
                    set: { menu.setFocusDictationEnabled($0) }
                )
            )
            if let status = menu.focusDictationStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button(menu.setupComplete ? "Settings…" : "Finish Setup…") {
                menu.openSetup(isFirstRun: false)
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // Keep SF Symbols only for active listening (filled mic) and error.
            // Idle, processing, and any other chrome use the Typwrtr menu asset.
            if menu.symbolName == "mic.fill"
                || menu.symbolName == "exclamationmark.triangle.fill"
            {
                Image(systemName: menu.symbolName)
                    .accessibilityLabel("Typwrtr")
                    .help(menu.toolTip)
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .accessibilityLabel("Typwrtr")
                    .help(menu.toolTip)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
