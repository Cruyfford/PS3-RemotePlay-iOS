import Foundation

/// Connection settings, kept in UserDefaults.
final class RPSettings: ObservableObject {
    @Published var host: String { didSet { store.set(host, forKey: "host") } }
    @Published var pspID: String { didSet { store.set(pspID, forKey: "pspID") } }
    @Published var pkey: String { didSet { store.set(pkey, forKey: "pkey") } }
    @Published var mac: String { didSet { store.set(mac, forKey: "mac") } }
    @Published var nickname: String { didSet { store.set(nickname, forKey: "nickname") } }
    @Published var bitrate: Int { didSet { store.set(bitrate, forKey: "bitrate") } }

    private let store = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        pspID = d.string(forKey: "pspID") ?? ""
        pkey = d.string(forKey: "pkey") ?? ""
        mac = d.string(forKey: "mac") ?? ""
        nickname = d.string(forKey: "nickname") ?? "iPhone"
        let b = d.integer(forKey: "bitrate")
        bitrate = b > 0 ? b : 1024000
    }

    /// Number of bytes in a hex string, or nil when it is not valid hex.
    static func hexByteCount(_ text: String) -> Int? {
        let cleaned = text.filter { !": -\n\t\r".contains($0) }
        if cleaned.isEmpty || cleaned.count % 2 != 0 { return nil }
        for ch in cleaned where !ch.isHexDigit { return nil }
        return cleaned.count / 2
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A message describing what is missing, or nil when the settings are usable.
    var problem: String? {
        if trimmedHost.isEmpty { return "Enter the PS3 IP address." }
        if RPSettings.hexByteCount(pspID) != 16 { return "Device ID must be 32 hex digits." }
        if RPSettings.hexByteCount(pkey) != 16 { return "Key must be 32 hex digits." }
        if RPSettings.hexByteCount(mac) != 6 { return "Device MAC must be 12 hex digits." }
        return nil
    }

    /// Reads the ps3rp.json produced by tools/ps3rp.py.
    func importJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else { return false }
        guard let obj = parsed as? [String: Any] else { return false }
        var found = false
        if let v = obj["psp_id"] as? String { pspID = v; found = true }
        if let v = obj["pkey"] as? String { pkey = v; found = true }
        if let v = obj["psp_mac"] as? String { mac = v; found = true }
        if let v = obj["nickname"] as? String, !v.isEmpty { nickname = v }
        if let v = obj["ps3_ip"] as? String, !v.isEmpty { host = v }
        return found
    }
}
