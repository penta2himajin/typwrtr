import SwiftUI

@main
struct TypwrtrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var menu = MenuBarModel.shared

    var body: some Scene {
        MenuBarExtra(menu.extraTitle, systemImage: menu.symbolName) {
            Text("Typwrtr (dogfood)")
            Text(menu.statusTitle)
            Text(menu.hotkeyStatus)
            Text(menu.backendTitle)
            Text(menu.lastCaptureTitle)
            Text(menu.lastTextTitle)
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
