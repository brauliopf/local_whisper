import SwiftUI

@main
struct local_whisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var coordinator: AppCoordinator { appDelegate.coordinator }

    var body: some Scene {
        MenuBarExtra {
            CoordinatorSettingsBridge(coordinator: coordinator)

            Button("Show Encouragement") {
                coordinator.showEncouragement()
            }
            .keyboardShortcut("e", modifiers: [.control, .option])

            Button("Transcribe") {
                coordinator.toggleTranscription()
            }
            .keyboardShortcut("w", modifiers: [.control, .option])

            Button("Read screenshot") {
                coordinator.readScreenshot()
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

private struct CoordinatorSettingsBridge: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                coordinator.openSettings = { openSettings() }
            }
    }
}
