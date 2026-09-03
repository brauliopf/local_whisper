import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var statusItem: StatusItem?

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = StatusItem(coordinator: coordinator)
        coordinator.finishLaunching()
    }
}
