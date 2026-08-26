import AppKit
import SwiftUI

@MainActor
final class ToastPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ToastView>?
    private var dismissTask: Task<Void, Never>?

    func show(message: String, isError: Bool) {
        dismissTask?.cancel()

        let screen = screenForCursor()
        let toastView = ToastView(message: message, isError: isError)

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
            let hostingView = NSHostingView(rootView: toastView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            panel?.contentView = hostingView
            self.hostingView = hostingView
        } else {
            hostingView?.rootView = toastView
        }

        guard let panel, let hostingView else { return }

        let size = hostingView.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, on: screen))
        panel.orderFrontRegardless()

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
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
