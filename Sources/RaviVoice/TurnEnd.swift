import Foundation

// MARK: - Tipos do contrato

enum TurnEndAction: String, Codable {
    case close, wait, cancel
}

enum ConversationState: String, Codable {
    case continua, aguardando, encerrada
}

/// Limiares do D0: o gate acústico local. Não usa modelo, não usa rede.
struct D0Config: Codable {
    var outputThreshold: Double = 0.08
    var inputThreshold: Double = 0.08
    var eosQuietMs: Int = 300
    var userGuardMs: Int = 500
}

/// Política aplicada sobre a resposta semântica do Jev.
struct TurnPolicy: Codable {
    var minStateProb: Double = 0.7
    var minCompleteProb: Double = 0.5
    var explicitProb: Double = 0.55
    var waitingQuietMs: Int = 3000
}

struct TurnEndConfig: Codable {
    /// Liga o coletor. Em shadow ele só observa; nunca fecha.
    var enabled: Bool = true
    /// Shadow é o padrão. `allowLiveClose` é uma segunda trava: sem ela, nunca age.
    var shadow: Bool = true
    var allowLiveClose: Bool = false
    var url: String = "http://127.0.0.1:8791/v1/turn-end"
    /// O Jev pode passar de 800 ms em partida fria; 1,5 s ainda é fail-safe.
    var timeoutMs: Int = 1500
    /// Não manda mais de um candidato por sessão nesse intervalo.
    var minIntervalMs: Int = 2000
    /// Janela do modo sombra. O arquivo de estado guarda o início real.
    var shadowHours: Double = 72
    var d0: D0Config = D0Config()
    var policy: TurnPolicy = TurnPolicy()
}

struct TurnSignals: Codable {
    var outputLevel: Double
    var inputLevel: Double
    var msSinceAgentSpeech: Int
    var msSinceUserSpeech: Int
    var eos: Bool
    var pendingWork: Bool
    var closeRequested: Bool

    enum CodingKeys: String, CodingKey {
        case outputLevel = "output_level"
        case inputLevel = "input_level"
        case msSinceAgentSpeech = "ms_since_agent_speech"
        case msSinceUserSpeech = "ms_since_user_speech"
        case eos
        case pendingWork = "pending_work"
        case closeRequested = "close_requested"
    }
}

struct TurnSnippet: Codable {
    var role: String
    var text: String
}

struct TurnSnippets: Codable {
    var lastUser: String?
    var lastAgent: String?
    var recent: [TurnSnippet]

    enum CodingKeys: String, CodingKey {
        case lastUser = "last_user"
        case lastAgent = "last_agent"
        case recent
    }
}

struct TurnEndRequest: Codable {
    var schema: String = "ravi.turn_end.request/v1"
    var requestId: String
    var sessionId: String
    var turnId: String
    var candidateId: String
    var mode: String
    var deadlineMs: Int
    var signals: TurnSignals
    var snippets: TurnSnippets
    var policy: TurnPolicy

    enum CodingKeys: String, CodingKey {
        case schema
        case requestId = "request_id"
        case sessionId = "session_id"
        case turnId = "turn_id"
        case candidateId = "candidate_id"
        case mode
        case deadlineMs = "deadline_ms"
        case signals
        case snippets
        case policy
    }
}

struct TurnEndResponse: Codable {
    var schema: String?
    var requestId: String?
    var decision: String
    var state: ConversationState?
    var stateProb: Double?
    var podeProb: Double?
    var completeProb: Double?
    var explicitProb: Double?
    var confidence: Double?
    var reasonCode: String?
    var reason: String?
    var provider: String?
    var model: String?
    var latencyMs: Int?
    var shadow: Bool?
    var expiresInMs: Int?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case requestId = "request_id"
        case decision
        case state
        case stateProb = "state_prob"
        case podeProb = "pode_prob"
        case completeProb = "complete_prob"
        case explicitProb = "explicit_prob"
        case confidence
        case reasonCode = "reason_code"
        case reason
        case provider
        case model
        case latencyMs = "latency_ms"
        case shadow
        case expiresInMs = "expires_in_ms"
        case error
    }

    init(
        schema: String? = "ravi.turn_end.decision/v1",
        requestId: String? = nil,
        decision: String,
        state: ConversationState? = nil,
        stateProb: Double? = nil,
        podeProb: Double? = nil,
        completeProb: Double? = nil,
        explicitProb: Double? = nil,
        confidence: Double? = nil,
        reasonCode: String? = nil,
        reason: String? = nil,
        provider: String? = "jev",
        model: String? = "typesafe-ai/jev",
        latencyMs: Int? = nil,
        shadow: Bool? = true,
        expiresInMs: Int? = 1500,
        error: String? = nil
    ) {
        self.schema = schema
        self.requestId = requestId
        self.decision = decision
        self.state = state
        self.stateProb = stateProb
        self.podeProb = podeProb
        self.completeProb = completeProb
        self.explicitProb = explicitProb
        self.confidence = confidence
        self.reasonCode = reasonCode
        self.reason = reason
        self.provider = provider
        self.model = model
        self.latencyMs = latencyMs
        self.shadow = shadow
        self.expiresInMs = expiresInMs
        self.error = error
    }

    var action: TurnEndAction { TurnEndAction(rawValue: decision) ?? .wait }
}

