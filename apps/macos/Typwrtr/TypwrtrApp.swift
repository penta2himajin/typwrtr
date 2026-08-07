import SwiftUI

@main
struct TypwrtrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var menu = MenuBarModel.shared

    var body: some Scene {
        MenuBarExtra(menu.extraTitle, systemImage: menu.symbolName) {
            Text(menu.statusTitle)
            Text(menu.lastTextTitle)
            Divider()
            Button("Push to talk") {}
                .keyboardShortcut("d", modifiers: [.control, .shift])
                .disabled(true)
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
        }
        .menuBarExtraStyle(.menu)
    }
}
