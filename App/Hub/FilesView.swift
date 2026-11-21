import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// PS3 file browser over FTP: browse, download to the phone, upload (PKG → install), rename, delete.
@MainActor
final class FilesModel: ObservableObject {
    @Published var path = "/"
    @Published var entries: [FTPClient.Entry] = []
    @Published var busy = false
    @Published var error: String?
    @Published var transfer: (name: String, done: Int64, total: Int64)?

    private var ftp: FTPClient?
    private var key = ""

    func client(_ store: HubStore) -> FTPClient {
        let k = "\(store.host):\(store.ftpPort)"
        if ftp == nil || k != key { ftp?.close(); ftp = FTPClient(host: store.host.trimmingCharacters(in: .whitespaces), port: store.ftpPort); key = k }
        return ftp!
    }

    func reset() { ftp?.close(); ftp = nil }

    func load(_ store: HubStore, _ p: String? = nil) async {
        let target = p ?? path
        busy = true; error = nil
        defer { busy = false }
        do {
            entries = try await client(store).list(target)
            path = target
        } catch {
            reset()
            // one retry with a fresh connection
            do { entries = try await client(store).list(target); path = target }
            catch { self.error = error.localizedDescription }
        }
    }

    func join(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }

    var parent: String? {
        guard path != "/" else { return nil }
        var p = path
        if let r = p.range(of: "/", options: .backwards) { p = String(p[..<r.lowerBound]) }
        return p.isEmpty ? "/" : p
    }
}

struct FilesView: View {
    @EnvironmentObject var store: HubStore
    @StateObject private var model = FilesModel()
    @State private var importing = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var renameItem: FTPClient.Entry?
    @State private var newName = ""
    @State private var shareURL: URL?
    @State private var installURL = false
    @State private var pkgURL = ""

