import SwiftUI
import Darwin

struct SettingsView: View {
    @EnvironmentObject var store: HubStore
    @State private var scanning = false
    @State private var found: [String] = []
    @State private var testing = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L.t("Settings", "الإعدادات")).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundColor(Theme.text)

                card(L.t("PlayStation 3", "جهاز PS3")) {
                    field(L.t("IP address", "عنوان IP"), text: $store.host, placeholder: "192.168.1.20", keyboard: .numbersAndPunctuation)
                    HStack(spacing: 10) {
                        PillButton(title: scanning ? L.t("Searching…", "جارٍ البحث…") : L.t("Find my PS3", "ابحث عن جهازي"), icon: "dot.radiowaves.left.and.right", tint: Theme.accent) { scan() }
                            .disabled(scanning)
                        PillButton(title: testing ? "…" : L.t("Test", "اختبار"), icon: "checkmark.seal.fill", tint: Theme.accent2) { test() }
                    }
                    if !found.isEmpty {
                        ForEach(found, id: \.self) { ip in
                            Button {
                                store.host = ip
                                Task { await store.refreshStatus(); await store.loadGames() }
                            } label: {
                                HStack {
                                    Image(systemName: "playstation.logo")
                                    Text(ip).font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    Spacer()
                                    if store.host == ip { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent2) }
                                }
                                .foregroundColor(Theme.text).padding(12).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(L.t("Needs webMAN MOD on the PS3 and both devices on the same Wi-Fi.", "يحتاج webMAN MOD على الجهاز، والجهازان على نفس شبكة الواي فاي."))
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }

                card(L.t("Connection", "الاتصال")) {
                    stepper(L.t("webMAN port", "منفذ webMAN"), value: $store.httpPort)
                    stepper(L.t("FTP port", "منفذ FTP"), value: $store.ftpPort)
                    HStack(spacing: 8) {
                        presetButton("webMAN FTP · 21") { store.ftpPort = 21 }
                        presetButton("File Manager FTP · 2121") { store.ftpPort = 2121 }
                    }
                    field(L.t("webMAN admin password (optional)", "كلمة مرور webMAN (اختياري)"), text: $store.password, placeholder: "", secure: true)
                }

                card(L.t("Appearance", "المظهر")) {
                    Toggle(isOn: $store.arabic) { Text(L.t("Arabic interface", "الواجهة بالعربية")).foregroundColor(Theme.text) }.tint(Theme.accent)
                    Toggle(isOn: $store.hdCovers) { Text(L.t("HD box art from the internet", "أغلفة عالية الدقة من الإنترنت")).foregroundColor(Theme.text) }.tint(Theme.accent)
                    Button {
                        ImageCache.shared.clear()
                        store.show(L.t("Cover cache cleared", "تم مسح الأغلفة المحفوظة"))
                    } label: {
                        Label(L.t("Clear cover cache", "مسح الأغلفة المحفوظة"), systemImage: "trash").foregroundColor(Theme.warm)
                    }
                }

                card(L.t("About", "حول")) {
                    Text("PS3 Hub · CRUYFFORD").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(Theme.text)
                    Text(L.t("Games, controller and files use webMAN MOD's web commands and FTP. Remote Play uses the PS3's own PREMO protocol.",
                             "الألعاب واليد والملفات تعمل عبر أوامر webMAN MOD وخادم FTP. البث يعمل عبر بروتوكول Remote Play الخاص بالجهاز."))
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(Theme.accent2).textCase(.uppercase)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(22)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .keyboardType(keyboard).autocapitalization(.none).disableAutocorrection(true)
            .foregroundColor(Theme.text).font(.system(size: 16, weight: .semibold, design: .monospaced))
            .padding(12).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func stepper(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).foregroundColor(Theme.text)
            Spacer()
            TextField("", value: value, formatter: NumberFormatter())
                .keyboardType(.numberPad).multilineTextAlignment(.center)
                .frame(width: 80).padding(8).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .foregroundColor(Theme.text).font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
    }

    private func presetButton(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: { Theme.haptic(); a() }) {
            Text(t).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func test() {
        testing = true
        Task {
            let ok = await store.client.ping()
            testing = false
            store.show(ok ? L.t("webMAN found ✓", "تم العثور على webMAN ✓") : L.t("No answer from webMAN", "لا يوجد رد من webMAN"))
            if ok { await store.refreshStatus(); await store.loadGames() }
        }
    }

    /// Probe every address of the phone's Wi-Fi /24 for webMAN.
    private func scan() {
        guard let prefix = Self.wifiPrefix() else { store.show(L.t("Connect the iPhone to Wi-Fi", "اتصل بشبكة واي فاي")); return }
        scanning = true
        found = []
        let port = store.httpPort
        Task {
            let hits = await withTaskGroup(of: String?.self) { group -> [String] in
                for i in 1...254 {
                    let ip = "\(prefix).\(i)"
                    group.addTask {
                        let w = WebMan(host: ip, port: port)
                        return await w.ping() ? ip : nil
                    }
                }
                var r: [String] = []
                for await x in group { if let x = x { r.append(x) } }
                return r
            }
            found = hits.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            scanning = false
            if found.isEmpty { store.show(L.t("No PS3 with webMAN found", "لم يُعثر على جهاز عليه webMAN")) }
            else if found.count == 1 && store.host.isEmpty { store.host = found[0]; await store.refreshStatus(); await store.loadGames() }
        }
    }

    static func wifiPrefix() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var result: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), name == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                let parts = ip.split(separator: ".")
                if parts.count == 4 { result = parts[0...2].joined(separator: ".") }
            }
            ptr = p.pointee.ifa_next
        }
        return result
    }
}
