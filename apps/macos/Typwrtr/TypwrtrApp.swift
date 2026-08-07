import SwiftUI

@main
struct TypwrtrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var menu = MenuBarModel.shared

    var body: some Scene {
        MenuBarExtra(menu.extraTitle, systemImage: menu.symbolName) {
            Text(menu.statusTitle)
            Text(menu.hotkeyStatus)
            Text(menu.lastTextTitle)
            Divider()
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
            Menu("Debug") {
                Text(menu.languageTitle)
                Text(menu.backendDebugTitle)
                Text(menu.lastCaptureTitle)
                Divider()
                Button("Use model folder…") {
                    menu.pickModelFolder()
                }
                Button("Copy fetch-models command") {
                    menu.copyFetchCommand()
                }
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
