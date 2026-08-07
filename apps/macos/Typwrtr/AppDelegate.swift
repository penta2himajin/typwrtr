import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PttCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let coordinator = PttCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        return coordinator.confirmQuitIfBusy()
    }
}
