import Foundation

/// Fire-once NATS publisher over the plain text protocol (CONNECT / PUB / PING), enough for
/// `RaviVoice say` to put one event on Ravi's bus without a client library.
enum NATSPublisher {
    enum Failure: Error, CustomStringConvertible {
        case badURL(String), resolve(String), connect(String), server(String), timeout

        var description: String {
            switch self {
            case .badURL(let u): return "NATS URL inválida: \(u)"
            case .resolve(let h): return "não resolvi o host NATS \(h)"
            case .connect(let e): return "não conectei no NATS: \(e)"
            case .server(let e): return "NATS recusou: \(e)"
            case .timeout: return "NATS não respondeu"
            }
        }
    }

    /// NATS_URL from the environment or ~/.ravi/.env, else the Ravi default.
    static func defaultURL() -> String {
        if let url = ProcessInfo.processInfo.environment["NATS_URL"], !url.isEmpty { return url }
        let env = Config.readDotenv(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ravi/.env"))
        return env["NATS_URL"] ?? "nats://127.0.0.1:4222"
    }

    static func publish(subject: String, payload: Data, url: String = defaultURL(), timeout: TimeInterval = 3) throws {
        guard let components = URLComponents(string: url), let host = components.host else { throw Failure.badURL(url) }
        let port = components.port ?? 4222

        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let addr = info else { throw Failure.resolve(host) }
        defer { freeaddrinfo(info) }

        let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard fd >= 0 else { throw Failure.connect(String(cString: strerror(errno))) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 else {
            throw Failure.connect(String(cString: strerror(errno)))
        }

        _ = try readLine(fd) // INFO {...}
        var frame = Data()
        var credentials = ""
        if let user = components.user {
            credentials = #","user":"\#(user)","pass":"\#(components.password ?? "")""#
        }
        frame.append(#"CONNECT {"verbose":false,"pedantic":false,"name":"ravi-voice"\#(credentials)}"#.data(using: .utf8)!)
        frame.append("\r\nPUB \(subject) \(payload.count)\r\n".data(using: .utf8)!)
        frame.append(payload)
        frame.append("\r\nPING\r\n".data(using: .utf8)!)
        try frame.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { throw Failure.connect(String(cString: strerror(errno))) }
                sent += n
            }
        }
        // PONG confirms the server processed everything before it; -ERR means it refused.
        while true {
            let line = try readLine(fd)
            if line.hasPrefix("PONG") { return }
            if line.hasPrefix("-ERR") { throw Failure.server(line) }
        }
    }

    private static func readLine(_ fd: Int32) throws -> String {
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = recv(fd, &byte, 1, 0)
            guard n == 1 else { throw Failure.timeout }
            if byte == UInt8(ascii: "\n") { break }
            if byte != UInt8(ascii: "\r") { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
