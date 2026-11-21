import Foundation

/// HTTP client for webMAN MOD's web server on the PS3 (port 80 by default).
/// Commands: https://github.com/aldostools/webMAN-MOD/wiki/Web-Commands
final class WebMan {
    var host: String
    var port: Int
    var password: String

    init(host: String, port: Int = 80, password: String = "") {
        self.host = host
        self.port = port
        self.password = password
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 30
        c.httpMaximumConnectionsPerHost = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    var base: String { port == 80 ? "http://\(host)" : "http://\(host):\(port)" }

    /// Path-style command; keeps '/' and encodes the rest.
    func url(_ path: String) -> URL? {
        let enc = path.addingPercentEncoding(withAllowedCharacters: .webManPath) ?? path
        return URL(string: base + enc)
    }

    @discardableResult
    func get(_ path: String, timeout: TimeInterval = 8) async throws -> Data {
        guard let u = url(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
        return data
    }

    func text(_ path: String, timeout: TimeInterval = 8) async throws -> String {
        let d = try await get(path, timeout: timeout)
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    // MARK: status

    struct Status {
        var cpu: Int?
        var rsx: Int?
        var fan: Int?
        var uptime: String?
        var firmware: String?
    }

    /// Reachability + webMAN check.
    func ping() async -> Bool {
        guard let t = try? await text("/cpursx.ps3", timeout: 3) else { return false }
        return t.localizedCaseInsensitiveContains("CPU") || t.localizedCaseInsensitiveContains("webMAN")
    }

    func status() async throws -> Status {
        let t = try await text("/cpursx.ps3")
        var s = Status()
        s.cpu = Self.firstInt(after: "CPU:", in: t)
        s.rsx = Self.firstInt(after: "RSX:", in: t)
        s.fan = Self.firstInt(after: "FAN:", in: t)
        if let r = t.range(of: "Startup:") ?? t.range(of: "Play:") {
            let tail = t[r.upperBound...].prefix(24)
            s.uptime = String(tail).components(separatedBy: CharacterSet(charactersIn: "<\n")).first?.trimmingCharacters(in: .whitespaces)
        }
        if let r = t.range(of: "Firmware") {
            let tail = t[r.upperBound...].prefix(40)
            s.firmware = String(tail).components(separatedBy: CharacterSet(charactersIn: "<\n")).first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        }
        return s
    }

    static func firstInt(after key: String, in t: String) -> Int? {
        guard let r = t.range(of: key) else { return nil }
        var digits = ""
        for ch in t[r.upperBound...].prefix(16) {
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    // MARK: games

    func games() async throws -> [Game] {
        // the XMB list webMAN builds for its "My Games" column
        if let d = try? await get("/dev_hdd0/xmlhost/game_plugin/mygames.xml", timeout: 12) {
            let list = GameParser.parseXML(d)
            if !list.isEmpty { return list }
        }
        // fallback: the web game list
        let html = try await text("/index.ps3", timeout: 25)
        return GameParser.parseIndexHTML(html)
    }

    func refreshGames() async { _ = try? await get("/refresh.ps3", timeout: 60) }

    func play(_ g: Game) async throws { _ = try await get("/play.ps3" + g.path, timeout: 20) }
    func mount(_ g: Game) async throws { _ = try await get("/mount_ps3" + g.path, timeout: 20) }
    func unmount() async throws { _ = try await get("/mount_ps3/unmount") }

    // MARK: system

    func pad(_ buttons: String) async { _ = try? await get("/pad.ps3?" + buttons, timeout: 3) }
    func popup(_ msg: String) async throws { _ = try await get("/popup.ps3?" + msg) }
    func eject() async throws { _ = try await get("/eject.ps3") }
    func insert() async throws { _ = try await get("/insert.ps3") }
    func restart() async throws { _ = try await get("/restart.ps3" + pwd) }
    func shutdown() async throws { _ = try await get("/shutdown.ps3" + pwd) }
    func quitGame() async throws { _ = try await get("/xmb.ps3$exit") }
    func installURL(_ url: String) async throws { _ = try await get("/install.ps3?url=" + url, timeout: 20) }
    func installPath(_ path: String) async throws { _ = try await get("/install.ps3" + path, timeout: 20) }
    func screenshot() async throws { _ = try await get("/browser.ps3$screenshot_xmb", timeout: 15) }

    private var pwd: String { password.isEmpty ? "" : "?pwd=" + password }

    /// URL of a file on the PS3 served by webMAN (icons, covers ...).
    func fileURL(_ path: String) -> URL? { url(path) }
}

extension CharacterSet {
    static let webManPath: CharacterSet = {
        var s = CharacterSet.urlPathAllowed
        s.insert(charactersIn: "?=&$")
        s.remove(charactersIn: "#")
        return s
    }()
}
