import Foundation

/// A function the backend (Responses delegation) can call. The voice model hands the request
/// to the backend model, which emits a function_call; we run it here and return the output.
///
/// Phase 2: the Ravi session tools (list/read/send to `ravi sessions`) register here.
protocol VoiceTool {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments object.
    var parameters: [String: Any] { get }
    func run(arguments: [String: Any]) async throws -> String
}

final class ToolRegistry {
    private(set) var tools: [String: VoiceTool] = [:]

    init(_ tools: [VoiceTool] = []) {
        tools.forEach(register)
    }

    func register(_ tool: VoiceTool) {
        tools[tool.name] = tool
    }

    /// Function tool definitions in Responses API shape.
    var definitions: [[String: Any]] {
        tools.values.sorted { $0.name < $1.name }.map { tool in
            [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters,
            ]
        }
    }

    /// Runs a call and always returns a string output; failures become a JSON error the
    /// backend can talk about instead of stalling the conversation.
    func call(name: String, argumentsJSON: String) async -> String {
        guard let tool = tools[name] else {
            return Self.json(["error": "unknown tool \(name)"])
        }
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let args = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        do {
            let output = try await tool.run(arguments: args)
            Log.info("tool \(name) ok (\(output.count) chars)")
            return output
        } catch {
            Log.error("tool \(name) falhou: \(error)")
            return Self.json(["error": String(describing: error)])
        }
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Closes the active session when the user explicitly asks to end the conversation.
final class CloseSessionTool: VoiceTool {
    let name = "close_session"
    let description = "Close the current voice session when the user explicitly asks to stop, hang up, end or close the conversation."
    let parameters: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    func run(arguments: [String: Any]) async throws -> String {
        let close = onClose
        DispatchQueue.main.async { close() }
        return ToolRegistry.json(["status": "closing"])
    }
}

/// Local date/time, so the assistant knows "now" on this Mac.
struct CurrentTimeTool: VoiceTool {
    let name = "current_time"
    let description = "Returns the current local date, time and time zone of the user's Mac."
    let parameters: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]

    func run(arguments: [String: Any]) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy, HH:mm"
        return ToolRegistry.json([
            "local": formatter.string(from: Date()),
            "iso": ISO8601DateFormatter().string(from: Date()),
            "timeZone": TimeZone.current.identifier,
        ])
    }
}
