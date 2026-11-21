import SwiftUI
import UIKit

/// Memory + disk image cache for covers and icons.
final class ImageCache {
    static let shared = ImageCache()
    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mem.countLimit = 400
    }

    private func file(_ key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return dir.appendingPathComponent(String(safe.suffix(180)))
    }

    func cached(_ key: String) -> UIImage? {
        if let m = mem.object(forKey: key as NSString) { return m }
        if let d = try? Data(contentsOf: file(key)), let img = UIImage(data: d) { mem.setObject(img, forKey: key as NSString); return img }
        return nil
    }

    func missing(_ key: String) -> Bool { FileManager.default.fileExists(atPath: file(key).path + ".none") }

    /// first URL that yields an image wins; result stored under key
    func load(key: String, urls: [URL]) async -> UIImage? {
        if let c = cached(key) { return c }
        if missing(key) { return nil }
        lock.lock()
        if let t = inflight[key] { lock.unlock(); return await t.value }
        let task = Task<UIImage?, Never> { [session, dir] in
            _ = dir
            for u in urls {
                guard let r = try? await session.data(from: u) else { continue }
                let data = r.0, resp = r.1
                if let h = resp as? HTTPURLResponse, h.statusCode != 200 { continue }
                guard data.count > 200, let img = UIImage(data: data) else { continue }
                try? data.write(to: self.file(key))
                self.mem.setObject(img, forKey: key as NSString)
                return img
            }
            return nil
        }
        inflight[key] = task
        lock.unlock()
        let img = await task.value
        lock.lock(); inflight[key] = nil; lock.unlock()
        if img == nil && !urls.isEmpty { FileManager.default.createFile(atPath: file(key).path + ".none", contents: Data()) }
        return img
    }

    func clear() {
        mem.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Game artwork: online box art when available, else webMAN's icon, else a generated tile.
struct CoverImage: View {
    @EnvironmentObject var store: HubStore
    let game: Game
    var corner: CGFloat = 16
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: game.path) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.platformColor(game.platform).opacity(0.9), Theme.bg1], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Text(game.platform.label).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(0.85))
                Text(game.title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 8)
            }
        }
    }

    private func load() async {
        var urls: [URL] = []
        if store.hdCovers { urls += CoverSource.urls(for: game) }
        if let icon = game.icon, icon.hasPrefix("/"), let u = store.client.fileURL(icon) { urls.append(u) }
        if urls.isEmpty { return }
        let key = (store.hdCovers ? "hd_" : "ic_") + game.path
        image = await ImageCache.shared.load(key: key, urls: urls)
    }
}
