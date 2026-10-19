import Foundation

/// Backend function tools over the Ravi gateway.

struct RaviListSessionsTool: VoiceTool {
    let gateway: RaviGateway
    let name = "ravi_list_sessions"
    let description = "List the user's Ravi agent sessions, most recently active first."
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "limit": ["type": "integer", "description": "How many sessions (default 10, max 30)."],
            "agent": ["type": "string", "description": "Only sessions of this agent id."],
        ],
        "additionalProperties": false,
    ]

    func run(arguments: [String: Any]) async throws -> String {
        let limit = min(max(arguments["limit"] as? Int ?? 10, 1), 30)
        let sessions = try await gateway.recentSessions(limit: limit, agent: arguments["agent"] as? String)
        let now = Date()
        return ToolRegistry.json(["sessions": sessions.map { s in
            [
                "name": s.name,
                "agent": s.agentId ?? NSNull(),
                "displayName": s.displayName ?? NSNull(),
                "channel": s.channel ?? NSNull(),
                "lastActive": RaviText.relative(s.updatedAt, now: now),
            ] as [String: Any]
        }])
    }
}

struct RaviSessionRecapTool: VoiceTool {
    let gateway: RaviGateway
    let name = "ravi_session_recap"
    let description = "Read the latest messages of one Ravi session (who said what, most recent last)."
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "session": ["type": "string", "description": "Exact session name, e.g. from ravi_list_sessions."],
            "count": ["type": "integer", "description": "How many recent messages (default 8, max 20)."],
        ],
        "required": ["session"],
        "additionalProperties": false,
    ]

    func run(arguments: [String: Any]) async throws -> String {
        guard let session = arguments["session"] as? String else { return ToolRegistry.json(["error": "session is required"]) }
        let count = min(max(arguments["count"] as? Int ?? 8, 1), 20)
        let digest = try await gateway.recap(session, count: count)
        let now = Date()
        return ToolRegistry.json([
            "session": RaviText.label(digest),
            "lastActive": RaviText.relative(digest.updatedAt, now: now),
            "messages": digest.messages.map { m in
                [
                    "role": m.role,
                    "when": RaviText.relative(m.time, now: now),
                    "text": RaviText.truncate(m.text, 700),
                ]
            },
        ])
    }
}

struct RaviSendMessageTool: VoiceTool {
    let gateway: RaviGateway
    let bridge: RaviBridge
    let name = "ravi_send_message"
    let description = """
    Send a message or request to a Ravi session on the user's behalf. Returns as soon as it is \
    queued; the session answers later on its own and the answer is spoken to the user then \
    (the voice conversation closes meanwhile and reopens with the answer).
    """
    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "session": ["type": "string", "description": "Exact session name."],
            "message": ["type": "string", "description": "What to send, written as the user would say it."],
        ],
        "required": ["session", "message"],
        "additionalProperties": false,
    ]

    func run(arguments: [String: Any]) async throws -> String {
        guard let session = arguments["session"] as? String,
              let message = (arguments["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return ToolRegistry.json(["error": "session and message are required"]) }
        let request = try await bridge.send(session: session, message: message)
        return ToolRegistry.json([
            "status": "sent",
            "session": session,
            "requestId": request.id,
            "note": "Tell the user in one short sentence that it was sent and that you'll come back when the answer arrives.",
        ])
    }
}
