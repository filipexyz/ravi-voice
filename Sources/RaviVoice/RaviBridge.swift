import Foundation

/// Glue between Ravi and the voice session:
/// - keeps a fresh snapshot of recent sessions for the session.start context;
/// - sends requests to sessions with an implicit return instruction (answer on ravi.voice);
/// - turns inbox messages (replies or messages from other agents) into announcements.
@MainActor
final class RaviBridge {
    struct PendingRequest: Equatable {
        var id: String
        var session: String
        var summary: String
        var sentAt: Date
    }

    let gateway: RaviGateway
    private let sessionCount: Int
    private let messageCount: Int

    private(set) var snapshot: [RaviSessionDigest] = []
    private(set) var snapshotAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private(set) var pending: [String: PendingRequest] = [:]
    /// Announcements that could not be spoken (no session could open); go into the next context.
    private(set) var held: [RaviReply] = []

    /// Fired after a request goes out, so the app can end the conversation and wait.
    var onRequestSent: ((PendingRequest) -> Void)?

    init(gateway: RaviGateway, sessions: Int, messages: Int) {
        self.gateway = gateway
        self.sessionCount = sessions
        self.messageCount = messages
    }

    // MARK: Snapshot

    func startBackgroundRefresh(every interval: TimeInterval = 120) {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let task = Task { [gateway, sessionCount, messageCount] in
            do {
                let digest = try await gateway.digest(sessions: sessionCount, messages: messageCount)
                self.snapshot = digest
                self.snapshotAt = Date()
                Log.debug("Ravi: snapshot com \(digest.count) sessões")
            } catch {
                Log.warn("Ravi: falha ao atualizar sessões: \(error)")
            }
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    /// Before a session starts: refresh a stale snapshot, but never hold the user up for long.
    func prepare(maxAge: TimeInterval = 90, timeout: TimeInterval = 1.5) async {
        if let at = snapshotAt, Date().timeIntervalSince(at) < maxAge { return }
        let task = refresh()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Instructions for the voice model; consumes held announcements.
    func takeVoiceContext() -> String {
        let pendingList = pending.values.sorted { $0.sentAt < $1.sentAt }
        var text = RaviText.voiceContext(sessions: snapshot, replies: held, now: Date())
        if !pendingList.isEmpty {
            text += "\n\n## Pedidos aguardando resposta\n"
            for request in pendingList {
                text += "- \(request.session): \(RaviText.truncate(request.summary, 160)) (\(RaviText.relative(request.sentAt, now: Date())))\n"
            }
        }
        held.removeAll()
        return text
    }

    func backendContext() -> String {
        RaviText.backendContext(sessions: snapshot, now: Date())
    }

    // MARK: Requests

    /// Sends to a session without waiting; the session answers on ravi.voice via `ravi voice say`.
    func send(session: String, message: String) async throws -> PendingRequest {
        let id = "vreq_\(UUID().uuidString.prefix(10).lowercased())"
        try await gateway.sendNoWait(session, message: RaviText.requestPrompt(message: message, requestId: id))
        let request = PendingRequest(id: id, session: session, summary: message, sentAt: Date())
        pending[id] = request
        Log.info("Ravi: pedido \(id) enviado pra \(session)")
        onRequestSent?(request)
        return request
    }

    // MARK: Inbox

    /// What the voice should say about an inbox message.
    func announcement(for message: VoiceMessage) -> String {
        let text = RaviText.truncate(RaviText.clean(message.text), 1_400)
        if let replyTo = message.replyTo, let request = pending.removeValue(forKey: replyTo) {
            Log.info("Ravi: resposta de \(request.session) ao pedido \(replyTo)")
            return "Chegou a resposta da sessão \(request.session) do Ravi ao pedido que o usuário fez por voz (\"\(RaviText.truncate(request.summary, 120))\"). Conte agora, resumindo: \(text)"
        }
        let who = message.fromSession.map { "da sessão \($0)" } ?? message.fromAgent.map { "do agente \($0)" } ?? "de um agente"
        return "Chegou uma mensagem \(who) do Ravi pro usuário. Conte agora, resumindo: \(text)"
    }

    func hold(_ message: VoiceMessage) {
        held.append(RaviReply(session: message.fromSession ?? message.fromAgent ?? "ravi", text: message.text, receivedAt: message.createdAt))
        if let replyTo = message.replyTo { pending.removeValue(forKey: replyTo) }
    }

    /// Requests nobody answered in a long while are dropped so the context stays honest.
    func expireStale(olderThan age: TimeInterval = 6 * 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        pending = pending.filter { $0.value.sentAt > cutoff }
    }
}
