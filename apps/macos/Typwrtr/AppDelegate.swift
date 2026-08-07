import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PttCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent-style: no Dock / no left-side app menu takeover while dictating into other apps.
        NSApp.setActivationPolicy(.accessory)

        MenuBarModel.shared.setLanguage(AppLanguage.current)
        MenuBarModel.shared.setBackendDebug("Backend: starting…")
        MenuBarModel.shared.refreshSetupStatus()

        let made = SessionFactory.makeSession()
        let coordinator = PttCoordinator(
            menu: MenuBarModel.shared,
            session: made.0,
            backend: made.1
        )
        self.coordinator = coordinator
        coordinator.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MenuBarModel.shared.presentSetupIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        return coordinator.confirmQuitIfBusy()
    }
}
