import Foundation

enum Platform: String, CaseIterable, Identifiable, Codable {
    case ps3, ps2, ps1, psp, retro, video, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ps3: return "PS3"
        case .ps2: return "PS2"
        case .ps1: return "PS1"
        case .psp: return "PSP"
        case .retro: return L.t("Retro", "ريترو")
        case .video: return L.t("Video", "فيديو")
        case .other: return L.t("Other", "أخرى")
        }
    }

    static func from(path: String) -> Platform {
        let p = path.uppercased()
        if p.contains("/PS3ISO") || p.contains("/GAMES/") || p.contains("/GAMEZ/") || p.contains("/GAME/") || p.contains("PS3_GAME") { return .ps3 }
        if p.contains("/PS2ISO") || p.contains("/PS2DISC") { return .ps2 }
        if p.contains("/PSXISO") || p.contains("/PSXGAMES") || p.contains("/PSXISO") { return .ps1 }
        if p.contains("/PSPISO") || p.contains("/ISO/") { return .psp }
        if p.contains("/ROMS") { return .retro }
        if p.contains("/BDISO") || p.contains("/DVDISO") || p.contains("/VIDEO") { return .video }
        return .other
    }
}

struct Game: Identifiable, Hashable, Codable {
    var id: String { path }
    var title: String
    var path: String          // PS3 path used with /play.ps3 and /mount_ps3
    var icon: String?         // PS3 path of webMAN's icon
    var titleID: String?      // BLUS12345 / SLUS-12345 ...
    var platform: Platform

    var device: String {
        let parts = path.split(separator: "/")
        guard let first = parts.first else { return "" }
        let d = String(first)
        if d.hasPrefix("dev_hdd") { return "HDD" }
        if d.hasPrefix("dev_usb") { return "USB " + d.replacingOccurrences(of: "dev_usb", with: "") }
        if d.hasPrefix("ntfs") || d.hasPrefix("dev_ntfs") { return "NTFS" }
        if d.hasPrefix("net") { return "NET" }
        return d
    }
}

enum GameParser {
    /// webMAN's mygames.xml: <T key=".." ..><P key="icon"><>..</></P><P key="title"><>..</></P><P key="module_action"><>http://127.0.0.1/mount_ps3/..</></P>...</T>
    static func parseXML(_ data: Data) -> [Game] {
        let s = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var out: [Game] = []
        var seen = Set<String>()
        var search = s.startIndex..<s.endIndex
        while let start = s.range(of: "<T key=", range: search) {
            guard let end = s.range(of: "</T>", range: start.upperBound..<s.endIndex) else { break }
            let item = String(s[start.lowerBound..<end.lowerBound])
            search = end.upperBound..<s.endIndex
            let pairs = pairsIn(item)
            guard let action = pairs["module_action"], let r = action.range(of: "/mount_ps3") else { continue }
            let path = decodePath(String(action[r.upperBound...]))
            if path.isEmpty || path == "/unmount" || seen.contains(path) { continue }
            seen.insert(path)
            let title = entities(pairs["title"] ?? (path.split(separator: "/").last.map(String.init) ?? path))
            let info = pairs["info"] ?? ""
            out.append(Game(title: cleanTitle(title), path: path, icon: pairs["icon"], titleID: findID(in: info + " " + path + " " + title),
                            platform: Platform.from(path: path)))
        }
        return out
    }

    private static func pairsIn(_ item: String) -> [String: String] {
        var d: [String: String] = [:]
        var search = item.startIndex..<item.endIndex
        while let k = item.range(of: "<P key=\"", range: search) {
            guard let ke = item.range(of: "\"", range: k.upperBound..<item.endIndex) else { break }
            let key = String(item[k.upperBound..<ke.lowerBound])
            guard let vs = item.range(of: "<>", range: ke.upperBound..<item.endIndex),
                  let ve = item.range(of: "</>", range: vs.upperBound..<item.endIndex) else { break }
            d[key] = String(item[vs.upperBound..<ve.lowerBound])
            search = ve.upperBound..<item.endIndex
        }
        return d
    }

    /// /index.ps3 fallback: links to /mount.ps3<path> with an image and a title
    static func parseIndexHTML(_ s: String) -> [Game] {
        var out: [Game] = []
        var seen = Set<String>()
        var search = s.startIndex..<s.endIndex
        while let r = s.range(of: "href=\"/mount.ps3", range: search) {
            guard let e = s.range(of: "\"", range: r.upperBound..<s.endIndex) else { break }
            let path = decodePath(String(s[r.upperBound..<e.lowerBound]))
            search = e.upperBound..<s.endIndex
            if path.isEmpty || seen.contains(path) || path.hasPrefix("/unmount") { continue }
            seen.insert(path)
            // nearest img src after the link
            var icon: String?
            let window = s[e.upperBound..<(s.index(e.upperBound, offsetBy: 600, limitedBy: s.endIndex) ?? s.endIndex)]
            if let i = window.range(of: "src=\""), let ie = window.range(of: "\"", range: i.upperBound..<window.endIndex) {
                icon = decodePath(String(window[i.upperBound..<ie.lowerBound]))
            }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            out.append(Game(title: cleanTitle(stripExt(name)), path: path, icon: icon, titleID: findID(in: path), platform: Platform.from(path: path)))
        }
        return out
    }

    static func decodePath(_ s: String) -> String {
        var p = s.removingPercentEncoding ?? s
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        return entities(p)
    }

    static func entities(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    static func stripExt(_ n: String) -> String {
        for e in [".iso", ".ISO", ".bin", ".BIN", ".cue", ".CUE", ".img", ".mdf", ".zip", ".7z"] where n.hasSuffix(e) {
            return String(n.dropLast(e.count))
        }
        return n
    }

    static func cleanTitle(_ t: String) -> String {
        var s = stripExt(t)
        // drop trailing [BLUS12345] / (USA) tags
        while let r = s.range(of: "\\s*[\\[(][^\\])]*[\\])]\\s*$", options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? t : s.trimmingCharacters(in: .whitespaces)
    }

    /// PS3: BLUS12345 / NPUB12345; PS1/PS2: SLUS-12345 / SLES_123.45
    static func findID(in s: String) -> String? {
        let u = s.uppercased()
        if let r = u.range(of: "[A-Z]{4}[0-9]{5}", options: .regularExpression) { return String(u[r]) }
        if let r = u.range(of: "[A-Z]{4}[-_][0-9]{3}\\.?[0-9]{2}", options: .regularExpression) {
            let raw = String(u[r]).replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "")
            return raw
        }
        return nil
    }
}

/// Online box art (higher quality than the XMB icons).
enum CoverSource {
    static func urls(for g: Game) -> [URL] {
        var out: [URL] = []
        if let id = g.titleID {
            switch g.platform {
            case .ps3:
                if !id.contains("-") {
                    for reg in ["US", "EN", "JA", "FR", "DE"] {
                        if let u = URL(string: "https://art.gametdb.com/ps3/coverM/\(reg)/\(id).jpg") { out.append(u) }
                    }
                }
            case .ps2:
                if id.contains("-"), let u = URL(string: "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/\(id).jpg") { out.append(u) }
            case .ps1:
                if id.contains("-"), let u = URL(string: "https://raw.githubusercontent.com/xlenore/psx-covers/main/covers/default/\(id).jpg") { out.append(u) }
            default: break
            }
        }
        return out
    }
}
