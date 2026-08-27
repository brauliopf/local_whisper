import SwiftUI

@main
struct local_whisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var appModel: AppModel { appDelegate.appModel }

    var body: some Scene {
        MenuBarExtra {
            AppModelSettingsBridge(appModel: appModel)

            Button("Show Encouragement") {
                appModel.showEncouragement()
            }
            .keyboardShortcut("e", modifiers: [.control, .option])

            Button("Transcribe") {
                appModel.toggleTranscription()
            }
            .keyboardShortcut("w", modifiers: [.control, .option])

            Button("Read screenshot") {
                appModel.readScreenshot()
            }
            .keyboardShortcut("r", modifiers: [.control, .option])

            Divider()

            SettingsLink()

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
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
