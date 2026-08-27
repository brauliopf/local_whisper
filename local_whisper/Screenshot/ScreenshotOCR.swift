import AppKit
import Foundation

@MainActor
@Observable
final class ScreenshotOCR {
    var openSettings: (() -> Void)?

    private let openAI: any OpenAIClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private var task: Task<Void, Never>?

    init(
        openAI: any OpenAIClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.openAI = openAI
        self.keychain = keychain
        self.toast = toast
    }

    func cancel() {
        task?.cancel()
        task = nil
        ScreenshotCapture.cancel()
    }

    func captureAndRead() {
        cancel()

        guard let apiKey = keychain.loadAPIKey(), !apiKey.isEmpty else {
            openSettings?()
            return
        }

        task = Task {
            if !ScreenshotCapture.hasScreenRecordingAccess {
                let granted = ScreenshotCapture.requestScreenRecordingAccess()
                guard granted else {
                    toast.show(message: "Screen Recording access is required.", isError: true)
                    return
                }
            }

            let url = await ScreenshotCapture.captureInteractive()
            guard !Task.isCancelled else { return }
            guard let url else { return }

            defer { try? FileManager.default.removeItem(at: url) }

            toast.show(message: "Reading image…", isError: false, autoDismiss: false)

            do {
                let jpeg = try Self.jpegData(from: url)
                let text = try await openAI.extractText(fromJPEG: jpeg, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                guard let text else {
                    toast.show(message: "No text found", isError: false)
                    return
                }
                Clipboard.copy(text)
                toast.show(message: "Copied to clipboard", isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toast.show(message: error.localizedDescription, isError: true)
            }
        }
    }

    private static func jpegData(from fileURL: URL) throws -> Data {
        guard
            let image = NSImage(contentsOf: fileURL),
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            throw OpenAIError.apiError("Couldn't read the screenshot.")
        }
        return data
    }
}
