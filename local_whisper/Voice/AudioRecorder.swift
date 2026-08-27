import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            return "Couldn't start recording."
        }
    }
}

final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private(set) var duration: TimeInterval = 0

    func hasMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() throws {
        cancel()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-whisper-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else { throw AudioRecorderError.failedToStart }

        self.recorder = recorder
        self.fileURL = url
        self.duration = 0
    }

    func stop() -> URL? {
        duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        return fileURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        duration = 0
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }
}
