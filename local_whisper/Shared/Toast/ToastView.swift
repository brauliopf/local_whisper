import SwiftUI

struct ToastView: View {
    let message: String
    var isError = false
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                HStack(spacing: 8) {
                    Text(message)
                        .lineLimit(1)
                    Image(systemName: systemImage)
                }
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(isError ? Color.red : Color.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}
