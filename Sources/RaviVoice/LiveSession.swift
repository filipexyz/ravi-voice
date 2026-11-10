import Foundation

/// One GPT-Live voice session over WebSocket (wss://api.openai.com/v1/live/sessions).
///
/// Lifecycle: `start()` → session.start → session.started → stream mic audio → … →
/// `close()` (hotkey, idle timeout) → session.close → session.closed → teardown.
/// Backend work uses Responses delegation; function calls are run by `ToolRegistry`.
@MainActor
final class LiveSession {
    enum State: Equatable {
        case idle, connecting, live, closing
    }

    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    /// Output frames quieter than this count as silence (the model streams silence continuously).
    static let speechPeakThreshold = 300

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            activity?.sessionState = state
            onStateChange?(state)
        }
    }
    /// UI state for the overlay face.
    var activity: VoiceActivity?
    private(set) var isMuted = false
    var onStateChange: ((State) -> Void)?
    /// Called once per closed session with the reason ("idle", "hotkey", "expired", an error…).
    var onEnded: ((String) -> Void)?

    private let config: Config
    private let apiKey: String
    private let tools: ToolRegistry
    private let audio: AudioIO
    let protectsObserverAnnouncement: Bool
    private let announcementGate: ObserverAnnouncementGate?
    private let urlSession = URLSession(configuration: .default)

    private var socket: URLSessionWebSocketTask?
    private var sessionId: String?
    private var idle: IdleTracker
    private var idleTimer: Timer?
    private var closeTimeout: Timer?
    private var endReason = "closed"

    /// Function calls emitted per delegation, run once that delegation's response completes.
    private var pendingCalls: [String: [(callId: String, task: Task<String, Never>)]] = [:]
    private var transcript = TranscriptAssembler()
    /// Earlier conversations: sent as `session.input`, and every finished utterance is added.
    private let memory: ConversationMemory?
    private let history: [[String: Any]]

    /// Shadow collector: D0 + provedor externo. Nunca fecha em shadow.
    private let turnEnd: TurnEndService?
    private let gate: TurnEndGate
    private var turnEndTimer: Timer?
    private var lastOutputSpeechAt: TimeInterval = 0
    private var lastInputSpeechAt: TimeInterval = 0
    /// Último delta de transcrição; o candidato espera o texto assentar para não mandar snippet cortado.
    private var lastTranscriptAt: TimeInterval = 0
    private var candidateArmed = false
    private var turnCounter = 0
    /// Reavaliação após um close adiado pelo gate (não cancela de vez).
    private var recheckWork: DispatchWorkItem?
    private var recheckUntil: TimeInterval = 0
    private var nextCandidateAllowedAt: TimeInterval = 0
    private var recentUtterances: [Utterance] = []

    /// Mic chunks are produced on the audio thread; this gate is read there.
    private let audioGate = AudioGate()

    /// Extra context appended to the voice and backend instructions (Ravi snapshot).
    private let voiceContext: String
    private let backendContext: String

    /// Said right after the session starts (a woken session speaks first).
    private var openingCommentary: [String]
    private let idleTimeout: TimeInterval
    /// When set, close as soon as everyone has been quiet this long (after a request went out).
    private var closeWhenQuietAfter: TimeInterval?

    init(config: Config, apiKey: String, tools: ToolRegistry, audio: AudioIO,
         voiceContext: String = "", backendContext: String = "",
         openingCommentary: [String] = [], idleTimeout: TimeInterval? = nil,
         memory: ConversationMemory? = nil, history: [[String: Any]] = [],
         turnEnd: TurnEndService? = nil, observerAnnouncement: Bool = false) {
        self.config = config
        self.memory = memory
        self.history = history
        self.turnEnd = turnEnd
        self.gate = TurnEndGate(config: config.turnEnd.d0)
        self.voiceContext = voiceContext
        self.backendContext = backendContext
        self.openingCommentary = openingCommentary
        self.idleTimeout = idleTimeout ?? config.idleTimeoutSeconds
        self.apiKey = apiKey
        self.tools = tools
        self.audio = audio
        self.protectsObserverAnnouncement = observerAnnouncement
        self.announcementGate = observerAnnouncement ? ObserverAnnouncementGate() : nil
        self.idle = IdleTracker(timeout: idleTimeout ?? config.idleTimeoutSeconds, now: Self.now)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Control

    func start() {
        guard state == .idle else { return }
        state = .connecting
        endReason = "closed"
        isMuted = false

        do {
            try audio.start()
        } catch {
            Log.error("não consegui abrir o áudio: \(error)")
            finish(reason: "audio_error")
            return
        }
        let gate = audioGate
        let protection = announcementGate
        audio.shouldPlay = protection.map { protection in
            { protection.allowsPlayback(at: ProcessInfo.processInfo.systemUptime) }
        }
        audio.onCapture = { [weak self] chunk in
            let level = VoiceActivity.level(pcm16: chunk)
            let capturedAt = ProcessInfo.processInfo.systemUptime
            // Update on the capture thread so already queued main-actor callbacks cannot
            // submit/play an announcement using a stale quiet observation.
            let cancelled = protection?.noteInput(level: level, at: capturedAt) ?? false
            Task { @MainActor in
                guard let self else { return }
                self.activity?.setInput(level)
                if let protection {
                    if cancelled || protection.isCancelled {
                        self.finish(reason: "observer_input")
                    } else {
                        self.submitObserverAnnouncementIfQuiet()
                    }
                    // Notification-only sessions use the mic locally for admission, never
                    // as conversational input. Human speech cancels this notification.
                    return
                }
                guard gate.isOpen else { return }
                let payload = #"{"type":"session.input_audio.append","audio":"\#(chunk.base64EncodedString())"}"#
                self.socket?.send(.string(payload)) { _ in }
                self.noteInputLevel(level, at: capturedAt)
            }
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        socket.resume()
        receive(on: socket)
        send(sessionStartEvent())
        Log.info("conectando ao \(config.model)…")
    }

    /// Graceful close: session.close, then wait for session.closed (or time out).
    func close(reason: String) {
        switch state {
        case .idle, .closing: return
        case .connecting:
            endReason = reason
            finish(reason: reason)
        case .live:
            endReason = reason
            state = .closing
            audioGate.isOpen = false
            send(["type": "session.close", "event_id": "close_\(reason)"])
            closeTimeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    Log.warn("session.closed não chegou; finalização de uso não confirmada")
                    self?.finish(reason: reason)
                }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard state == .live, muted != isMuted else { return }
        if protectsObserverAnnouncement {
            announcementGate?.cancel()
            finish(reason: "observer_muted")
            return
        }
        isMuted = muted
        activity?.muted = muted
        send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute", "event_id": muted ? "mute" : "unmute"])
        idle.touch(at: Self.now)
    }

    /// Context the model should say aloud soon (e.g. an async notification in phase 2).
    func appendCommentary(_ content: String) {
        guard state == .live else { return }
        send(["type": "session.commentary.append", "delegation_id": NSNull(), "content": content])
    }

    /// Say something now (a Ravi reply or message). Queued if the session is still connecting.
    /// Returns false when there is no session to say it.
    func announce(_ text: String) -> Bool {
        guard !protectsObserverAnnouncement else { return false }
        switch state {
        case .live:
            appendCommentary(text)
            closeWhenQuietAfter = nil
            idle.touch(at: Self.now)
            return true
        case .connecting:
            openingCommentary.append(text)
            return true
        case .idle, .closing:
            return false
        }
    }

    func cancelObserverAnnouncement() {
        guard protectsObserverAnnouncement else { return }
        announcementGate?.cancel()
        finish(reason: "observer_superseded")
    }

    private func submitObserverAnnouncementIfQuiet() {
        guard state == .live, let announcementGate, !openingCommentary.isEmpty,
              announcementGate.markSubmitted(at: Self.now) else { return }
        let content = openingCommentary.joined(separator: "\n")
        openingCommentary.removeAll()
        appendCommentary(content)
        idle.touch(at: Self.now)
    }

    /// End the conversation once both sides have been quiet for `seconds` (used after a request
    /// is sent: the voice says "I'll get back to you" and hangs up; the answer reopens it).
    func closeWhenQuiet(after seconds: TimeInterval) {
        guard state == .live else { return }
        closeWhenQuietAfter = seconds
    }

    // MARK: Wire

    private func sessionStartEvent() -> [String: Any] {
        var backendTools = protectsObserverAnnouncement ? [] : tools.definitions
        if config.webSearch && !protectsObserverAnnouncement { backendTools.append(["type": "web_search"]) }
        var responses: [String: Any] = [
            "model": config.backendModel,
            "instructions": [config.backendInstructions, backendContext].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            "tool_choice": "auto",
        ]
        if !backendTools.isEmpty { responses["tools"] = backendTools }
        return [
            "type": "session.start",
            "event_id": "start",
            "session": [
                "model": config.model,
                "instructions": protectsObserverAnnouncement
                    ? "Esta sessão transmite um único aviso do Ravi. Aguarde em silêncio até receber commentary; então diga somente o aviso em português, sem saudação, pergunta extra ou outras ações."
                    : [config.instructions, voiceContext].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                "audio": [
                    "format": ["type": "audio/pcm", "rate": Int(AudioIO.sampleRate)],
                    "output": ["voice": config.voice],
                ],
                "delegation": ["type": "responses", "responses": responses],
                "input": history,
            ] as [String: Any],
        ]
    }

    private func send(_ event: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { error in
            if let error { Log.debug("send falhou: \(error)") }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text: text)
                    case .data(let data): self.handle(text: String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(on: socket)
                case .failure(let error):
                    if self.state != .idle {
                        Log.error("websocket encerrado: \(error.localizedDescription)")
                        self.finish(reason: self.state == .closing ? self.endReason : "connection_lost")
                    }
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }
        let now = Self.now

        switch type {
        case "session.output_audio.delta":
            guard let b64 = event["delta"] as? String, let pcm = Data(base64Encoded: b64) else { return }
            if let announcementGate, !announcementGate.allowsPlayback(at: now) {
                if announcementGate.isCancelled { finish(reason: "observer_input_unavailable") }
                return
            }
            audio.play(pcm16: pcm)
            if AudioIO.peak(pcm16: pcm) > Self.speechPeakThreshold { idle.touch(at: now) }
            let level = VoiceActivity.level(pcm16: pcm)
            activity?.setOutput(level)
            if level > config.turnEnd.d0.outputThreshold {
                lastOutputSpeechAt = now
                candidateArmed = true
                if protectsObserverAnnouncement { closeWhenQuietAfter = 1.5 }
            }

        case "session.started":
            let session = event["session"] as? [String: Any]
            sessionId = session?["id"] as? String
            idle = IdleTracker(timeout: idleTimeout, now: now)
            audioGate.isOpen = true
            state = .live
            startIdleTimer()
            startTurnEndTimer()
            Log.info("sessão ativa \(sessionId ?? "?")")
            if protectsObserverAnnouncement {
                submitObserverAnnouncementIfQuiet()
            } else {
                openingCommentary.forEach(appendCommentary)
                openingCommentary.removeAll()
            }

        case "session.input_transcript.delta":
            idle.touch(at: now)
            if let delta = event["delta"] as? String { appendTranscript(.user, delta, now: now) }

        case "session.output_transcript.delta":
            if let announcementGate, !announcementGate.allowsPlayback(at: now) { return }
            idle.touch(at: now)
            if let delta = event["delta"] as? String { appendTranscript(.assistant, delta, now: now) }

        case "session.delegation.created":
            guard !protectsObserverAnnouncement else { return }
            if let delegation = event["delegation"] as? [String: Any], let id = delegation["id"] as? String {
                idle.beginWork(id, at: now)
                activity?.thinking = true
                Log.info("delegação \(id) → backend")
            }

        case "response.event":
            handleBackend(event, now: now)

        case "session.usage.updated":
            if let usage = event["usage"] as? [String: Any] { Log.debug("uso: \(usage)") }

        case "session.closed":
            let reason = event["reason"] as? String ?? "closed"
            let seconds = (event["usage"] as? [String: Any])?["seconds"] ?? "?"
            Log.info("sessão encerrada (\(reason)), \(seconds)s de voz")
            finish(reason: state == .closing ? endReason : reason)

        case "error":
            let error = event["error"] as? [String: Any] ?? [:]
            Log.error("erro do servidor: \(error["code"] ?? "-") \(error["message"] ?? "")")
            if state == .connecting { finish(reason: "error: \(error["code"] ?? error["message"] ?? "unknown")") }

        default:
            Log.debug("evento \(type)")
        }
    }

    /// Responses delegation events arrive wrapped: { type: "response.event", delegation_id, event }.
    private func handleBackend(_ envelope: [String: Any], now: TimeInterval) {
        guard !protectsObserverAnnouncement else { return }
        guard let delegationId = envelope["delegation_id"] as? String,
              let inner = envelope["event"] as? [String: Any],
              let type = inner["type"] as? String
        else { return }
        idle.touch(at: now)

        switch type {
        case "response.output_item.done":
            guard let item = inner["item"] as? [String: Any],
                  item["type"] as? String == "function_call",
                  let callId = item["call_id"] as? String,
                  let name = item["name"] as? String
            else { return }
            let arguments = item["arguments"] as? String ?? "{}"
            Log.info("tool call \(name)(\(arguments))")
            let tools = self.tools
            let task = Task { await tools.call(name: name, argumentsJSON: arguments) }
            pendingCalls[delegationId, default: []].append((callId, task))

        case "response.output_text.done":
            if let text = inner["text"] as? String { Log.info("backend → \(RaviText.truncate(text, 300))") }

        case "response.completed", "response.failed", "response.incomplete", "response.cancelled":
            Log.info("delegação \(delegationId): \(type.replacingOccurrences(of: "response.", with: ""))")
            guard let calls = pendingCalls.removeValue(forKey: delegationId), !calls.isEmpty else {
                idle.endWork(delegationId, at: now)
                activity?.thinking = !idle.pendingWork.isEmpty
                return
            }
            // Return every result for this response, then resume the backend once.
            Task { @MainActor in
                for call in calls {
                    let output = await call.task.value
                    guard self.state == .live else { return }
                    self.send([
                        "type": "response.item.create",
                        "item": ["type": "function_call_output", "call_id": call.callId, "output": output],
                    ])
                }
                self.send(["type": "response.create"])
                self.idle.touch(at: Self.now)
            }

        default:
            break
        }
    }

    private func appendTranscript(_ role: Utterance.Role, _ delta: String, now: TimeInterval) {
        transcript.append(role, delta, now: now)
        lastTranscriptAt = now
        if let line = transcript.currentText(role) { activity?.setCaption(line, isUser: role == .user) }
    }

    private func record(_ utterances: [Utterance]) {
        for utterance in utterances {
            Log.transcript(utterance.role == .user ? "você" : "ravi", utterance.text)
            memory?.append(utterance)
            recentUtterances.append(utterance)
            if recentUtterances.count > 8 { recentUtterances.removeFirst(recentUtterances.count - 8) }
            // Só conta fala transcrita como fala do usuário; o nível do mic também
            // capta eco do próprio agente e não serve para a análise de sombra.
            if utterance.role == .user {
                turnEnd?.noteUserSpeech(sessionId: sessionId ?? "unknown", at: utterance.at)
            }
        }
    }

    private func noteInputLevel(_ level: Double, at now: TimeInterval) {
        guard level > config.turnEnd.d0.inputThreshold else { return }
        lastInputSpeechAt = now
        // Barge-in cancela o candidato pendente.
        candidateArmed = false
    }

    // MARK: Idle + teardown

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: protectsObserverAnnouncement ? 0.1 : 1,
                                        repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func startTurnEndTimer() {
        turnEndTimer?.invalidate()
        recheckWork?.cancel()
        recheckWork = nil
        recheckUntil = 0
        nextCandidateAllowedAt = 0
        guard turnEnd != nil else { return }
        turnEndTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTurnEnd() }
        }
    }

    /// 100 ms tick: só chama o provedor quando o D0 confirma o candidato.
    private func tickTurnEnd() {
        guard state == .live, let turnEnd, candidateArmed else { return }
        let now = Self.now
        // 200 ms sem novo delta: evita mandar "Chegou mensagem do Je" no lugar da fala inteira.
        guard now - lastTranscriptAt >= 0.2 else { return }
        let signals = currentTurnSignals(now: now)
        guard turnEnd.isCandidate(signals) else { return }
        candidateArmed = false
        recheckWork?.cancel()
        recheckUntil = 0
        nextCandidateAllowedAt = now + Double(config.turnEnd.minIntervalMs) / 1000
        turnCounter += 1
        let snippets = currentSnippets()
        let session = sessionId ?? "unknown"
        let turn = "turn_\(turnCounter)"
        let onClose: @MainActor () -> Bool = { [weak self] in
            guard let self, self.state == .live else { return false }
            let current = self.currentTurnSignals(now: Self.now)
            if let failure = self.gate.failure(current) {
                // Não cancela de vez: agenda uma reavaliação para quando o áudio/mic ficar quieto.
                Log.info("turn-end: fechamento adiado (\(failure)); reavaliar quando o gate liberar")
                self.scheduleTurnEndRecheck()
                return false
            }
            self.close(reason: "jev")
            return true
        }
        Task {
            await turnEnd.evaluate(
                sessionId: session,
                turnId: turn,
                signals: signals,
                snippets: snippets,
                onClose: onClose
            )
        }
    }

    private func currentTurnSignals(now: TimeInterval) -> TurnSignals {
        TurnSignals(
            outputLevel: activity?.outputLevel ?? 0,
            inputLevel: activity?.inputLevel ?? 0,
            msSinceAgentSpeech: Int(max(0, now - lastOutputSpeechAt) * 1000),
            msSinceUserSpeech: Int(max(0, now - lastInputSpeechAt) * 1000),
            eos: true,
            pendingWork: !idle.pendingWork.isEmpty,
            closeRequested: false
        )
    }

    /// Se o close foi adiado, tenta de novo em fatias curtas até o gate liberar (máx. 5 s).
    private func scheduleTurnEndRecheck() {
        recheckWork?.cancel()
        let now = Self.now
        if recheckUntil == 0 { recheckUntil = now + 5.0 }
        let waitForInterval = max(0, nextCandidateAllowedAt - now)
        let delay = min(0.4, max(0.1, waitForInterval))
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .live else { return }
                let now = Self.now
                let current = self.currentTurnSignals(now: now)
                if self.gate.failure(current) == nil {
                    self.recheckUntil = 0
                    self.candidateArmed = true
                    Log.info("turn-end: gate liberou; reavaliando o fechamento")
                } else if now < self.recheckUntil {
                    self.scheduleTurnEndRecheck()
                } else {
                    self.recheckUntil = 0
                    Log.info("turn-end: reavaliação expirou; segue para o idle")
                }
            }
        }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func currentSnippets() -> TurnSnippets {
        let lastUser = recentUtterances.last(where: { $0.role == .user })?.text
        let currentAgent = transcript.currentText(.assistant)
        let lastAgent = (currentAgent?.isEmpty == false ? currentAgent : recentUtterances.last(where: { $0.role == .assistant })?.text)
        let recent = recentUtterances.suffix(4).map {
            TurnSnippet(role: $0.role == .user ? "user" : "assistant", text: Self.truncate($0.text, 500))
        }
        return TurnSnippets(
            lastUser: lastUser.map { Self.truncate($0, 500) },
            lastAgent: lastAgent.map { Self.truncate($0, 500) },
            recent: Array(recent)
        )
    }

    private static func truncate(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private func tick() {
        let now = Self.now
        if let announcementGate {
            // Also invalidate already buffered playback if capture stops between output
            // events. Waiting for another PCM frame would leave that buffer unguarded.
            _ = announcementGate.allowsPlayback(at: now)
            if announcementGate.isCancelled {
                finish(reason: "observer_input_unavailable")
                return
            }
        }
        record(transcript.flushQuiet(now: now))
        guard state == .live else { return }
        if let quiet = closeWhenQuietAfter, idle.pendingWork.isEmpty, now - idle.lastActivity >= quiet {
            Log.info("pedido enviado e conversa em silêncio; encerrando até a resposta chegar")
            close(reason: "aguardando resposta")
        } else if idle.isIdle(at: now) {
            Log.info("inatividade de \(Int(idleTimeout))s; encerrando")
            close(reason: "idle")
        }
    }

    private func finish(reason: String) {
        guard state != .idle else { return }
        let endedSession = sessionId ?? "unknown"
        idleTimer?.invalidate()
        closeTimeout?.invalidate()
        turnEndTimer?.invalidate()
        recheckWork?.cancel()
        idleTimer = nil
        closeTimeout = nil
        turnEndTimer = nil
        recheckWork = nil
        recheckUntil = 0
        audioGate.isOpen = false
        announcementGate?.cancel()
        audio.onCapture = nil
        audio.flushPlayback()
        audio.shouldPlay = nil
        audio.stop()
        pendingCalls.values.flatMap { $0 }.forEach { $0.task.cancel() }
        pendingCalls.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        sessionId = nil
        record(transcript.flushAll())
        activity?.reset()
        state = .idle
        turnEnd?.noteSessionEnd(sessionId: endedSession, reason: reason)
        onEnded?(reason)
    }
}

/// Thread-safe flag read from the audio thread.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}
