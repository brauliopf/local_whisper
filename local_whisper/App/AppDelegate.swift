import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var statusItem: StatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            statusItem = StatusItem(coordinator: coordinator)
            coordinator.finishLaunching()
        }
    }
}
