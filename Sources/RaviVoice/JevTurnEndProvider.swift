import Foundation

/// Chamada nativa ao Jev, sem sidecar.
///
/// Dois caminhos:
/// - `vercel`: AI Gateway (`/v4/ai/evaluation-model`), chave `AI_GATEWAY_API_KEY`,
///   modelo `typesafe-ai/jev`, headers `ai-gateway-*`.
/// - `typesafe`/`jev`: API direta (`/v1/systemone`), chave `TYPESAFE_API_KEY`,
///   modelo `jev-1.13.0` (ou `jev-latest`), perguntas booleanas no tipo `noul`.
///
/// A chave é resolvida do config, do ambiente ou de `jev.env`/`~/.ravi/.env`.
/// Sem chave, o init devolve nil e o app não usa o Jev.
final class JevTurnEndProvider {
    enum Style: String {
        case vercel
        case typesafe
    }

    struct Resolved {
        let style: Style
        let baseURL: URL
        let model: String
        let apiKey: String
        let keyEnv: String
        let timeout: TimeInterval
    }

    let resolved: Resolved

    init?(config: TurnEndConfig) {
        let provider = config.provider.lowercased()
        let style: Style
        switch provider {
        case "typesafe", "jev", "systemone", "direct":
            style = .typesafe
        default:
            style = .vercel
        }

        let defaultBase: String
        let defaultModel: String
        let defaultKeyEnv: String
        switch style {
        case .vercel:
            defaultBase = "https://ai-gateway.vercel.sh/v4/ai/evaluation-model"
            defaultModel = "typesafe-ai/jev"
            defaultKeyEnv = "AI_GATEWAY_API_KEY"
        case .typesafe:
            defaultBase = "https://api.typesafe.ai/v1/systemone"
            defaultModel = "jev-1.13.0"
            defaultKeyEnv = "TYPESAFE_API_KEY"
        }

        guard let url = URL(string: config.baseURL?.isEmpty == false ? config.baseURL! : defaultBase) else {
            Log.error("turn-end: baseURL inválida (\(config.baseURL ?? defaultBase))")
            return nil
        }
        let model = config.model?.isEmpty == false ? config.model! : defaultModel
        let keyEnv = config.apiKeyEnv?.isEmpty == false ? config.apiKeyEnv! : defaultKeyEnv
        guard let key = Self.resolveKey(config: config, env: keyEnv), !key.isEmpty else {
            Log.info("turn-end: sem chave \(keyEnv) para provider \(style.rawValue)")
            return nil
        }

        self.resolved = Resolved(
            style: style,
            baseURL: url,
            model: model,
            apiKey: key,
            keyEnv: keyEnv,
            timeout: TimeInterval(config.timeoutMs) / 1000
        )
    }

