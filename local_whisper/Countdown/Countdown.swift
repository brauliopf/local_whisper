import Foundation

@MainActor
@Observable
final class Countdown {
    static let duration: TimeInterval = 20 * 60

    private(set) var remainingLabel: String?
    private(set) var isRunning = false

    private let toast: ToastPresenter
    private var deadline: Date?
    private var tickTask: Task<Void, Never>?

    init(toast: ToastPresenter) {
        self.toast = toast
    }

    func handleHotkey() {
        if isRunning {
            syncFromDeadline()
            if let remainingLabel {
                toast.show(message: remainingLabel, isError: false)
            }
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }

        deadline = Date().addingTimeInterval(Self.duration)
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

    private static func format(_ remaining: TimeInterval) -> String {
        let seconds = Int(ceil(remaining))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
