import Foundation
import RaviSDK

/// Non-GUI entry points of the same binary:
///   RaviVoice say --text "…" [--reply-to <id>] [--json]   (behind the Ravi app op `ravi voice say`)
///   RaviVoice deliver [<file>]                            (the shell step of the ravi.voice trigger)
enum CLI {
    /// Returns an exit code when argv is a CLI command, nil to start the menu bar app.
    static func run(_ argv: [String]) -> Int32? {
        guard argv.count > 1 else { return nil }
        switch argv[1] {
        case "say": return say(Array(argv.dropFirst(2)))
        case "deliver": return deliver(Array(argv.dropFirst(2)))
        default: return nil
        }
    }

    // MARK: say

    static func say(_ args: [String]) -> Int32 {
        var text: [String] = []
        var replyTo: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--text", "-t":
                i += 1
                if i < args.count { text.append(args[i]) }
            case "--reply-to":
                i += 1
                if i < args.count { replyTo = args[i] }
            case "--json":
                break
            default:
                text.append(args[i])
            }
            i += 1
        }
        let body = text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return fail("say", code: "USAGE", "use: ravi voice say --text \"mensagem\" [--reply-to <id>]", exit: 2)
        }

        let sender = resolveSender()
        let message = VoiceMessage(
            correlationId: "voice_\(UUID().uuidString.prefix(12).lowercased())",
            replyTo: replyTo?.isEmpty == true ? nil : replyTo,
            text: body,
            fromSession: sender.session,
            fromAgent: sender.agent,
            createdAt: Date()
        )
        do {
            try spacedPublish { try NATSPublisher.publish(subject: VoiceMessage.topic, payload: try message.encoded()) }
        } catch {
            return fail("say", code: "PUBLISH_FAILED", String(describing: error), exit: 1)
        }
        printJSON([
            "success": true,
            "op": "voice say",
            "topic": VoiceMessage.topic,
            "correlationId": message.correlationId,
            "replyTo": message.replyTo ?? NSNull(),
            "from": ["session": sender.session as Any? ?? NSNull(), "agent": sender.agent as Any? ?? NSNull()],
            "note": "Queued for the user's voice. It will be spoken aloud on their Mac.",
        ])
        return 0
    }

    /// The ravi.voice trigger has a cooldown (Ravi's minimum is 1s) and drops events inside it,
    /// so publishes from this Mac are spaced out under an exclusive file lock.
    static let minimumSpacing: TimeInterval = 1.2

    private static func spacedPublish(_ publish: () throws -> Void) throws {
        let lockURL = Config.directory.appendingPathComponent("say.lock")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return try publish() }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buffer, buffer.count, 0)
        let last = n > 0 ? Double(String(decoding: buffer[0..<n], as: UTF8.self)) ?? 0 : 0
        let wait = last + minimumSpacing - Date().timeIntervalSince1970
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        try publish()
        let stamp = Array(String(format: "%.3f", Date().timeIntervalSince1970).utf8)
        ftruncate(fd, 0)
        _ = pwrite(fd, stamp, stamp.count, 0)
    }

    /// The caller's identity comes from its own context key (Ravi passes it to app processes),
    /// so a session can't pretend to be another one.
    private static func resolveSender() -> (session: String?, agent: String?) {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["RAVI_CONTEXT_KEY"], !key.isEmpty, let base = gatewayURL(env) else {
            return (env["RAVI_SESSION_NAME"], env["RAVI_AGENT_ID"])
        }
        let client = RaviClient(transport: HTTPTransport(baseURL: base, contextKey: key, timeout: 4))
        let semaphore = DispatchSemaphore(value: 0)
        var result: (String?, String?) = (nil, nil)
        Task {
            if let me = try? await client.context.whoami() {
                result = (me.sessionName.stringValue, me.agentId.stringValue)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return (result.0 ?? env["RAVI_SESSION_NAME"], result.1 ?? env["RAVI_AGENT_ID"])
    }

    private static func gatewayURL(_ env: [String: String]) -> URL? {
        if let raw = env["RAVI_GATEWAY_URL"] ?? env["RAVI_BASE_URL"] ?? env["RAVI_HTTP_BASE_URL"], let url = URL(string: raw) { return url }
        let dotenv = Config.readDotenv(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ravi/.env"))
        guard let port = env["RAVI_HTTP_PORT"] ?? dotenv["RAVI_HTTP_PORT"] else { return nil }
        let host = env["RAVI_HTTP_HOST"] ?? dotenv["RAVI_HTTP_HOST"] ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)")
    }

    // MARK: deliver

    static func deliver(_ args: [String]) -> Int32 {
        guard let path = args.first ?? ProcessInfo.processInfo.environment["RAVI_TRIGGER_DATA_FILE"] else {
            return fail("deliver", code: "USAGE", "sem arquivo de evento (RAVI_TRIGGER_DATA_FILE)", exit: 2)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let message = try VoiceMessage.decode(data)
            let file = try VoiceInbox.drop(try message.encoded())
            printJSON(["success": true, "op": "voice deliver", "correlationId": message.correlationId, "file": file.lastPathComponent])
            return 0
        } catch {
            return fail("deliver", code: "DELIVER_FAILED", String(describing: error), exit: 1)
        }
    }

    // MARK: output

    private static func printJSON(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func fail(_ op: String, code: String, _ message: String, exit: Int32) -> Int32 {
        printJSON(["success": false, "op": "voice \(op)", "error": ["code": code, "message": message]])
        return exit
    }
}
