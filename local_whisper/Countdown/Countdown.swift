import Foundation
import SwiftUI

@MainActor
@Observable
final class Countdown {
    private(set) var remainingLabel: String?
    private(set) var isRunning = false

    private static let toastID = "countdown"

    private let toast: ToastPresenter
    private var deadline: Date?
    private var tickTask: Task<Void, Never>?

    init(toast: ToastPresenter) {
        self.toast = toast
    }

    func handleHotkey() {
        if isRunning {
            syncFromDeadline()
            guard remainingLabel != nil else { return }
            toast.show(id: Self.toastID) {
                ToastView {
                    ToastLabel(countdown: self)
                }
            }
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }

        deadline = Date().addingTimeInterval(TimerSettings.duration)
        isRunning = true
        syncFromDeadline()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.syncFromDeadline()
            }
        }
    }

    func cancel() {
        tickTask?.cancel()
        tickTask = nil
        deadline = nil
        remainingLabel = nil
        isRunning = false
        toast.hide(id: Self.toastID)
    }

    func refresh() {
        syncFromDeadline()
    }

    private func syncFromDeadline() {
        guard let deadline else {
            remainingLabel = nil
            isRunning = false
            return
        }

        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            complete()
            return
        }

        remainingLabel = Self.format(remaining)
    }

    private func complete() {
        guard isRunning else { return }
        tickTask?.cancel()
        tickTask = nil
        deadline = nil
        remainingLabel = nil
        isRunning = false
        toast.show(message: "Timer complete", isError: false, systemImage: "checkmark")
    }

    fileprivate static func format(_ remaining: TimeInterval) -> String {
        let seconds = Int(ceil(remaining))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ToastLabel: View {
    @Bindable var countdown: Countdown

    var body: some View {
        Text(countdown.remainingLabel ?? "0:00")
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
