import SwiftUI

@main
struct TypwrtrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var menu = MenuBarModel.shared

    var body: some Scene {
        MenuBarExtra {
            Text(menu.statusTitle)
            Text(menu.freeStatusTitle)
            Text(menu.lastTextTitle)
            Divider()
            Button("Push to talk") {}
                .keyboardShortcut("d", modifiers: [.control, .shift])
                .disabled(true)
            Button(menu.freeArmed ? "Disarm Free" : "Arm Free") {
                menu.toggleFreeArmed()
            }
            Button("Undo last insert") {
                menu.onUndoRequested?()
            }
            .disabled(!menu.canUndo)
            .keyboardShortcut("z", modifiers: [.control, .shift])
            Divider()
            Button(menu.setupComplete ? "Setup…" : "Setup… (incomplete)") {
                menu.openSetup(isFirstRun: false)
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            if menu.symbolName == "mic" {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .accessibilityLabel("Typwrtr")
                    .help(menu.toolTip)
            } else {
                Image(systemName: menu.symbolName)
                    .accessibilityLabel("Typwrtr")
                    .help(menu.toolTip)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
