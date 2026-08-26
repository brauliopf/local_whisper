import SwiftUI

@main
struct local_whisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var appModel: AppModel { appDelegate.appModel }

    var body: some Scene {
        MenuBarExtra {
            AppModelSettingsBridge(appModel: appModel)

            Button("Show Encouragement    ⌃⌥E") {
                appModel.showEncouragement()
            }

            Divider()

            SettingsLink()

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

private struct AppModelSettingsBridge: View {
    @Bindable var appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appModel.openSettings = { openSettings() }
            }
    }
}
