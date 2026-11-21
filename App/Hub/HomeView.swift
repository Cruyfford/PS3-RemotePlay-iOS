import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: HubStore
    @Binding var tab: HubTab
    @State private var message = ""
    @State private var askShutdown = false
    @State private var askRestart = false
    @State private var showMessage = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                consoleCard
                if let last = store.lastPlayed.flatMap({ store.game(at: $0) }) { continueCard(last) }
                if !recentGames.isEmpty {
                    SectionTitle(text: L.t("Recently played", "لعبت مؤخراً"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(recentGames) { g in
                                Button { store.play(g) } label: { GameCard(game: g, width: 118) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                SectionTitle(text: L.t("Quick actions", "أوامر سريعة"))
                quickGrid
                stats
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        }
        .refreshable { await store.refreshStatus(); await store.loadGames() }
        .alert(L.t("Turn off the PS3?", "إطفاء الجهاز؟"), isPresented: $askShutdown) {
            Button(L.t("Turn off", "إطفاء"), role: .destructive) { store.run(L.t("Shutting down", "جارٍ الإطفاء")) { try await store.client.shutdown() } }
            Button(L.t("Cancel", "إلغاء"), role: .cancel) {}
        }
        .alert(L.t("Restart the PS3?", "إعادة تشغيل الجهاز؟"), isPresented: $askRestart) {
            Button(L.t("Restart", "إعادة التشغيل"), role: .destructive) { store.run(L.t("Restarting", "جارٍ إعادة التشغيل")) { try await store.client.restart() } }
            Button(L.t("Cancel", "إلغاء"), role: .cancel) {}
        }
        .sheet(isPresented: $showMessage) { messageSheet }
    }

    private var recentGames: [Game] { store.recents.compactMap { store.game(at: $0) }.prefix(12).map { $0 } }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PS3 Hub").font(.system(size: 32, weight: .heavy, design: .rounded)).foregroundColor(Theme.text)
                Text(L.t("Your console, from your pocket", "جهازك في جيبك")).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(Theme.dim)
            }
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        let on = store.online == true
        return HStack(spacing: 6) {
            Circle().fill(on ? Theme.accent2 : (store.online == false ? Theme.warm : Theme.dim)).frame(width: 9, height: 9)
                .shadow(color: on ? Theme.accent2 : .clear, radius: 6)
            Text(on ? L.t("Online", "متصل") : store.online == false ? L.t("Offline", "غير متصل") : "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Theme.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).glass(16)
    }

    private var consoleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "playstation.logo").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PlayStation 3").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(Theme.text)
                    Text(store.configured ? store.host : L.t("Not set up", "غير مُعدّ")).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.dim)
                    if let fw = store.status.firmware, !fw.isEmpty { Text(fw).font(.system(size: 11)).foregroundColor(Theme.dim).lineLimit(1) }
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Gauge2(label: "CPU", value: store.status.cpu, unit: "°C", maxValue: 90)
                Gauge2(label: "RSX", value: store.status.rsx, unit: "°C", maxValue: 90)
                Gauge2(label: L.t("Fan", "المروحة"), value: store.status.fan, unit: "%", maxValue: 100)
            }
        }
        .padding(18).glass(26)
    }

    private func continueCard(_ g: Game) -> some View {
        Button { store.play(g) } label: {
            ZStack(alignment: .bottomLeading) {
                CoverImage(game: g, corner: 26).frame(height: 190).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("Continue playing", "تابع اللعب")).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(Theme.accent2)
                        Text(g.title).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundColor(.white).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundColor(.black)
                        .frame(width: 48, height: 48).background(Color.white, in: Circle())
                }
                .padding(18)
            }
        }
        .buttonStyle(.plain)
    }

    private var quickGrid: some View {
        let items: [(String, String, Color, () -> Void)] = [
            (L.t("Controller", "اليد"), "gamecontroller.fill", Theme.accent, { tab = .pad }),
            (L.t("Exit game", "الخروج من اللعبة"), "xmark.circle.fill", Theme.warm, { store.run(L.t("Back to XMB", "رجوع إلى XMB")) { try await store.client.quitGame() } }),
            (L.t("Unmount", "إلغاء التركيب"), "eject.fill", Theme.accent2, { store.run(L.t("Unmounted", "تم إلغاء التركيب")) { try await store.client.unmount() } }),
            (L.t("Eject disc", "إخراج القرص"), "opticaldiscdrive.fill", Theme.accent, { store.run(L.t("Ejected", "تم الإخراج")) { try await store.client.eject() } }),
            (L.t("Rescan games", "تحديث الألعاب"), "arrow.clockwise", Theme.accent2, { Task { await store.loadGames(rescan: true); store.show(L.t("Library updated", "تم تحديث المكتبة")) } }),
            (L.t("Message", "رسالة"), "text.bubble.fill", Theme.accent, { showMessage = true }),
            (L.t("Screenshot", "لقطة شاشة"), "camera.fill", Theme.accent2, { store.run(L.t("Saved on the PS3", "حُفظت على الجهاز")) { try await store.client.screenshot() } }),
            (L.t("Restart", "إعادة تشغيل"), "arrow.triangle.2.circlepath", Theme.warm, { askRestart = true }),
            (L.t("Turn off", "إطفاء"), "power", Theme.warm, { askShutdown = true }),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(0..<items.count, id: \.self) { i in
                let it = items[i]
                Button(action: { Theme.haptic(); it.3() }) {
                    VStack(spacing: 8) {
                        Image(systemName: it.1).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                            .frame(width: 44, height: 44).background(it.2.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text(it.0).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(Theme.text)
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96).glass(20)
                }
                .buttonStyle(.plain)
                .disabled(!store.configured)
            }
        }
    }

    private var stats: some View {
        let counts = Dictionary(grouping: store.games, by: { $0.platform }).mapValues { $0.count }
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: L.t("Library", "المكتبة"))
            HStack(spacing: 10) {
                ForEach([Platform.ps3, .ps2, .ps1, .psp], id: \.self) { p in
                    VStack(spacing: 4) {
                        Text("\(counts[p] ?? 0)").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(.white)
                        Text(p.label).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.platformColor(p))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12).glass(18)
                }
            }
        }
        .onTapGesture { tab = .games }
    }

    private var messageSheet: some View {
        NavigationView {
            Form {
                Section(footer: Text(L.t("Shown as a notification on the TV.", "تظهر كإشعار على الشاشة."))) {
                    TextField(L.t("Message", "الرسالة"), text: $message)
                }
                Button(L.t("Send", "إرسال")) {
                    let m = message
                    showMessage = false
                    store.run(L.t("Sent", "أُرسلت")) { try await store.client.popup(m) }
                }
                .disabled(message.isEmpty)
            }
            .navigationTitle(L.t("Message to PS3", "رسالة إلى الجهاز"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Ring gauge for temperatures and fan speed.
struct Gauge2: View {
    let label: String
    let value: Int?
    let unit: String
    let maxValue: Double

    var body: some View {
        let v = Double(value ?? 0)
        let frac = min(max(v / maxValue, 0), 1)
        let color: Color = unit == "%" ? Theme.accent2 : (v >= 75 ? Theme.warm : v >= 60 ? Color.orange : Theme.accent2)
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
                Circle().trim(from: 0, to: frac).stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: frac)
                Text(value.map { "\($0)\(unit)" } ?? "—").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundColor(.white)
            }
            .frame(width: 66, height: 66)
            Text(label).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.dim)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Poster card used in rows and grids.
struct GameCard: View {
    @EnvironmentObject var store: HubStore
    let game: Game
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                CoverImage(game: game, corner: 16)
                    .aspectRatio(0.72, contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                HStack(spacing: 4) {
                    if store.favorites.contains(game.path) {
                        Image(systemName: "star.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.yellow)
                    }
                    Text(game.platform.label).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundColor(.white)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Theme.platformColor(game.platform).opacity(0.9), in: Capsule())
                .padding(7)
            }
            Text(game.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(Theme.text).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
    }
}
