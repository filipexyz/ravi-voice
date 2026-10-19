import Foundation

/// Tiny file + stderr logger. Logs go to ~/Library/Logs/RaviVoice/ravi-voice.log,
/// transcripts to ~/Library/Logs/RaviVoice/transcripts.log.
enum Log {
    static let dir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RaviVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let logURL = dir.appendingPathComponent("ravi-voice.log")
    static let transcriptURL = dir.appendingPathComponent("transcripts.log")

    private static let queue = DispatchQueue(label: "ravi-voice.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }
    static func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["RAVI_VOICE_DEBUG"] != nil { write("DEBUG", message) }
    }

    /// Waits for pending writes (call before exit()).
    static func flush() { queue.sync {} }

    static func transcript(_ speaker: String, _ text: String) {
        let line = "[\(formatter.string(from: Date()))] \(speaker): \(text)\n"
        queue.async { append(line, to: transcriptURL) }
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            append(line, to: logURL)
        }
    }

    /// Unit tests log to stderr only, never into the real log files.
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    private static func append(_ line: String, to url: URL) {
        if isTesting { return }
        let data = line.data(using: .utf8)!
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