// MARK: - D0

struct D0Detector {
    let config: D0Config

    func isCandidate(
        outputLevel: Double,
        inputLevel: Double,
        msSinceAgentSpeech: Int,
        msSinceUserSpeech: Int,
        pendingWork: Bool
    ) -> Bool {
        outputLevel < config.outputThreshold
            && inputLevel < config.inputThreshold
            && msSinceAgentSpeech >= config.eosQuietMs
            && msSinceUserSpeech >= config.userGuardMs
            && !pendingWork
    }
}

// MARK: - Política

struct TurnEndPolicyEngine {
    let config: TurnPolicy

    /// O app é a autoridade final: a resposta do Jev é conselho.
    func decide(_ response: TurnEndResponse, signals: TurnSignals) -> TurnEndAction {
        guard let state = response.state else { return .wait }
        let pode = response.podeProb ?? 0
        let complete = response.completeProb ?? 0
        let explicit = response.explicitProb ?? 0

        if state != .continua, explicit >= config.explicitProb, complete >= config.minCompleteProb {
            return .close
        }
        if state == .encerrada, pode >= config.minStateProb, complete >= config.minCompleteProb {
            return .close
        }
        if state == .aguardando,
           pode >= config.minStateProb,
           complete >= config.minCompleteProb,
           signals.msSinceAgentSpeech >= config.waitingQuietMs {
            return .close
        }
        return .wait
    }
}

// MARK: - Provedor HTTP

enum TurnEndProviderError: LocalizedError {
    case badURL
    case badStatus(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "URL do provedor inválida"
        case .badStatus(let code): return "provedor respondeu \(code)"
        case .decode(let message): return "resposta inválida: \(message)"
        }
    }
}

final class HTTPTurnEndProvider {
    private let url: URL
    private let timeout: TimeInterval

    init(config: TurnEndConfig) throws {
        guard let url = URL(string: config.url) else { throw TurnEndProviderError.badURL }
        self.url = url
        self.timeout = TimeInterval(config.timeoutMs) / 1000
    }

    func evaluate(_ request: TurnEndRequest) async throws -> TurnEndResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("\(request.sessionId)/\(request.candidateId)", forHTTPHeaderField: "Idempotency-Key")
        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TurnEndProviderError.badStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TurnEndProviderError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(TurnEndResponse.self, from: data)
        } catch {
            throw TurnEndProviderError.decode(error.localizedDescription)
        }
    }
}

// MARK: - Janela de sombra

struct ShadowWindow: Codable {
    var startedAt: Date
    var endsAt: Date
    var active: Bool
}

// MARK: - Serviço

/// Orquestra D0 -> Jev e grava o resultado. Em shadow, nunca fecha.
@MainActor
final class TurnEndService {
    private let config: TurnEndConfig
    private let provider: HTTPTurnEndProvider?
    private let d0: D0Detector
    private let policy: TurnEndPolicyEngine
    private let shadowURL: URL
    private var shadow: ShadowWindow
    private var lastCandidateAt: Date?
    private var lastCandidateID: String?
    private var lastCandidateSession: String?
    private var counter = 0

    private static let logURL = Log.dir.appendingPathComponent("turn-end.jsonl")
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(config: TurnEndConfig) {
        self.config = config
        self.provider = try? HTTPTurnEndProvider(config: config)
        self.d0 = D0Detector(config: config.d0)
        self.policy = TurnEndPolicyEngine(config: config.policy)
        self.shadowURL = Config.directory.appendingPathComponent("turn-end-shadow.json")
        self.shadow = Self.loadOrStartShadow(config: config, url: shadowURL)

        if config.enabled {
            Log.info("turn-end: shadow ativo até \(Self.iso.string(from: shadow.endsAt)) (janela \(Int(config.shadowHours))h)")
            if provider == nil { Log.error("turn-end: provedor HTTP inválido; tudo vira wait") }
        } else {
            Log.info("turn-end: desligado na config")
        }
    }

    var isShadowActive: Bool {
        guard config.enabled, shadow.active else { return false }
        return Date() < shadow.endsAt
    }

