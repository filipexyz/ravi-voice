import Foundation

/// A message for the voice agent, published on `ravi.voice.message` by `ravi voice say`.
struct VoiceMessage: Codable, Equatable, Sendable {
    static let topic = "ravi.voice.message"

    var appId: String = "voice"
    /// Unique per message.
    var correlationId: String
    /// Set when answering a request the voice sent (the id from the return instruction).
    var replyTo: String?
    var text: String
    var fromSession: String?
    var fromAgent: String?
    var createdAt: Date

    /// The sender is populated by the authenticated `say` caller, not inferred from text.
    var isObserverAnnouncement: Bool { fromAgent == "voice-observer" }

    /// Trigger data files hold the event payload; tolerate a `{ data: … }` envelope too.
    static func decode(_ data: Data) throws -> VoiceMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let message = try? decoder.decode(VoiceMessage.self, from: data) { return message }
        struct Envelope: Decodable { var data: VoiceMessage }
        return try decoder.decode(Envelope.self, from: data).data
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// File-drop inbox: the Ravi trigger's shell step (`RaviVoice deliver`) writes one JSON file
/// per event; the running app watches the directory, handles each file and deletes it.
/// Durable by construction — events that arrive while the app restarts wait on disk.
final class VoiceInbox {
    static let directory = Config.directory.appendingPathComponent("inbox", isDirectory: true)

    private var source: DispatchSourceFileSystemObject?
    private let onMessage: (VoiceMessage) -> Void

    init(onMessage: @escaping (VoiceMessage) -> Void) {
        self.onMessage = onMessage
    }

    /// Atomic drop (write tmp, then rename) so the watcher never reads a half-written file.
    static func drop(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let tmp = directory.appendingPathComponent(".\(name).tmp")
        let final = directory.appendingPathComponent("\(name).json")
        try data.write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("inbox: não consegui observar \(Self.directory.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        drain()
        Log.info("inbox de voz observando \(Self.directory.path)")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                onMessage(try VoiceMessage.decode(try Data(contentsOf: file)))
            } catch {
                Log.error("inbox: evento inválido \(file.lastPathComponent): \(error)")
            }
        }
    }
}
