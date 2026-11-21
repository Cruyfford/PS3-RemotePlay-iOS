import Foundation
import Network

/// Small FTP client (passive mode) on Network.framework, for webMAN's FTP (port 21)
/// or File Manager's FTP server (port 2121).
final class FTPClient {
    struct Entry: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let isDir: Bool
        let size: Int64
    }

    enum FTPError: LocalizedError {
        case connect, reply(String), closed
        var errorDescription: String? {
            switch self {
            case .connect: return L.t("Couldn't connect to the FTP server", "تعذر الاتصال بخادم FTP")
            case .reply(let r): return r
            case .closed: return L.t("Connection closed", "انقطع الاتصال")
            }
        }
    }

    private let host: String
    private let port: UInt16
    private var ctrl: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "ftp")

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: port)
    }

    deinit { ctrl?.cancel() }

    // MARK: low level

    private func open(_ host: String, _ port: UInt16) async throws -> NWConnection {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, Error>) in
            var done = false
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: if !done { done = true; cont.resume(returning: c) }
                case .failed, .cancelled: if !done { done = true; cont.resume(throwing: FTPError.connect) }
                case .waiting: if !done { done = true; c.cancel(); cont.resume(throwing: FTPError.connect) }
                default: break
                }
            }
            c.start(queue: queue)
        }
    }

    private func receive(_ c: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, err in
                if let d = data, !d.isEmpty { cont.resume(returning: d) }
                else if complete { cont.resume(returning: nil) }
                else if let e = err { cont.resume(throwing: e) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func send(_ c: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in
                if let e = e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    /// one complete reply (handles multi-line "123-...\r\n123 ...")
    private func reply() async throws -> (Int, String) {
        guard let c = ctrl else { throw FTPError.closed }
        var code: Int?
        var lines: [String] = []
        while true {
            while let r = buffer.range(of: Data("\r\n".utf8)) ?? buffer.range(of: Data("\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                let line = String(decoding: lineData, as: UTF8.self)
                lines.append(line)
                let chars = Array(line)
                if chars.count >= 4, let n = Int(String(chars[0..<3])) {
                    if code == nil { code = n }
                    if chars[3] == " " && n == code { return (n, lines.joined(separator: "\n")) }
                } else if chars.count == 3, let n = Int(line), code == nil || code == n {
                    return (n, line)
                }
            }
            guard let d = try await receive(c) else { throw FTPError.closed }
            buffer.append(d)
        }
    }

    @discardableResult
    private func cmd(_ s: String, expect: ClosedRange<Int> = 100...399) async throws -> (Int, String) {
        guard let c = ctrl else { throw FTPError.closed }
        try await send(c, Data((s + "\r\n").utf8))
        let r = try await reply()
        if !expect.contains(r.0) { throw FTPError.reply(r.1) }
        return r
    }

    // MARK: session

    func connect(user: String = "anonymous", pass: String = "ps3hub") async throws {
        if ctrl != nil { return }
        ctrl = try await open(host, port)
        _ = try await reply()                               // 220
        let u = try await cmd("USER \(user)", expect: 200...399)
        if u.0 == 331 { try await cmd("PASS \(pass)", expect: 200...299) }
        try? await cmd("TYPE I")
    }

    func close() {
        if let c = ctrl { c.send(content: Data("QUIT\r\n".utf8), completion: .idempotent); c.cancel() }
        ctrl = nil
        buffer.removeAll()
    }

    private func pasv() async throws -> NWConnection {
        let r = try await cmd("PASV", expect: 227...227)
        // 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)
        guard let open = r.1.firstIndex(of: "("), let close = r.1.firstIndex(of: ")") else { throw FTPError.reply(r.1) }
        let nums = r.1[r.1.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { throw FTPError.reply(r.1) }
        let p = UInt16(nums[4] * 256 + nums[5])
        // servers behind HEN often report 127.0.0.1: always use the host we connected to
        return try await self.open(host, p)
    }

    private func readAll(_ c: NWConnection, progress: ((Int64) -> Void)? = nil, sink: ((Data) throws -> Void)? = nil) async throws -> Data {
        var all = Data()
        var total: Int64 = 0
        while let d = try await receive(c) {
            if d.isEmpty { continue }
            total += Int64(d.count)
            if let s = sink { try s(d) } else { all.append(d) }
            progress?(total)
        }
        c.cancel()
        return all
    }

    // MARK: operations

    func list(_ path: String) async throws -> [Entry] {
        try await connect()
        try await cmd("CWD \(path)", expect: 200...299)
        let data = try await pasv()
        try await cmd("LIST", expect: 100...199)
        let raw = try await readAll(data)
        _ = try? await reply()                                // 226
        return Self.parseList(String(decoding: raw, as: UTF8.self))
    }

    static func parseList(_ text: String) -> [Entry] {
        var out: [Entry] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let name = String(parts[8])
            if name == "." || name == ".." { continue }
            let isDir = line.first == "d"
            out.append(Entry(name: name, isDir: isDir, size: Int64(parts[4]) ?? 0))
        }
        return out.sorted { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func download(_ remote: String, to local: URL, progress: @escaping (Int64) -> Void) async throws {
        try await connect()
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let fh = try FileHandle(forWritingTo: local)
        defer { try? fh.close() }
        let data = try await pasv()
        try await cmd("RETR \(remote)", expect: 100...199)
        _ = try await readAll(data, progress: progress) { chunk in fh.write(chunk) }
        _ = try? await reply()
    }

    func upload(_ local: URL, to remote: String, progress: @escaping (Int64) -> Void) async throws {
        try await connect()
        let fh = try FileHandle(forReadingFrom: local)
        defer { try? fh.close() }
        let data = try await pasv()
        try await cmd("STOR \(remote)", expect: 100...199)
        var sent: Int64 = 0
        while true {
            let chunk = fh.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            try await send(data, chunk)
            sent += Int64(chunk.count)
            progress(sent)
        }
        data.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        try? await Task.sleep(nanoseconds: 300_000_000)
        data.cancel()
        _ = try? await reply()
    }

    func delete(_ path: String, isDir: Bool) async throws {
        try await connect()
        try await cmd(isDir ? "RMD \(path)" : "DELE \(path)", expect: 200...299)
    }

    func mkdir(_ path: String) async throws {
        try await connect()
        try await cmd("MKD \(path)", expect: 200...299)
    }

    func rename(_ from: String, _ to: String) async throws {
        try await connect()
        try await cmd("RNFR \(from)", expect: 300...399)
        try await cmd("RNTO \(to)", expect: 200...299)
    }
}
