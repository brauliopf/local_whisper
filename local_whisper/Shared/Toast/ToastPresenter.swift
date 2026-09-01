import AppKit
import SwiftUI

@MainActor
final class ToastPresenter {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var dismissTask: Task<Void, Never>?
    private var currentID: AnyHashable?
    private var presentedSize: CGSize = .zero
    private var screen: NSScreen?

    func show(message: String, isError: Bool, systemImage: String? = nil, autoDismiss: Bool = true) {
        show(autoDismiss: autoDismiss) {
            ToastView(message: message, isError: isError, systemImage: systemImage)
        }
    }

    func show(
        id: AnyHashable = UUID(),
        autoDismiss: Bool = true,
        @ViewBuilder content: () -> some View
    ) {
        dismissTask?.cancel()
        currentID = id
        presentedSize = .zero
        screen = screenForCursor()

        let root = AnyView(
            ToastRoot(onSizeChange: { [weak self] size in
                self?.applySize(size)
            }) {
                content()
            }
        )

        if panel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }

        if hostingView == nil {
            let hostingView = NSHostingView(rootView: root)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            panel?.contentView = hostingView
            self.hostingView = hostingView
        } else {
            hostingView?.rootView = root
        }

        guard let panel, let hostingView else { return }

        hostingView.layoutSubtreeIfNeeded()
        applySize(hostingView.fittingSize)
        panel.orderFrontRegardless()

        guard autoDismiss else { return }

        dismissTask = Task { [id] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.hide(id: id)
        }
    }

    func hide(id: AnyHashable? = nil) {
        if let id, currentID != id { return }
        currentID = nil
        dismissTask?.cancel()
        dismissTask = nil
        presentedSize = .zero
        panel?.orderOut(nil)
    }

    private func applySize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != presentedSize else { return }
        presentedSize = size

        guard let panel, let screen else { return }
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, on: screen))
    }

    private func screenForCursor() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func origin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.minY + 80
        return NSPoint(x: x, y: y)
    }
}

private struct ToastSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 {
            value = next
        }
    }
}

private struct ToastRoot<Content: View>: View {
    var onSizeChange: (CGSize) -> Void
    var content: Content

    init(onSizeChange: @escaping (CGSize) -> Void, @ViewBuilder content: () -> Content) {
        self.onSizeChange = onSizeChange
        self.content = content()
    }

    var body: some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: ToastSizeKey.self, value: geo.size)
                }
            }
            .onPreferenceChange(ToastSizeKey.self) { size in
                guard size.width > 0, size.height > 0 else { return }
                onSizeChange(size)
            }
    }
}
