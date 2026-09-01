import SwiftUI

struct ToastView<Content: View>: View {
    var isError = false
    var content: Content

    init(isError: Bool = false, @ViewBuilder content: () -> Content) {
        self.isError = isError
        self.content = content()
    }

    var body: some View {
        content
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

extension ToastView where Content == ToastMessage {
    init(message: String, isError: Bool, systemImage: String? = nil) {
        self.init(isError: isError) {
            ToastMessage(message: message, systemImage: systemImage)
        }
    }
}

struct ToastMessage: View {
    let message: String
    var systemImage: String?

    var body: some View {
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
}
