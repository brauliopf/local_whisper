import SwiftUI

struct GroceryRequestView: View {
    @State private var request = ""
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add grocery item")
                .font(.title2.weight(.semibold))
            Text("Describe one item to add to the dedicated Instacart cart. Checkout is not performed.")
                .foregroundStyle(.secondary)
            TextField("e.g. organic apples", text: $request)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Search", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func submit() {
        let value = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSubmit(value)
    }
}
