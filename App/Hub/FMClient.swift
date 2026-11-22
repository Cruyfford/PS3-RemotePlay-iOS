import Foundation

/// Client for the File Manager (CRPK00001) phone-link API on port 8080.
/// Reaches every drive the PS3 app can open — HDD, FAT32, exFAT, NTFS, ext.
final class FMClient: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    struct Volume: Decodable, Hashable { let label: String; let root: String; let fs: String; let kind: Int; let writable: Bool; let free: Int64 }
    struct Status: Decodable { let busy: Bool; let task: String?; let name: String?; let done: Int64?; let total: Int64?; let queue: Int? }
    private struct ListReply: Decodable { struct E: Decodable { let name: String; let dir: Bool; let size: Int64 }; let entries: [E] }
    private struct VolReply: Decodable { let volumes: [Volume] }
    private struct OkReply: Decodable { let ok: Bool; let error: String? }

    enum FMError: LocalizedError {
        case server(String)
        var errorDescription: String? { if case .server(let s) = self { return s }; return nil }
    }

    let base: URL
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private var progressHandlers: [Int: (Int64) -> Void] = [:]
    private var downloadDone: [Int: (URL?, Error?) -> Void] = [:]
    private let lock = NSLock()

    init(host: String) { base = URL(string: "http://\(host):8080")! }

    private func url(_ path: String, _ q: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        // '+' and '&' inside file names must survive
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func call(_ method: String, _ path: String, _ q: [String: String] = [:]) async throws -> Data {
        var r = URLRequest(url: url(path, q))
        r.httpMethod = method
        let (d, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let msg = (try? JSONDecoder().decode(OkReply.self, from: d))?.error ?? "HTTP \(h.statusCode)"
            throw FMError.server(msg)
        }
        return d
    }

    /// true when the File Manager is running on the PS3 with the phone link on
    static func probe(host: String) async -> Bool {
        guard let u = URL(string: "http://\(host):8080/api/info") else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 2.5
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(data: d, encoding: .utf8)?.contains("CRPK00001") == true
    }

    func volumes() async throws -> [Volume] { try JSONDecoder().decode(VolReply.self, from: try await call("GET", "api/volumes")).volumes }

    func list(_ path: String) async throws -> [FTPClient.Entry] {
        let r = try JSONDecoder().decode(ListReply.self, from: try await call("GET", "api/list", ["path": path]))
        return r.entries.map { FTPClient.Entry(name: $0.name, isDir: $0.dir, size: $0.size) }
            .sorted { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func status() async throws -> Status { try JSONDecoder().decode(Status.self, from: try await call("GET", "api/status")) }
    func mkdir(_ p: String) async throws { _ = try await call("POST", "api/mkdir", ["path": p]) }
    func delete(_ p: String) async throws { _ = try await call("POST", "api/delete", ["path": p]) }
    func rename(_ a: String, _ b: String) async throws { _ = try await call("POST", "api/rename", ["from": a, "to": b]) }
    func install(_ p: String) async throws { _ = try await call("POST", "api/install", ["path": p]) }

    func upload(_ local: URL, to remote: String, progress: @escaping (Int64) -> Void) async throws {
        var r = URLRequest(url: url("api/file", ["path": remote]))
        r.httpMethod = "PUT"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (d, resp): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let t = session.uploadTask(with: r, fromFile: local) { d, resp, e in
                if let e = e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), resp!)) }
            }
            lock.lock(); progressHandlers[t.taskIdentifier] = progress; lock.unlock()
            t.resume()
        }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw FMError.server((try? JSONDecoder().decode(OkReply.self, from: d))?.error ?? "HTTP \(h.statusCode)")
        }
    }

    func download(_ remote: String, to local: URL, progress: @escaping (Int64) -> Void) async throws {
        let tmp: URL = try await withCheckedThrowingContinuation { cont in
            let t = session.downloadTask(with: url("api/file", ["path": remote]))
            lock.lock()
            progressHandlers[t.taskIdentifier] = progress
            downloadDone[t.taskIdentifier] = { u, e in if let u = u { cont.resume(returning: u) } else { cont.resume(throwing: e ?? FMError.server("download")) } }
            lock.unlock()
            t.resume()
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: tmp, to: local)
    }

    // MARK: delegate
    func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData sent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let h = progressHandlers[task.taskIdentifier]; lock.unlock()
        h?(totalBytesSent)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData w: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let h = progressHandlers[downloadTask.taskIdentifier]; lock.unlock()
        h?(totalBytesWritten)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the file is deleted when this returns: move it first
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ok = (try? FileManager.default.moveItem(at: location, to: keep)) != nil
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock(); let done = downloadDone.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
        if ok && code == 200 { done?(keep, nil) } else { done?(nil, FMError.server("HTTP \(code)")) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        progressHandlers.removeValue(forKey: task.taskIdentifier)
        let done = downloadDone.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let e = error { done?(nil, e) }
    }
}
