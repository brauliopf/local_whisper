import SwiftUI

struct ToastView: View {
    let message: String
    let isError: Bool
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(isError ? Color.red : Color.primary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 400)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}
