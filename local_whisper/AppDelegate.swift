import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            appModel.finishLaunching()
        }
    }
}
