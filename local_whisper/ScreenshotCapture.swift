import CoreGraphics
import Foundation

enum ScreenshotCapture {
    private static var runningProcess: Process?

    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func cancel() {
        runningProcess?.terminate()
        runningProcess = nil
    }

    /// Interactive system picker (`screencapture -i`). Nil if cancelled or failed.
    static func captureInteractive() async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-whisper-\(UUID().uuidString).png")

        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", url.path]
                do {
                    runningProcess = process
                    try process.run()
                    process.waitUntilExit()
                    runningProcess = nil
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    runningProcess = nil
                    continuation.resume(returning: -1)
                }
            }
        }

        guard status == 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}
