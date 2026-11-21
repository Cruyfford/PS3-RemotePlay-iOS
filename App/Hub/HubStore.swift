import Foundation
import SwiftUI

/// App-wide state: the console, its game library, favorites and recents, connection status.
@MainActor
final class HubStore: ObservableObject {
    @Published var host: String { didSet { save(); rebuildClient() } }
    @Published var httpPort: Int { didSet { save(); rebuildClient() } }
    @Published var ftpPort: Int { didSet { save() } }
    @Published var password: String { didSet { save(); rebuildClient() } }
    @Published var arabic: Bool { didSet { UserDefaults.standard.set(arabic, forKey: "hub.arabic"); L.arabic = arabic } }
    @Published var hdCovers: Bool { didSet { save() } }

    @Published var games: [Game] = []
    @Published var favorites: Set<String> = []
    @Published var recents: [String] = []
    @Published var online: Bool? = nil
    @Published var status = WebMan.Status()
    @Published var loading = false
    @Published var toast: String?
    @Published var lastPlayed: String?

    private(set) var client: WebMan
    private var poller: Task<Void, Never>?
    private let d = UserDefaults.standard

    init() {
        host = d.string(forKey: "hub.host") ?? ""
        let hp = d.integer(forKey: "hub.http"); httpPort = hp > 0 ? hp : 80
        let fp = d.integer(forKey: "hub.ftp"); ftpPort = fp > 0 ? fp : 21
        password = d.string(forKey: "hub.pwd") ?? ""
        arabic = L.arabic
        hdCovers = d.object(forKey: "hub.hdcovers") as? Bool ?? true
        favorites = Set(d.stringArray(forKey: "hub.favs") ?? [])
        recents = d.stringArray(forKey: "hub.recents") ?? []
        lastPlayed = d.string(forKey: "hub.last")
        client = WebMan(host: "", port: 80)
        rebuildClient()
        if let data = d.data(forKey: "hub.gamescache"), let g = try? JSONDecoder().decode([Game].self, from: data) { games = g }
    }

    private func save() {
        d.set(host, forKey: "hub.host"); d.set(httpPort, forKey: "hub.http"); d.set(ftpPort, forKey: "hub.ftp")
        d.set(password, forKey: "hub.pwd"); d.set(hdCovers, forKey: "hub.hdcovers")
    }

    private func rebuildClient() {
        client = WebMan(host: host.trimmingCharacters(in: .whitespaces), port: httpPort, password: password)
    }

    var configured: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    func show(_ msg: String) {
        toast = msg
        let current = msg
        Task { try? await Task.sleep(nanoseconds: 2_400_000_000); if self.toast == current { self.toast = nil } }
    }

    // MARK: polling

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func refreshStatus() async {
        guard configured else { online = nil; return }
        if let s = try? await client.status() { status = s; online = true } else { online = false }
    }

    // MARK: games

    func loadGames(rescan: Bool = false) async {
        guard configured else { return }
        loading = true
        defer { loading = false }
        if rescan { await client.refreshGames() }
        do {
            let list = try await client.games()
            games = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if let data = try? JSONEncoder().encode(games) { d.set(data, forKey: "hub.gamescache") }
            online = true
        } catch {
            online = false
            show(L.t("Couldn't reach webMAN on the PS3", "تعذر الاتصال بـ webMAN على الجهاز"))
        }
    }

    func play(_ g: Game) {
        Theme.haptic(.medium)
        recents.removeAll { $0 == g.path }
        recents.insert(g.path, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        d.set(recents, forKey: "hub.recents")
        lastPlayed = g.path; d.set(g.path, forKey: "hub.last")
        show(L.t("Starting \(g.title)…", "جارٍ تشغيل \(g.title)…"))
        Task {
            do { try await client.play(g) } catch { show(L.t("Launch failed", "فشل التشغيل")) }
        }
    }

    func mount(_ g: Game) {
        Task {
            do { try await client.mount(g); show(L.t("Mounted", "تم التركيب")) } catch { show(L.t("Mount failed", "فشل التركيب")) }
        }
    }

    func toggleFavorite(_ g: Game) {
        if favorites.contains(g.path) { favorites.remove(g.path) } else { favorites.insert(g.path) }
        d.set(Array(favorites), forKey: "hub.favs")
        Theme.haptic()
    }

    func game(at path: String) -> Game? { games.first { $0.path == path } }

    func run(_ label: String, _ op: @escaping () async throws -> Void) {
        Theme.haptic(.medium)
        Task {
            do { try await op(); show(label) } catch { show(L.t("Command failed", "فشل الأمر")) }
        }
    }
}
