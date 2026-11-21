import SwiftUI
import UIKit

/// Arabic / English strings. The language follows the app setting (default: the phone's language).
enum L {
    static var arabic: Bool = {
        if let v = UserDefaults.standard.object(forKey: "hub.arabic") as? Bool { return v }
        return Locale.preferredLanguages.first?.hasPrefix("ar") ?? false
    }()
    static func t(_ en: String, _ ar: String) -> String { arabic ? ar : en }
}

enum Theme {
    static let bg0 = Color(red: 0.035, green: 0.035, blue: 0.09)
    static let bg1 = Color(red: 0.07, green: 0.06, blue: 0.16)
    static let accent = Color(red: 0.50, green: 0.47, blue: 0.87)      // violet
    static let accent2 = Color(red: 0.36, green: 0.79, blue: 0.65)     // teal
    static let warm = Color(red: 0.85, green: 0.35, blue: 0.19)
    static let text = Color(red: 0.93, green: 0.92, blue: 1.0)
    static let dim = Color(red: 0.62, green: 0.61, blue: 0.78)

    static func platformColor(_ p: Platform) -> Color {
        switch p {
        case .ps3: return Color(red: 0.25, green: 0.45, blue: 0.95)
        case .ps2: return Color(red: 0.32, green: 0.30, blue: 0.80)
        case .ps1: return Color(red: 0.55, green: 0.56, blue: 0.62)
        case .psp: return Color(red: 0.80, green: 0.33, blue: 0.50)
        case .retro: return Color(red: 0.86, green: 0.55, blue: 0.18)
        case .video: return Color(red: 0.20, green: 0.66, blue: 0.55)
        case .other: return Color(red: 0.45, green: 0.45, blue: 0.55)
        }
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

/// Animated aurora background used behind every screen.
struct HubBackground: View {
    @State private var phase = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bg0, Theme.bg1], startPoint: .top, endPoint: .bottom)
            Circle().fill(Theme.accent.opacity(0.35)).frame(width: 420, height: 420).blur(radius: 120)
                .offset(x: phase ? 140 : 90, y: phase ? -320 : -260)
            Circle().fill(Theme.accent2.opacity(0.22)).frame(width: 380, height: 380).blur(radius: 120)
                .offset(x: phase ? -150 : -100, y: phase ? 380 : 320)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { phase.toggle() } }
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

extension View {
    func glass(_ radius: CGFloat = 22) -> some View { modifier(Glass(radius: radius)) }
    func hubText() -> some View { foregroundColor(Theme.text) }
}

struct SectionTitle: View {
    let text: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(text).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(Theme.text)
            Spacer()
            if let t = trailing { t }
        }
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    var tint: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: { Theme.haptic(); action() }) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(tint.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}
