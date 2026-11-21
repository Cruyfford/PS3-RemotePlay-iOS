import SwiftUI

enum HubTab: Int, CaseIterable {
    case home, games, pad, files, stream, settings
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .games: return "square.grid.2x2.fill"
        case .pad: return "gamecontroller.fill"
        case .files: return "folder.fill"
        case .stream: return "play.tv.fill"
        case .settings: return "gearshape.fill"
        }
    }
    var title: String {
        switch self {
        case .home: return L.t("Home", "الرئيسية")
        case .games: return L.t("Games", "الألعاب")
        case .pad: return L.t("Controller", "اليد")
        case .files: return L.t("Files", "الملفات")
        case .stream: return L.t("Remote Play", "البث")
        case .settings: return L.t("Settings", "الإعدادات")
        }
    }
}

struct RootView: View {
    @StateObject private var store = HubStore()
    @State private var tab: HubTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            HubBackground()
            Group {
                switch tab {
                case .home: HomeView(tab: $tab)
                case .games: GamesView()
                case .pad: ControllerView()
                case .files: FilesView()
                case .stream: StreamTab()
                case .settings: SettingsView()
                }
            }
            .padding(.bottom, 74)
            TabBar(tab: $tab)
            if let t = store.toast {
                Toast(text: t).padding(.bottom, 100).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environmentObject(store)
        .environment(\.layoutDirection, store.arabic ? .rightToLeft : .leftToRight)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
        .onAppear {
            store.startPolling()
            if !store.configured { tab = .settings }
            else if store.games.isEmpty { Task { await store.loadGames() } }
        }
    }
}

struct TabBar: View {
    @Binding var tab: HubTab
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(HubTab.allCases, id: \.rawValue) { t in
                Button {
                    Theme.haptic()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            if tab == t {
                                Capsule().fill(Theme.accent.opacity(0.35)).frame(width: 46, height: 30)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                            Image(systemName: t.icon).font(.system(size: 17, weight: .semibold))
                                .foregroundColor(tab == t ? .white : Theme.dim)
                        }
                        .frame(height: 30)
                        Text(t.title).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundColor(tab == t ? .white : Theme.dim).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .glass(28)
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

/// Remote Play tab: the existing PREMO client screen.
struct StreamTab: View {
    var body: some View {
        ConnectView()
    }
}
