import Foundation

nonisolated enum OpenAIModels: Sendable {
    static func chatIDs(from ids: [String], saved: String) -> [String] {
        merged(saved: saved, into: ids.filter(isChat).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    static func transcribeIDs(from ids: [String], saved: String) -> [String] {
        merged(saved: saved, into: ids.filter(isTranscribe).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    static func merged(saved: String, into ids: [String]) -> [String] {
        if ids.contains(saved) { return ids }
        return [saved] + ids
    }

    static func isTranscribe(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("transcribe") || lower.contains("whisper")
    }

    static func isChat(_ id: String) -> Bool {
        let lower = id.lowercased()
        let excluded = ["audio", "realtime", "tts", "embedding", "dalle", "dall-e", "moderation", "transcribe", "whisper"]
        if excluded.contains(where: { lower.contains($0) }) { return false }
        return ["gpt-", "o1", "o3", "o4", "chatgpt-"].contains { lower.hasPrefix($0) }
    }
}
