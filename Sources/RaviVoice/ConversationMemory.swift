import Foundation

/// One finished utterance of the conversation.
struct Utterance: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
    var at: Date
}

/// Turns transcript deltas into utterances. Live is full duplex and sends no end-of-turn
/// event, and both sides can talk at once, so each speaker accumulates on its own and is
/// closed after its own quiet gap: an interjection no longer splits the other side's sentence.
struct TranscriptAssembler {
    var quietGap: TimeInterval = 1.2
    private var open: [Utterance.Role: (text: String, started: Date, last: TimeInterval)] = [:]

    mutating func append(_ role: Utterance.Role, _ delta: String, now: TimeInterval, date: Date = Date()) {
        var entry = open[role] ?? (text: "", started: date, last: now)
        entry.text += delta
        entry.last = now
        open[role] = entry
    }

    func currentText(_ role: Utterance.Role) -> String? {
        open[role]?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Utterances whose speaker has been quiet for `quietGap`, oldest first.
    mutating func flushQuiet(now: TimeInterval) -> [Utterance] {
        let gap = quietGap
        return flush { now - $0.last >= gap }
    }

    mutating func flushAll() -> [Utterance] {
        flush { _ in true }
    }

    private mutating func flush(where shouldClose: ((text: String, started: Date, last: TimeInterval)) -> Bool) -> [Utterance] {
        var closed: [Utterance] = []
        for (role, entry) in open where shouldClose(entry) {
            open[role] = nil
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { closed.append(Utterance(role: role, text: text, at: entry.started)) }
        }
        return closed.sorted { $0.at < $1.at }
    }
}

/// What was said in earlier conversations, kept on disk so the next session can pick up
/// where the last one stopped (sent as `session.input` text history to GPT-Live).
final class ConversationMemory {
    static let defaultURL = Config.directory.appendingPathComponent("memory.json")
    /// GPT-Live's `input` limits: 128 messages, 8,192 combined tokens.
    static let maxMessages = 120
    static let keepOnDisk = 600

    private let url: URL
    private(set) var utterances: [Utterance] = []

    init(url: URL = ConversationMemory.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Utterance].self, from: data) {
            utterances = saved
        } else if url == Self.defaultURL {
            // First run with memory: start from what transcripts.log already has.
            utterances = Self.importTranscriptLog(Log.transcriptURL)
            if !utterances.isEmpty { save() }
        }
    }

    /// Parses `[ISO date] você|ravi: text` lines; other speakers (ravi:<session>) are skipped.
    static func importTranscriptLog(_ url: URL) -> [Utterance] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [Utterance] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let date = iso.date(from: String(line[line.index(after: line.startIndex)..<close]))
            else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let role: Utterance.Role
            if rest.hasPrefix("você: ") { role = .user } else if rest.hasPrefix("ravi: ") { role = .assistant } else { continue }
            let body = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { result.append(Utterance(role: role, text: body, at: date)) }
        }
        return Array(result.suffix(keepOnDisk))
    }

    func append(_ utterance: Utterance) {
        utterances.append(utterance)
        if utterances.count > Self.keepOnDisk { utterances.removeFirst(utterances.count - Self.keepOnDisk) }
        save()
    }

    func clear() {
        utterances.removeAll()
        save()
    }

    /// Rough token count for budgeting (pt-BR averages a bit under 4 characters per token).
    static func estimateTokens(_ text: String) -> Int { text.count / 3 + 4 }

    /// The most recent utterances within `maxAge` that fit `maxTokens`, as `session.input`
    /// messages in order, consecutive lines of one speaker merged, plus a note of how long ago
    /// the last conversation ended. Empty when there is nothing recent.
    func historyInput(now: Date = Date(), maxAge: TimeInterval, maxTokens: Int) -> [[String: Any]] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var picked: [Utterance] = []
        var budget = maxTokens - 60 // room for the note
        for utterance in utterances.reversed() where utterance.at >= cutoff {
            let cost = Self.estimateTokens(utterance.text)
            if cost > budget || picked.count >= Self.maxMessages - 1 { break }
            budget -= cost
            picked.append(utterance)
        }
        guard let last = picked.first else { return [] }
        picked.reverse()

        var merged: [Utterance] = []
        for utterance in picked {
            if let tail = merged.last, tail.role == utterance.role {
                merged[merged.count - 1].text += " " + utterance.text
            } else {
                merged.append(utterance)
            }
        }
        var messages = merged.map { utterance -> [String: Any] in
            [
                "type": "message",
                "role": utterance.role.rawValue,
                "content": [["type": utterance.role == .user ? "input_text" : "output_text", "text": utterance.text]],
            ]
        }
        let ago = RaviText.relative(last.at, now: now)
        messages.append([
            "type": "message",
            "role": "developer",
            "content": [[
                "type": "input_text",
                "text": "Acima está a conversa anterior com o usuário (terminou \(ago)). Continue de onde parou se fizer sentido; não repita nem resuma o histórico sem ser pedido.",
            ]],
        ])
        return messages
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(utterances) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
