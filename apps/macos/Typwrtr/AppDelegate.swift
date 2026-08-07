import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PttCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent-style: no Dock / no left-side app menu takeover while dictating into other apps.
        NSApp.setActivationPolicy(.accessory)

        MenuBarModel.shared.setBackend("ASR: starting…")

        // Build session + wire hotkey on the main queue promptly so ⌃⇧D works
        // without waiting on a background hop (Whisper path is still usually quick).
        let made = SessionFactory.makeSession()
        let coordinator = PttCoordinator(
            menu: MenuBarModel.shared,
            session: made.0,
            backend: made.1
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        return coordinator.confirmQuitIfBusy()
    }
}