    private let shortcuts: [(String, String)] = [
        ("HDD", "/dev_hdd0"), ("USB 0", "/dev_usb000"), ("USB 1", "/dev_usb001"), ("packages", "/dev_hdd0/packages"),
        ("GAMES", "/dev_hdd0/GAMES"), ("PS3ISO", "/dev_hdd0/PS3ISO"), ("PS2ISO", "/dev_hdd0/PS2ISO"), ("game", "/dev_hdd0/game"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L.t("Files", "الملفات")).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundColor(Theme.text)
                Spacer()
                Menu {
                    Button { importing = true } label: { Label(L.t("Upload from iPhone", "رفع من الآيفون"), systemImage: "square.and.arrow.up") }
                    Button { folderName = ""; newFolder = true } label: { Label(L.t("New folder", "مجلد جديد"), systemImage: "folder.badge.plus") }
                    Button { pkgURL = ""; installURL = true } label: { Label(L.t("Install PKG from URL", "تثبيت PKG من رابط"), systemImage: "link") }
                    Button { Task { await model.load(store) } } label: { Label(L.t("Refresh", "تحديث"), systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundColor(.white).frame(width: 38, height: 38).glass(19)
                }
            }
            .padding(.horizontal, 18).padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shortcuts, id: \.1) { s in
                        Button { Task { await model.load(store, s.1) } } label: {
                            Text(s.0).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(model.path.hasPrefix(s.1) ? .white : Theme.text)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(model.path.hasPrefix(s.1) ? Theme.accent.opacity(0.85) : Color.white.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }

            HStack(spacing: 8) {
                if let up = model.parent {
                    Button { Task { await model.load(store, up) } } label: {
                        Image(systemName: "chevron.backward").font(.system(size: 14, weight: .bold)).foregroundColor(.white).frame(width: 30, height: 30).glass(15)
                    }
                    .buttonStyle(.plain)
                }
                Text(model.path).font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.dim).lineLimit(1).truncationMode(.head)
                Spacer()
                if model.busy { ProgressView().tint(.white) }
            }
            .padding(.horizontal, 18)

            if let t = model.transfer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Theme.text).lineLimit(1)
                    ProgressView(value: t.total > 0 ? Double(t.done) / Double(t.total) : 0).tint(Theme.accent2)
                    Text(ByteCountFormatter.string(fromByteCount: t.done, countStyle: .file) + (t.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: t.total, countStyle: .file) : ""))
                        .font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim)
                }
                .padding(14).glass(16).padding(.horizontal, 18)
            }

            if let e = model.error {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundColor(Theme.warm)
                    Text(e).foregroundColor(Theme.text).multilineTextAlignment(.center)
                    Text(L.t("Use port 21 for webMAN's FTP or 2121 for File Manager's FTP (Settings).", "استخدم المنفذ 21 لـ FTP في webMAN أو 2121 لـ FTP في File Manager (الإعدادات)."))
                        .font(.system(size: 12)).foregroundColor(Theme.dim).multilineTextAlignment(.center)
                    PillButton(title: L.t("Retry", "إعادة المحاولة"), icon: "arrow.clockwise") { Task { await model.load(store) } }
                }
                .padding(24)
                Spacer()
            } else {
                List {
                    ForEach(model.entries) { e in
                        row(e)
                            .listRowBackground(Color.white.opacity(0.04))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(e) } label: { Label(L.t("Delete", "حذف"), systemImage: "trash") }
                                Button { newName = e.name; renameItem = e } label: { Label(L.t("Rename", "تسمية"), systemImage: "pencil") }.tint(Theme.accent)
                            }
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.load(store) }
            }
        }
        .task { if model.entries.isEmpty && store.configured { await model.load(store, "/dev_hdd0") } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType.data, UTType.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { upload(urls) }
        }
        .alert(L.t("New folder", "مجلد جديد"), isPresented: $newFolder) {
            TextField(L.t("Name", "الاسم"), text: $folderName)
            Button(L.t("Create", "إنشاء")) { let n = folderName; Task { try? await model.client(store).mkdir(model.join(n)); await model.load(store) } }
            Button(L.t("Cancel", "إلغاء"), role: .cancel) {}
        }
        .alert(L.t("Rename", "إعادة تسمية"), isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField(L.t("Name", "الاسم"), text: $newName)
            Button(L.t("Rename", "تسمية")) {
                if let it = renameItem {
                    let from = model.join(it.name), to = model.join(newName)
                    Task { try? await model.client(store).rename(from, to); await model.load(store) }
                }
                renameItem = nil
            }
            Button(L.t("Cancel", "إلغاء"), role: .cancel) { renameItem = nil }
        }
        .alert(L.t("Install PKG from URL", "تثبيت PKG من رابط"), isPresented: $installURL) {
            TextField("https://…/file.pkg", text: $pkgURL)
            Button(L.t("Install", "تثبيت")) { let u = pkgURL; store.run(L.t("Download started on the PS3", "بدأ التحميل على الجهاز")) { try await store.client.installURL(u) } }
            Button(L.t("Cancel", "إلغاء"), role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ShareSheet(items: [u]) }
        }
    }

    private func row(_ e: FTPClient.Entry) -> some View {
        Button {
            if e.isDir { Task { await model.load(store, model.join(e.name)) } }
            else { download(e) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(e)).font(.system(size: 18, weight: .semibold)).foregroundColor(e.isDir ? Theme.accent : Theme.accent2)
                    .frame(width: 36, height: 36).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name).font(.system(size: 14.5, weight: .semibold, design: .rounded)).foregroundColor(Theme.text).lineLimit(1)
                    if !e.isDir { Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)).font(.system(size: 11.5)).foregroundColor(Theme.dim) }
                }
                Spacer()
                if e.name.lowercased().hasSuffix(".pkg") {
                    Button { store.run(L.t("Installing on the PS3", "جارٍ التثبيت على الجهاز")) { try await store.client.installPath(model.join(e.name)) } } label: {
                        Text(L.t("Install", "تثبيت")).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.accent2.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func icon(_ e: FTPClient.Entry) -> String {
        if e.isDir { return "folder.fill" }
        let n = e.name.lowercased()
        if n.hasSuffix(".pkg") { return "shippingbox.fill" }
        if n.hasSuffix(".iso") || n.hasSuffix(".bin") { return "opticaldisc" }
        if n.hasSuffix(".png") || n.hasSuffix(".jpg") { return "photo" }
        if n.hasSuffix(".mp4") || n.hasSuffix(".mkv") || n.hasSuffix(".avi") { return "film" }
        if n.hasSuffix(".mp3") || n.hasSuffix(".ogg") { return "music.note" }
        return "doc.fill"
    }

    private func download(_ e: FTPClient.Entry) {
        let remote = model.join(e.name)
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(e.name)
        model.transfer = (e.name, 0, e.size)
        Task {
            do {
                try await model.client(store).download(remote, to: local) { n in Task { @MainActor in model.transfer = (e.name, n, e.size) } }
                model.transfer = nil
                store.show(L.t("Saved to the app's Files folder", "حُفظ في مجلد التطبيق في Files"))
                shareURL = local
            } catch {
                model.transfer = nil
                model.reset()
                store.show(L.t("Download failed", "فشل التحميل"))
            }
        }
    }

    private func upload(_ urls: [URL]) {
        Task {
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                let fsz: Int? = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                let size = Int64(fsz ?? 0)
                let isPkg = u.pathExtension.lowercased() == "pkg"
                let dir = isPkg && !model.path.hasPrefix("/dev_hdd0/packages") ? "/dev_hdd0/packages" : model.path
                let remote = (dir == "/" ? "" : dir) + "/" + u.lastPathComponent
                model.transfer = (u.lastPathComponent, 0, size)
                do {
                    try await model.client(store).upload(u, to: remote) { n in Task { @MainActor in model.transfer = (u.lastPathComponent, n, size) } }
                    store.show(isPkg ? L.t("PKG sent to /dev_hdd0/packages", "أُرسل الـ PKG إلى /dev_hdd0/packages") : L.t("Uploaded", "تم الرفع"))
                } catch {
                    model.reset()
                    store.show(L.t("Upload failed", "فشل الرفع"))
                }
                model.transfer = nil
            }
            await model.load(store)
        }
    }

    private func delete(_ e: FTPClient.Entry) {
        let p = model.join(e.name)
        Task {
            do { try await model.client(store).delete(p, isDir: e.isDir); await model.load(store) }
            catch { store.show(L.t("Couldn't delete", "تعذر الحذف")) }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
