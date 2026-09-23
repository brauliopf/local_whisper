import SwiftUI

struct SettingsView: View {
    private let keychain: any Keychaining

    @State private var serviceToken = ""
    @State private var backendStatusMessage: String?
    @State private var countdownMinutesText = String(TimerSettings.minutes)
    @FocusState private var countdownMinutesFocused: Bool

    init(keychain: any Keychaining = KeychainStore()) {
        self.keychain = keychain
    }

    var body: some View {
        Form {
            Section {
                SecureField("Backend service token", text: $serviceToken)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") {
                        if keychain.saveServiceToken(serviceToken) {
                            backendStatusMessage = "Saved."
                        } else {
                            backendStatusMessage = "Couldn't save the token."
                        }
                    }
                    .disabled(serviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let backendStatusMessage {
                        Text(backendStatusMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("The token is stored securely in the macOS Keychain. Voice input is English-only and is transcribed without automatic translation.")
            }

            Section {
                HStack {
                    Text("Countdown time length")
                    Spacer()
                    TextField("", text: $countdownMinutesText)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                        .focused($countdownMinutesFocused)
                        .onSubmit(commitCountdownMinutes)
                        .onChange(of: countdownMinutesText) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            guard let minutes = Int(trimmed),
                                  (TimerSettings.minMinutes...TimerSettings.maxMinutes).contains(minutes)
                            else { return }
                            TimerSettings.minutes = minutes
                        }
                    Stepper("", onIncrement: {
                        nudgeCountdownMinutes(by: 1)
                    }, onDecrement: {
                        nudgeCountdownMinutes(by: -1)
                    })
                    .labelsHidden()
                    Text("min")
                        .foregroundStyle(.secondary)
                }

                Toggle("Play sound when timer completes", isOn: Binding(
                    get: { TimerSettings.completionSoundEnabled },
                    set: { TimerSettings.completionSoundEnabled = $0 }
                ))
            } header: {
                Text("Configurations")
            } footer: {
                Text("1–1440 minutes. Applies the next time you start the timer.")
            }

            Section {
                Toggle("Store raw LLM text in telemetry", isOn: Binding(
                    get: { TelemetrySettings.rawTelemetryEnabled },
                    set: { TelemetrySettings.rawTelemetryEnabled = $0 }
                ))
            } header: {
                Text("Observability")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .onAppear {
            serviceToken = keychain.loadServiceToken() ?? ""
            countdownMinutesText = String(TimerSettings.minutes)
        }
        .onChange(of: countdownMinutesFocused) { _, focused in
            if !focused {
                commitCountdownMinutes()
            }
        }
        .onDisappear {
            commitCountdownMinutes()
        }
    }

    private func nudgeCountdownMinutes(by delta: Int) {
        let current = Int(countdownMinutesText.trimmingCharacters(in: .whitespaces)) ?? TimerSettings.minutes
        let next = TimerSettings.clamp(current + delta)
        countdownMinutesText = String(next)
    }

    private func commitCountdownMinutes() {
        let trimmed = countdownMinutesText.trimmingCharacters(in: .whitespaces)
        let parsed = Int(trimmed)
        let minutes = TimerSettings.clamp(parsed ?? TimerSettings.minutes)
        TimerSettings.minutes = minutes
        countdownMinutesText = String(minutes)
    }
}
