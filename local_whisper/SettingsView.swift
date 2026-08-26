import SwiftUI

struct SettingsView: View {
    @State private var apiKey = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            } footer: {
                Text("Your key is stored securely in the macOS Keychain.")
            }

            HStack {
                Button("Save") {
                    if KeychainService.saveAPIKey(apiKey) {
                        statusMessage = "Saved."
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
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .onAppear {
            apiKey = KeychainService.loadAPIKey() ?? ""
        }
    }
}
