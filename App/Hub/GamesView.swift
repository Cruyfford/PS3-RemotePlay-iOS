import SwiftUI
import UIKit

struct GamesView: View {
    @EnvironmentObject var store: HubStore
    @State private var filter: Platform? = nil
    @State private var favoritesOnly = false
    @State private var query = ""
    @State private var selected: Game?

    private var shown: [Game] {
        store.games.filter { g in
            (filter == nil || g.platform == filter) &&
            (!favoritesOnly || store.favorites.contains(g.path)) &&
            (query.isEmpty || g.title.localizedCaseInsensitiveContains(query) || (g.titleID ?? "").localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L.t("Games", "الألعاب")).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundColor(Theme.text)
                Spacer()
                Text("\(shown.count)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(Theme.dim)
                Button {
                    Task { await store.loadGames(rescan: true) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        .frame(width: 38, height: 38).glass(19)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 10)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.dim)
                TextField(L.t("Search games or title ID", "ابحث باسم اللعبة أو رقمها"), text: $query)
                    .foregroundColor(Theme.text).disableAutocorrection(true).autocapitalization(.none)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.dim) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11).glass(16).padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(L.t("All", "الكل"), selected: filter == nil && !favoritesOnly, color: Theme.accent) { filter = nil; favoritesOnly = false }
                    chip(L.t("★ Favorites", "★ المفضلة"), selected: favoritesOnly, color: .yellow) { favoritesOnly.toggle() }
                    ForEach(Platform.allCases.filter { p in store.games.contains { $0.platform == p } }) { p in
                        chip(p.label, selected: filter == p, color: Theme.platformColor(p)) { filter = filter == p ? nil : p }
                    }
                }
                .padding(.horizontal, 18)
            }

            if store.loading && store.games.isEmpty {
                Spacer()
                ProgressView().tint(.white)
                Text(L.t("Reading your library…", "جارٍ قراءة مكتبتك…")).foregroundColor(Theme.dim).font(.system(size: 14, design: .rounded))
                Spacer()
            } else if shown.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "gamecontroller").font(.system(size: 40)).foregroundColor(Theme.dim)
                    Text(store.games.isEmpty ? L.t("No games yet. Pull to load them from webMAN.", "لا توجد ألعاب بعد. اسحب للأسفل لتحميلها من webMAN.")
                                             : L.t("Nothing matches", "لا توجد نتائج"))
                        .foregroundColor(Theme.dim).multilineTextAlignment(.center).font(.system(size: 14, design: .rounded))
                }
                .padding()
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)], spacing: 18) {
                        ForEach(shown) { g in
                            Button { selected = g } label: { GameCard(game: g) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { store.play(g) } label: { Label(L.t("Play", "تشغيل"), systemImage: "play.fill") }
                                    Button { store.mount(g) } label: { Label(L.t("Mount only", "تركيب فقط"), systemImage: "externaldrive.fill") }
                                    Button { store.toggleFavorite(g) } label: {
                                        Label(store.favorites.contains(g.path) ? L.t("Remove favorite", "إزالة من المفضلة") : L.t("Add to favorites", "إضافة للمفضلة"),
                                              systemImage: "star")
                                    }
                                    Button { UIPasteboard.general.string = g.path } label: { Label(L.t("Copy path", "نسخ المسار"), systemImage: "doc.on.doc") }
                                }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 20).padding(.top, 4)
                }
                .refreshable { await store.loadGames() }
            }
        }
        .sheet(item: $selected) { g in GameDetail(game: g).environmentObject(store) }
    }

    private func chip(_ t: String, selected: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: { Theme.haptic(); withAnimation(.easeOut(duration: 0.2)) { action() } }) {
            Text(t).font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(selected ? .white : Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? color.opacity(0.85) : Color.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(selected ? 0 : 0.1)))
        }
        .buttonStyle(.plain)
    }
}

struct GameDetail: View {
    @EnvironmentObject var store: HubStore
    @Environment(\.dismiss) private var dismiss
    let game: Game

    var body: some View {
        ZStack {
            HubBackground()
            // blurred cover as backdrop
            CoverImage(game: game, corner: 0).blur(radius: 40).opacity(0.45).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)
                    CoverImage(game: game, corner: 24)
                        .aspectRatio(0.72, contentMode: .fit)
                        .frame(maxWidth: 230)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                    VStack(spacing: 8) {
                        Text(game.title).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundColor(.white).multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            tag(game.platform.label, Theme.platformColor(game.platform))
                            if let id = game.titleID { tag(id, Color.white.opacity(0.15)) }
                            tag(game.device, Color.white.opacity(0.15))
                        }
                    }
                    Button {
                        store.play(game)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                            Text(L.t("Play on PS3", "شغّل على الجهاز")).font(.system(size: 18, weight: .heavy, design: .rounded))
                        }
                        .foregroundColor(.black).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 12) {
                        action(L.t("Mount", "تركيب"), "externaldrive.fill") { store.mount(game) }
                        action(store.favorites.contains(game.path) ? L.t("Favorite", "مفضلة") : L.t("Add favorite", "للمفضلة"),
                               store.favorites.contains(game.path) ? "star.fill" : "star") { store.toggleFavorite(game) }
                        action(L.t("Unmount", "إلغاء"), "eject.fill") { store.run(L.t("Unmounted", "تم الإلغاء")) { try await store.client.unmount() } }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t("Location", "المكان")).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(Theme.dim)
                        Text(game.path).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.text).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass(16)
                }
                .padding(.horizontal, 22).padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5).background(c, in: Capsule())
    }

    private func action(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: { Theme.haptic(); a() }) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(t).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 12).glass(16)
        }
        .buttonStyle(.plain)
    }
}