    func evaluate(_ request: TurnEndRequest) async throws -> TurnEndResponse {
        let started = Date()
        var req = URLRequest(url: resolved.baseURL)
        req.httpMethod = "POST"
        req.timeoutInterval = resolved.timeout
        req.setValue("Bearer \(resolved.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("\(request.sessionId)/\(request.candidateId)", forHTTPHeaderField: "Idempotency-Key")

        if resolved.style == .vercel {
            req.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
            req.setValue("4", forHTTPHeaderField: "ai-evaluation-model-specification-version")
            req.setValue(resolved.model, forHTTPHeaderField: "ai-model-id")
        }

        let body = Self.body(for: request, style: resolved.style, model: resolved.model)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw JevProviderError.badStatus(-1, "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw JevProviderError.badStatus(http.statusCode, String(text))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevProviderError.decode("JSON inválido")
        }
        return try Self.parse(json, request: request, resolved: resolved, started: started)
    }

    // MARK: - Corpo da pergunta

    private static func body(for request: TurnEndRequest, style: Style, model: String) -> [String: Any] {
        let recent = request.snippets.recent.map { ["role": $0.role, "text": $0.text] }
        let state: [String: Any] = [
            "canal": "voz",
            "conversa_recente": recent,
            "ultima_fala_do_agente": request.snippets.lastAgent ?? "",
            "agente_ainda_falando": false,
            "silencio_desde_o_fim_da_fala_ms": request.signals.msSinceAgentSpeech,
        ]

        let boolType = style == .vercel ? "boolean" : "noul"
        let questions: [String: Any] = [
            "estado_da_conversa": [
                "type": "choice",
                "instructions":
                    "Classifique o estado da conversa DE VOZ imediatamente depois da última fala do agente. " +
                    "O áudio do agente já terminou e está em silêncio. Escolha uma única opção.",
                "criteria": [
                    "continua":
                        "O agente fez uma pergunta direta, um convite para continuar, ou deixou uma pausa no meio de um assunto. " +
                        "O usuário deve falar de novo para a conversa funcionar.",
                    "aguardando":
                        "O agente prometeu voltar com uma resposta, ação ou confirmação (por exemplo: 'te aviso', 'vou pedir', " +
                        "'já mandei', 'te conto quando responder'). O próximo evento esperado é do agente, não uma fala do usuário.",
                    "encerrada":
                        "O agente se despediu, confirmou o encerramento, ou o usuário pediu para desligar e o agente concordou. " +
                        "Nada mais é esperado nesta conversa.",
                ],
            ],
            "fala_completa": [
                "type": boolType,
                "instructions":
                    "A última fala do agente termina uma ideia completa? Responda não se o texto foi cortado no meio de uma " +
                    "frase, termina em reticências, ou é claramente um fragmento.",
            ],
            "pedido_de_encerramento": [
                "type": boolType,
                "instructions":
                    "O usuário pediu explicitamente para desligar, encerrar, fechar ou terminar a conversa AGORA? " +
                    "Não conte pedidos hipotéticos ('se eu pedir para desligar'), pedidos de encerrar outra coisa, " +
                    "nem despedidas casuais sem intenção de encerrar.",
            ],
        ]

        if style == .typesafe {
            return ["state": state, "model": model, "questions": questions]
        }
        return ["state": state, "questions": questions]
    }

    // MARK: - Resposta

    private static func parse(
        _ json: [String: Any],
        request: TurnEndRequest,
        resolved: Resolved,
        started: Date
    ) throws -> TurnEndResponse {
        let answers = (json["answers"] as? [String: Any]) ?? json
        let stateAnswer = answers["estado_da_conversa"] as? [String: Any] ?? [:]
        let choiceText = stateAnswer["choice"] as? String
        let choice = choiceText.flatMap(ConversationState.init(rawValue:))
        let probabilities = stateAnswer["probabilities"] as? [String: Any] ?? [:]
        let stateProb = choiceText.flatMap { number(probabilities[$0]) }
        let podeProb = (number(probabilities["encerrada"]) ?? 0) + (number(probabilities["aguardando"]) ?? 0)
        let complete = probability(answers["fala_completa"])
        let explicit = probability(answers["pedido_de_encerramento"])

        var confidence = number(stateAnswer["confidence"])
        if confidence == nil,
           let metadata = json["providerMetadata"] as? [String: Any],
           let typesafe = metadata["typesafe"] as? [String: Any],
           let conf = typesafe["confidence"] as? [String: Any] {
            confidence = number(conf["estado_da_conversa"])
        }

        return TurnEndResponse(
            requestId: request.requestId,
            decision: "wait",
            state: choice,
            stateProb: stateProb,
            podeProb: podeProb,
            completeProb: complete,
            explicitProb: explicit,
            confidence: confidence,
            reasonCode: nil,
            reason: nil,
            provider: resolved.style.rawValue,
            model: resolved.model,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            shadow: request.mode != "live",
            expiresInMs: 1500
        )
    }

    private static func probability(_ answer: Any?) -> Double? {
        guard let dict = answer as? [String: Any] else { return nil }
        return number(dict["probability"]) ?? number(dict["noul"])
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    // MARK: - Chave

    private static func resolveKey(config: TurnEndConfig, env: String) -> String? {
        if let key = config.apiKey, !key.isEmpty { return key }
        let names = env == "JEV_API_KEY" ? [env] : [env, "JEV_API_KEY"]
        for name in names {
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        }
        let files = [
            Config.directory.appendingPathComponent("jev.env"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ravi/.env"),
        ]
        for file in files {
            let values = Config.readDotenv(file)
            for name in names {
                if let value = values[name], !value.isEmpty { return value }
            }
        }
        return nil
    }
}

enum JevProviderError: LocalizedError {
    case badStatus(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "Jev respondeu \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .decode(let message):
            return "resposta do Jev inválida: \(message)"
        }
    }
}