    /// O chamador só deve chamar `evaluate` quando isto for true.
    func isCandidate(_ signals: TurnSignals) -> Bool {
        d0.isCandidate(
            outputLevel: signals.outputLevel,
            inputLevel: signals.inputLevel,
            msSinceAgentSpeech: signals.msSinceAgentSpeech,
            msSinceUserSpeech: signals.msSinceUserSpeech,
            pendingWork: signals.pendingWork
        )
    }

    /// Só deve ser chamado depois que o D0 confirmou o candidato.
    @discardableResult
    func evaluate(
        sessionId: String,
        turnId: String,
        signals: TurnSignals,
        snippets: TurnSnippets
    ) async -> TurnEndResponse? {
        guard isShadowActive else { return nil }
        let now = Date()
        if let last = lastCandidateAt, now.timeIntervalSince(last) * 1000 < Double(config.minIntervalMs) {
            return nil
        }

        counter += 1
        let candidateId = "\(sessionId)-c\(counter)"
        let mode = (config.shadow || !config.allowLiveClose) ? "shadow" : "live"
        let request = TurnEndRequest(
            requestId: UUID().uuidString,
            sessionId: sessionId,
            turnId: turnId,
            candidateId: candidateId,
            mode: mode,
            deadlineMs: config.timeoutMs,
            signals: signals,
            snippets: snippets,
            policy: config.policy
        )

        lastCandidateAt = now
        lastCandidateID = candidateId
        lastCandidateSession = sessionId

        let started = Date()
        let response: TurnEndResponse
        if let provider {
            do {
                response = try await provider.evaluate(request)
            } catch {
                response = TurnEndResponse(
                    requestId: request.requestId,
                    decision: "wait",
                    reasonCode: "PROVIDER_ERROR",
                    reason: error.localizedDescription,
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                    shadow: true,
                    error: error.localizedDescription
                )
                Log.warn("turn-end: provedor falhou; wait (\(error.localizedDescription))")
            }
        } else {
            response = TurnEndResponse(
                requestId: request.requestId,
                decision: "wait",
                reasonCode: "PROVIDER_UNAVAILABLE",
                reason: "provedor HTTP não configurado",
                shadow: true
            )
        }

        let appDecision = policy.decide(response, signals: signals)
        // Trava dura: em shadow, ou sem allowLiveClose, nunca fecha por este caminho.
        let acted = (mode == "live" && config.allowLiveClose && appDecision == .close)
        writeLog([
            "type": "candidate",
            "at": Self.iso.string(from: now),
            "session": sessionId,
            "turn": turnId,
            "candidate": candidateId,
            "mode": mode,
            "d0": true,
            "signals": encode(signals),
            "snippets": encode(snippets),
            "decision": response.decision,
            "app_decision": appDecision.rawValue,
            "state": response.state?.rawValue ?? NSNull(),
            "state_prob": response.stateProb ?? NSNull(),
            "pode_prob": response.podeProb ?? NSNull(),
            "complete_prob": response.completeProb ?? NSNull(),
            "explicit_prob": response.explicitProb ?? NSNull(),
            "reason_code": response.reasonCode ?? NSNull(),
            "reason": response.reason ?? NSNull(),
            "provider": response.provider ?? NSNull(),
            "model": response.model ?? NSNull(),
            "latency_ms": response.latencyMs ?? Int(Date().timeIntervalSince(started) * 1000),
            "error": response.error ?? NSNull(),
            "acted": acted,
        ])
        return response
    }

    /// Registra a fala do usuário para a análise de sombra (reopen/corte).
    func noteUserSpeech(sessionId: String, at: Date) {
        guard isShadowActive else { return }
        let since = lastCandidateAt.map { Int(at.timeIntervalSince($0) * 1000) }
        writeLog([
            "type": "user_speech",
            "at": Self.iso.string(from: at),
            "session": sessionId,
            "candidate": lastCandidateID ?? NSNull(),
            "since_candidate_ms": since ?? NSNull(),
        ])
    }

    func noteSessionEnd(sessionId: String, reason: String) {
        guard isShadowActive else { return }
        writeLog([
            "type": "session_end",
            "at": Self.iso.string(from: Date()),
            "session": sessionId,
            "reason": reason,
        ])
    }

    private func writeLog(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        Log.writeJSONLine(line + "\n", to: Self.logURL)
    }

    private func encode<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return NSNull() }
        return object
    }

    private static func loadOrStartShadow(config: TurnEndConfig, url: URL) -> ShadowWindow {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let saved = try? decoder.decode(ShadowWindow.self, from: data) {
            return saved
        }
        let now = Date()
        let window = ShadowWindow(
            startedAt: now,
            endsAt: now.addingTimeInterval(config.shadowHours * 3600),
            active: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(window) {
            try? data.write(to: url)
        }
        return window
    }
}

private extension Log {
    /// Append de uma linha JSON no log de fim de turno. Separado do log textual.
    static func writeJSONLine(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
