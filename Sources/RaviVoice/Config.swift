import Foundation

/// User config, read from ~/.config/ravi-voice/config.json (created with defaults on first run).
struct Config: Codable {
    /// Hotkey spec. Either a lone modifier tapped by itself ("rightCommand", "rightOption",
    /// "rightShift", "rightControl", "leftCommand", "fn", ...) or a combo like "ctrl+option+space".
    var hotkey: String = "rightCommand"
    /// What the hotkey does while a session is live: "end" closes it, "mute" toggles the mic.
    var hotkeyWhileActive: String = "end"
    /// Seconds without speech (either side) or pending work before the session is closed.
    var idleTimeoutSeconds: Double = 60
    var model: String = "gpt-live-1"
    var voice: String = "marin"
    var instructions: String = Config.defaultInstructions
    /// Responses model the voice delegates reasoning/tool calls to.
    var backendModel: String = "gpt-6-luna"
    var backendInstructions: String = Config.defaultBackendInstructions
    /// Hosted web search on the backend.
    var webSearch: Bool = true
    /// Carry earlier conversations into the next one (text history, kept in
    /// ~/.config/ravi-voice/memory.json): how far back, and how much of the 8k-token limit.
    var memoryEnabled: Bool = true
    var memoryHours: Double = 12
    var memoryMaxTokens: Int = 6000
    /// Play short system sounds when the session starts/ends.
    var sounds: Bool = true
    /// Floating face + caption at the top of the screen while a session is live.
    var overlay: Bool = true
    /// Optional; otherwise OPENAI_API_KEY from the environment or ~/.ravi/.env.
    var openaiApiKey: String?
    /// Provedor externo de fim de turno (D0 local + Jev semântico).
    var turnEnd: TurnEndConfig = TurnEndConfig()
    /// Input device name as shown in System Settings › Sound › Input (nil = system default).
    /// Find exact names in Audio MIDI Setup.app or in ~/Library/Logs/RaviVoice/ravi-voice.log
    /// after a session starts. Example: "MacBook Pro Microphone", "Yeti Stereo Microphone".
    var inputDevice: String?

    /// Ravi integration through the local gateway (see README for the context key).
    var raviEnabled: Bool = true
    /// Defaults to http://RAVI_HTTP_HOST:RAVI_HTTP_PORT from ~/.ravi/.env.
    var raviGatewayURL: String?
    /// Defaults to RAVI_CONTEXT_KEY or ~/.config/ravi-voice/ravi-context.key.
    var raviContextKey: String?
    /// How many recently active sessions (and messages per session) go into the context.
    var raviRecentSessions: Int = 6
    var raviMessagesPerSession: Int = 4
    /// After sending a request to a session, hang up once the conversation goes quiet this long;
    /// the answer (on ravi.voice) reopens it. 0 disables.
    var closeAfterRequestSeconds: Double = 5
    /// Messages on ravi.voice open a conversation by themselves (with a sound) to speak.
    var wakeOnMessages: Bool = true
    /// Idle timeout for a conversation opened by an incoming message.
    var wakeIdleTimeoutSeconds: Double = 30
    /// Older inbox messages (e.g. delivered while the Mac slept) don't wake; they join the next context.
    var wakeMaxAgeMinutes: Double = 30

    static let defaultInstructions = """
    Você é o Ravi Voice, o assistente de voz pessoal que vive no Mac do usuário.
    Fale português do Brasil, de forma natural, direta e curta, como numa conversa falada.
    Não leia listas longas nem formatação; resuma. Se o usuário trocar de idioma, acompanhe.

    # Backend tools
    - Buscar na web (notícias, clima, cotações, fatos atuais).
    - Ver a data e a hora local do Mac.
    - Encerrar esta conversa quando o usuário pedir explicitamente.
    - (Mais capacidades podem estar listadas abaixo.)
    Não ofereça nada fora dessa lista: nada de lembretes, agenda ou ações no computador.

    # Delegation policy
    Delegue ao backend quando:
    - A resposta depende de informação atual, de uma ferramenta, ou de fazer uma ação.
    - O usuário confirma, corrige ou repete um pedido de ação ("sim", "pode mandar", "manda direto").
    Responda sozinho quando for cumprimento, papo, ou repetir um resultado que você já tem.
    Delegue antes de dar uma resposta que depende do backend. Não chute o resultado enquanto espera.
    Nunca diga que vai fazer ou que fez uma ação sem ter delegado ela nesse turno; se disser
    "vou fazer", delegue na mesma hora. Não peça confirmação de ações que o usuário já pediu.
    """

    static let defaultBackendInstructions = """
    You are the backend of a Portuguese (pt-BR) voice assistant running on the user's Mac.
    Use the available tools when they help. When the user asks for an action, do it with the
    tools right away: never ask for confirmation, and never answer that you will do something
    without calling the tool in this response. Keep answers short and speakable: no markdown,
    no lists, no URLs unless asked.
    """

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ravi-voice", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("config.json")

    static func load() -> Config {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: fileURL) {
            do {
                // Decode over defaults so a partial file only overrides what it sets.
                let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                var base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
                base.merge(overrides) { _, new in new }
                return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: base))
            } catch {
                Log.error("config.json inválido (\(error)); usando defaults")
                return Config()
            }
        }
        let config = Config()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Prompts stay out of the starter file so improved defaults keep applying;
        // add "instructions"/"backendInstructions" to override them.
        if let data = try? encoder.encode(config),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["instructions"] = nil
            object["backendInstructions"] = nil
            object["raviGatewayURL"] = nil
            object["raviContextKey"] = nil
            if let starter = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? starter.write(to: fileURL)
            }
        }
        Log.info("config criado em \(fileURL.path)")
        return config
    }

    /// Updates only `inputDevice` in the on-disk config, preserving all other fields.
    static func persistInputDevice(_ name: String?) {
        guard let data = try? Data(contentsOf: fileURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let name { object["inputDevice"] = name } else { object.removeValue(forKey: "inputDevice") }
        guard let saved = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? saved.write(to: fileURL)
    }

    /// API key resolution: config → environment → ~/.ravi/.env (the daemon's env file).
    func resolveApiKey() -> String? {
        if let key = openaiApiKey, !key.isEmpty { return key }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        let raviEnv = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ravi/.env")
        return Config.readDotenv(raviEnv)["OPENAI_API_KEY"]
    }

    static func readDotenv(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
