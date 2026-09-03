import Foundation
import OSLog

enum TelemetryScope {
    @TaskLocal static var context: TelemetryContext?
}

struct TelemetryContext: Sendable {
    let traceID: String
    let parentSpanID: String?
    let operation: String
    let trigger: String
    let rawPayloadsEnabled: Bool
}

struct TelemetrySpan: Sendable {
    let context: TelemetryContext
    let spanID: String
    let name: String
    let kind: String
    let start: Date
    let startUptime: ContinuousClock.Instant
    let model: String?
    let request: [String: String]
}

struct TelemetryRecord: Encodable, Sendable {
    let schemaVersion = 1
    let recordType = "span"
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let name: String
    let kind: String
    let startTime: Date
    let endTime: Date
    let durationMS: Int
    let status: String
    let error: String?
    let application: Application
    let operation: Operation
    let llm: LLM?
    let attributes: [String: String]
    let request: [String: Payload]
    let response: [String: Payload]
    let events: [Event]

    struct Payload: Encodable, Sendable {
        let value: String?
        let truncated: Bool
        let originalBytes: Int
        let storedBytes: Int
        let marker: String?

        enum CodingKeys: String, CodingKey {
            case value, truncated
            case originalBytes = "original_bytes"
            case storedBytes = "stored_bytes"
            case marker
        }
    }

    struct Application: Encodable, Sendable {
        let name = "local-whisper"
        let version: String
    }

    struct Operation: Encodable, Sendable {
        let name: String
        let trigger: String
    }

    struct LLM: Encodable, Sendable {
        let provider = "openai"
        let model: String
        let operationName: String
        let httpStatus: Int?
        let inputTokens: Int?
        let outputTokens: Int?
    }

    struct Event: Encodable, Sendable {
        let name: String
        let attributes: [String: String]
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordType = "record_type"
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case name, kind
        case startTime = "start_time"
        case endTime = "end_time"
        case durationMS = "duration_ms"
        case status, error, application, operation, llm, attributes, request, response, events
    }
}

actor LocalTelemetry {
    static let shared = LocalTelemetry()

    private let fileURL: URL
    private let logger = Logger(subsystem: "brauliopf.local-whisper", category: "telemetry")
    private let encoder: JSONEncoder
    private var currentDate: String?

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local-whisper", isDirectory: true)
        fileURL = support.appendingPathComponent("telemetry.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func prepare() {
        let date = Self.dateString()
        guard currentDate != date else { return }
        currentDate = date

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL, options: .atomic)
            } else {
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            logger.error("Unable to prepare telemetry file: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(
        name: String,
        operation: String,
        trigger: String,
        kind: String = "internal",
        model: String? = nil,
        request: [String: String] = [:],
        context: TelemetryContext? = nil
    ) -> TelemetrySpan {
        let context = context ?? TelemetryContext(
            traceID: Self.hexID(length: 32),
            parentSpanID: nil,
            operation: operation,
            trigger: trigger,
            rawPayloadsEnabled: ModelSettings.rawTelemetryEnabled
        )
        return TelemetrySpan(
            context: context,
            spanID: Self.hexID(length: 16),
            name: name,
            kind: kind,
            start: Date(),
            startUptime: ContinuousClock.now,
            model: model,
            request: request
        )
    }

    func finish(
        _ span: TelemetrySpan,
        status: String = "ok",
        error: String? = nil,
        response: [String: String] = [:],
        attributes: [String: String] = [:],
        httpStatus: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        let end = Date()
        let duration = span.startUptime.duration(to: .now)
        let milliseconds = max(0, Int(duration.components.attoseconds / 1_000_000_000_000_000))
            + max(0, Int(duration.components.seconds) * 1_000)
        let record = TelemetryRecord(
            traceID: span.context.traceID,
            spanID: span.spanID,
            parentSpanID: span.context.parentSpanID,
            name: span.name,
            kind: span.kind,
            startTime: span.start,
            endTime: end,
            durationMS: milliseconds,
            status: status,
            error: error,
            application: .init(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            operation: .init(name: span.context.operation, trigger: span.context.trigger),
            llm: span.model.map {
                .init(
                    model: $0,
                    operationName: span.name,
                    httpStatus: httpStatus,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                )
            },
            attributes: attributes,
            request: payload(span.request, enabled: span.context.rawPayloadsEnabled),
            response: payload(response, enabled: span.context.rawPayloadsEnabled),
            events: []
        )
        append(record)
    }

    func childContext(from span: TelemetrySpan) -> TelemetryContext {
        TelemetryContext(
            traceID: span.context.traceID,
            parentSpanID: span.spanID,
            operation: span.context.operation,
            trigger: span.context.trigger,
            rawPayloadsEnabled: span.context.rawPayloadsEnabled
        )
    }

    private func append(_ record: TelemetryRecord) {
        prepare()
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: [.atomic])
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
        } catch {
            logger.error("Unable to write telemetry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func payload(_ values: [String: String], enabled: Bool) -> [String: TelemetryRecord.Payload] {
        guard enabled else {
            return values.reduce(into: [:]) { result, item in
                result[item.key] = .init(
                    value: nil,
                    truncated: false,
                    originalBytes: item.value.utf8.count,
                    storedBytes: 0,
                    marker: nil
                )
            }
        }
        return values.reduce(into: [:]) { result, item in
            let bytes = Array(item.value.utf8)
            let originalBytes = bytes.count
            let storedBytes = min(originalBytes, 307_200)
            result[item.key] = .init(
                value: String(decoding: bytes.prefix(storedBytes), as: UTF8.self),
                truncated: originalBytes > storedBytes,
                originalBytes: originalBytes,
                storedBytes: storedBytes,
                marker: originalBytes > storedBytes ? "[TRUNCATED]" : nil
            )
        }
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func hexID(length: Int) -> String {
        String(UUID().uuidString.filter { $0 != "-" }.lowercased().prefix(length))
    }
}
