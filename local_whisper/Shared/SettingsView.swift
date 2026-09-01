import SwiftUI

struct SettingsView: View {
    private let keychain: any Keychaining
    private let openAI: any OpenAIClienting

    @State private var apiKey = ""
    @State private var statusMessage: String?
    @State private var chatModel = ModelSettings.chat
    @State private var transcribeModel = ModelSettings.transcribe
    @State private var chatIDs = [ModelSettings.chat]
    @State private var transcribeIDs = [ModelSettings.transcribe]
    @State private var isLoadingModels = false
    @State private var modelsError: String?
    @State private var pickersEnabled = false
    @State private var loadTask: Task<Void, Never>?
    @State private var countdownMinutesText = String(TimerSettings.minutes)
    @FocusState private var countdownMinutesFocused: Bool

    init(
        keychain: any Keychaining = KeychainStore(),
        openAI: any OpenAIClienting = OpenAIClient()
    ) {
        self.keychain = keychain
        self.openAI = openAI
    }

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") {
                        if keychain.saveAPIKey(apiKey) {
                            statusMessage = "Saved."
                            loadModels()
                        } else {
                            statusMessage = "Couldn't save the key."
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let statusMessage {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Your key is stored securely in the macOS Keychain.")
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
                    Stepper("", onIncrement: {
                        nudgeCountdownMinutes(by: 1)
                    }, onDecrement: {
                        nudgeCountdownMinutes(by: -1)
                    })
                    .labelsHidden()
                    Text("min")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Configurations")
            } footer: {
                Text("1–1440 minutes. Applies the next time you start the timer.")
            }

            Section {
                Picker("Chat", selection: $chatModel) {
                    ForEach(chatIDs, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .disabled(!pickersEnabled)

                Picker("Transcribe", selection: $transcribeModel) {
                    ForEach(transcribeIDs, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .disabled(!pickersEnabled)
            } header: {
                Text("LLM Model")
            } footer: {
                if isLoadingModels {
                    Text("Loading models…")
                } else if let modelsError {
                    Text(modelsError)
                }
            }
        }
        .formStyle(.grouped)
        .pickerStyle(.menu)
        .padding()
        .frame(width: 440)
        .onAppear {
            apiKey = keychain.loadAPIKey() ?? ""
            chatModel = ModelSettings.chat
            transcribeModel = ModelSettings.transcribe
            chatIDs = [chatModel]
            transcribeIDs = [transcribeModel]
            countdownMinutesText = String(TimerSettings.minutes)
            loadModels()
        }
        .onChange(of: countdownMinutesFocused) { _, focused in
            if !focused {
                commitCountdownMinutes()
            }
        }
        .onChange(of: chatModel) { _, newValue in
            ModelSettings.chat = newValue
        }
        .onChange(of: transcribeModel) { _, newValue in
            ModelSettings.transcribe = newValue
        }
        .onDisappear {
            commitCountdownMinutes()
            loadTask?.cancel()
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

    private func loadModels() {
        loadTask?.cancel()

        guard let key = keychain.loadAPIKey(), !key.isEmpty else {
            isLoadingModels = false
            modelsError = nil
            pickersEnabled = false
            chatIDs = [ModelSettings.chat]
            transcribeIDs = [ModelSettings.transcribe]
            return
        }

        isLoadingModels = true
        modelsError = nil
        pickersEnabled = false

        loadTask = Task {
            defer { isLoadingModels = false }
            do {
                let ids = try await openAI.listModels(apiKey: key)
                guard !Task.isCancelled else { return }
                chatIDs = OpenAIModels.chatIDs(from: ids, saved: ModelSettings.chat)
                transcribeIDs = OpenAIModels.transcribeIDs(from: ids, saved: ModelSettings.transcribe)
                pickersEnabled = true
            } catch {
                guard !Task.isCancelled else { return }
                chatIDs = OpenAIModels.merged(saved: ModelSettings.chat, into: [])
                transcribeIDs = OpenAIModels.merged(saved: ModelSettings.transcribe, into: [])
                modelsError = error.localizedDescription
                pickersEnabled = true
            }
        }
    }
}
