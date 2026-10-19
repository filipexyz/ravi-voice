import Foundation
import RaviSDK

/// One session as the voice agent sees it: identity plus the last few messages, cleaned up.
struct RaviSessionDigest: Sendable, Equatable {
    struct Message: Sendable, Equatable {
        var role: String
        var text: String
        var time: Date?
    }

    var name: String
    var agentId: String?
    var displayName: String?
    var channel: String?
    var updatedAt: Date?
    var messages: [Message] = []
}

/// A reply from a Ravi session to something sent by voice.
struct RaviReply: Sendable, Equatable {
    var session: String
    var text: String
    var receivedAt: Date
}

enum RaviGatewayError: Error, CustomStringConvertible {
    case sessionNotFound(String)
    case notPublished(String)

    var description: String {
        switch self {
        case .sessionNotFound(let name): return "sessão não encontrada: \(name)"
        case .notPublished(let name): return "o Ravi não publicou a mensagem pra \(name)"
        }
    }
}

/// Talks to the local Ravi daemon through its HTTP gateway with the generated Swift SDK,
/// using a narrow context key (sessions list/recap/read/send + access:session:*).
actor RaviGateway {
    let baseURL: URL
    private let reads: RaviClient

    init(baseURL: URL, contextKey: String) {
        self.baseURL = baseURL
        reads = RaviClient(transport: HTTPTransport(baseURL: baseURL, contextKey: contextKey, timeout: 8))
    }

    /// Gateway URL: config → RAVI_GATEWAY_URL → RAVI_HTTP_HOST/PORT from ~/.ravi/.env.
    /// Key: config → RAVI_CONTEXT_KEY → ~/.config/ravi-voice/ravi-context.key.
    static func fromConfig(_ config: Config) -> RaviGateway? {
        guard config.raviEnabled else { return nil }
        let env = ProcessInfo.processInfo.environment
        let raviEnv = Config.readDotenv(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ravi/.env"))

        var urlString = config.raviGatewayURL ?? env["RAVI_GATEWAY_URL"]
        if urlString == nil, let port = raviEnv["RAVI_HTTP_PORT"] ?? raviEnv["RAVI_WEBHOOK_PORT"] {
            let host = raviEnv["RAVI_HTTP_HOST"] ?? "127.0.0.1"
            urlString = "http://\(host):\(port)"
        }
        let keyFile = Config.directory.appendingPathComponent("ravi-context.key")
        let fileKey = (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = [config.raviContextKey, env["RAVI_CONTEXT_KEY"], fileKey].compactMap { $0 }.first { !$0.isEmpty }

        guard let urlString, let url = URL(string: urlString) else {
            Log.warn("Ravi: gateway não configurado (RAVI_HTTP_PORT no ~/.ravi/.env ou raviGatewayURL)")
            return nil
        }
        guard let key else {
            Log.warn("Ravi: sem context key (\(keyFile.path)); veja o README")
            return nil
        }
        return RaviGateway(baseURL: url, contextKey: key)
    }

    // MARK: Reads

    func recentSessions(limit: Int, agent: String? = nil) async throws -> [RaviSessionDigest] {
        let result = try await reads.sessions.list(.init(
            agent: agent,
            fields: "name,agentId,displayName,channel,updatedAt",
            limit: String(limit)
        ))
        return result.items.compactMap(Self.session(from:))
    }

    func recap(_ name: String, count: Int) async throws -> RaviSessionDigest {
        let recap: SessionsRecapReturn
        do {
            recap = try await reads.sessions.recap(name, .init(count: String(count)))
        } catch {
            if String(describing: error).contains("SESSION_NOT_FOUND") { throw RaviGatewayError.sessionNotFound(name) }
            throw error
        }
        var digest = Self.session(from: recap.session.objectValue ?? [:]) ?? RaviSessionDigest(name: name)
        let items = recap.recent.objectValue?["items"]?.arrayValue ?? []
        var messages: [RaviSessionDigest.Message] = []
        for item in items {
            guard let object = item.objectValue,
                  let text = object["text"]?.stringValue.map(RaviText.clean),
                  !text.isEmpty, !RaviText.isNoise(text), messages.last?.text != text
            else { continue }
            messages.append(.init(
                role: object["role"]?.stringValue ?? "?",
                text: text,
                time: object["time"]?.stringValue.flatMap(RaviText.parseISO)
            ))
        }
        digest.messages = messages
        return digest
    }

    /// Recent sessions with their last messages, fetched concurrently.
    func digest(sessions: Int, messages: Int) async throws -> [RaviSessionDigest] {
        let recent = try await recentSessions(limit: sessions)
        return await withTaskGroup(of: (Int, RaviSessionDigest).self) { group in
            for (index, session) in recent.enumerated() {
                group.addTask {
                    let full = (try? await self.recap(session.name, count: messages)) ?? session
                    var merged = session
                    merged.messages = full.messages
                    return (index, merged)
                }
            }
            var result = [(Int, RaviSessionDigest)]()
            for await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: Writes

    /// Queues a prompt for the session and returns once it is published. The answer comes
    /// back on ravi.voice (see `RaviText.requestPrompt`), not through this call.
    func sendNoWait(_ session: String, message: String) async throws {
        do {
            let result = try await reads.sessions.send(session, message, .init(wait: false))
            guard result.published else { throw RaviGatewayError.notPublished(session) }
        } catch let error as RaviGatewayError {
            throw error
        } catch {
            if String(describing: error).contains("SESSION_NOT_FOUND") { throw RaviGatewayError.sessionNotFound(session) }
            throw error
        }
    }

    private static func session(from object: [String: RaviJSON]) -> RaviSessionDigest? {
        guard let name = object["name"]?.stringValue else { return nil }
        return RaviSessionDigest(
            name: name,
            agentId: object["agentId"]?.stringValue,
            displayName: object["displayName"]?.stringValue,
            channel: object["channel"]?.stringValue,
            updatedAt: object["updatedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

extension RaviJSON {
    var objectValue: [String: RaviJSON]? { if case .object(let v) = self { return v }; return nil }
    var arrayValue: [RaviJSON]? { if case .array(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
}

/// Text cleanup + formatting for what goes into the voice model's context.
enum RaviText {
    /// Strips Ravi's routing headers ("[session surface] …", "[WhatsApp Grupo id:… mid:…] ")
    /// so only what people actually said remains, on one line.
    static func clean(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[session surface]") { continue }
            while text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            if !text.isEmpty { lines.append(text) }
        }
        var text = lines.joined(separator: " ")
        for (pattern, replacement) in noise {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Things that read badly aloud: markdown, attachment paths, transcript markers.
    private static let noise: [(String, String)] = [
        (#"\[Audio\]\s*Transcript:\s*"#, "(áudio) "),
        (#"\[(Document|Image|Video|Sticker)[^\]]*\]"#, "[anexo]"),
        (#"\s*\bfile:\s*\S+"#, ""),
        (#"\*\*|__|`"#, ""),
        (#"\s+"#, " "),
    ]

    /// System traffic (trigger/event payloads) that says nothing to a human.
    static func isNoise(_ cleaned: String) -> Bool {
        cleaned.hasPrefix("Event:") || cleaned.hasPrefix("{")
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    static func parseISO(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "sem data" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "agora"
        case ..<60: return "há \(minutes) min"
        case ..<(60 * 24): return "há \(minutes / 60) h"
        default: return "há \(minutes / (60 * 24)) d"
        }
    }

    static func label(_ s: RaviSessionDigest) -> String {
        var parts = [s.name]
        var meta: [String] = []
        if let display = s.displayName, display != s.name { meta.append("\"\(display)\"") }
        if let agent = s.agentId { meta.append("agente \(agent)") }
        if let channel = s.channel { meta.append(channel) }
        if !meta.isEmpty { parts.append("(\(meta.joined(separator: ", ")))") }
        return parts.joined(separator: " ")
    }

    /// The message a session receives from the voice, with the implicit return instruction:
    /// answer on ravi.voice, and stay silent in the session's own chat.
    static func requestPrompt(message: String, requestId: String) -> String {
        """
        [Ravi Voice] Pedido do usuário, ditado por voz no Mac:
        \(message)

        Como responder: o usuário está esperando a resposta por voz, não no chat. Quando tiver a \
        resposta (agora ou depois de terminar o trabalho), entregue com:
        ravi voice say --execute --reply-to \(requestId) --text "<resposta curta, falável, em português>"
        Depois termine o turno respondendo só @@SILENT@@, pra não postar no chat desta sessão.
        """
    }

    /// Context for the voice model's instructions: who's active and what was said lately.
    static func voiceContext(sessions: [RaviSessionDigest], replies: [RaviReply], now: Date) -> String {
        var out = """
        # Ravi
        O usuário usa o Ravi, um runtime de agentes com várias sessões (WhatsApp, Slack, CLI…).

        # Backend tools (Ravi)
        - Listar as sessões do Ravi.
        - Ler as últimas mensagens de uma sessão.
        - Mandar uma mensagem ou pergunta pra uma sessão (o agente dela responde depois).

        # Delegation policy (Ravi)
        Delegue ao backend quando o usuário pedir pra falar, perguntar, avisar ou pedir algo a uma
        sessão ou agente do Ravi, ou quiser saber o que está rolando agora numa sessão.
        Mande direto, sem pedir confirmação. Depois de mandar, diga numa frase curta que mandou e
        que volta a falar quando a resposta chegar; a conversa fecha sozinha em seguida e reabre
        quando a resposta vier. Não invente a resposta.
        Quando chegar um comentário com uma resposta ou mensagem do Ravi, conte ao usuário na hora,
        resumindo e dizendo de qual sessão veio.
        """
        if !replies.isEmpty {
            out += "\n\n## Respostas que chegaram enquanto a conversa estava fechada (conte logo no início)\n"
            for reply in replies {
                out += "- \(reply.session) (\(relative(reply.receivedAt, now: now))): \(truncate(clean(reply.text), 500))\n"
            }
        }
        guard !sessions.isEmpty else { return out }
        out += "\n\n## Sessões mais recentes (snapshot de quando a conversa abriu; use o backend pra dados frescos)\n"
        for session in sessions {
            out += "\n### \(label(session)) — ativa \(relative(session.updatedAt, now: now))\n"
            for message in session.messages {
                let who = message.role == "user" ? "usuário" : (message.role == "assistant" ? "agente" : message.role)
                out += "- \(who): \(truncate(message.text, 260))\n"
            }
        }
        return out
    }

    /// Compact list for the backend model, so it calls tools with real session names.
    static func backendContext(sessions: [RaviSessionDigest], now: Date) -> String {
        guard !sessions.isEmpty else { return "" }
        let lines = sessions.map { "- \(label($0)), ativa \(relative($0.updatedAt, now: now))" }
        return """
        Ravi sessions most recently active (use these exact names with the ravi_* tools; call
        ravi_list_sessions for others):
        \(lines.joined(separator: "\n"))
        When the user wants to ask, tell or request something of a session, call ravi_send_message
        immediately (no confirmation), phrasing the message as the user's request. Pick the session
        by name, display name or agent; if truly ambiguous, choose the most recently active match.
        """
    }
}
