import SwiftUI

struct BrowserPlanPreview: View {
    let goal: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview Plan")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Goal")
                    .font(.headline)
                Text(goal)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Returned Playwright code")
                    .font(.headline)
                ScrollView([.vertical, .horizontal]) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 500)
    }
}
