import Foundation

@MainActor
@Observable
final class Countdown {
    private(set) var remainingLabel: String?
    private(set) var isRunning = false

    private let toast: ToastPresenter
    private var deadline: Date?
    private var tickTask: Task<Void, Never>?

    init(toast: ToastPresenter) {
        self.toast = toast
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
        setRemaining(nil)
        isRunning = false
    }

    private func syncFromDeadline() {
        guard let deadline else {
            setRemaining(nil)
            isRunning = false
            return
        }

        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            complete()
            return
        }

        setRemaining(Self.format(remaining))
    }

    private func complete() {
        guard isRunning else { return }
        tickTask?.cancel()
        tickTask = nil
        deadline = nil
        setRemaining(nil)
        isRunning = false
        toast.show(message: "Timer complete", isError: false, systemImage: "checkmark")
    }

    private func setRemaining(_ value: String?) {
        guard remainingLabel != value else { return }
        remainingLabel = value
    }

    private static func format(_ remaining: TimeInterval) -> String {
        let seconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
