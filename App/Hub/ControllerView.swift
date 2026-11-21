import SwiftUI

/// Virtual DualShock over webMAN's /pad.ps3 (works on the XMB and in games).
struct ControllerView: View {
    @EnvironmentObject var store: HubStore
    @State private var mode = 0       // 0 pad, 1 touchpad

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L.t("Controller", "اليد")).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundColor(Theme.text)
                Spacer()
                Picker("", selection: $mode) {
                    Image(systemName: "gamecontroller.fill").tag(0)
                    Image(systemName: "hand.point.up.left.fill").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 120)
            }
            .padding(.horizontal, 18).padding(.top, 10)
            if !store.configured {
                Spacer()
                Text(L.t("Set the PS3 address in Settings first.", "أدخل عنوان الجهاز في الإعدادات أولاً.")).foregroundColor(Theme.dim)
                Spacer()
            } else if mode == 0 {
                PadLayout()
            } else {
                TouchPad()
            }
        }
        .environment(\.layoutDirection, .leftToRight)   // a controller is never mirrored
    }
}

private func send(_ store: HubStore, _ b: String) {
    Theme.haptic(.rigid)
    Task { await store.client.pad(b) }
}

struct PadLayout: View {
    @EnvironmentObject var store: HubStore

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(spacing: 18) {
                // shoulders
                HStack {
                    VStack(spacing: 8) { shoulder("L2"); shoulder("L1") }
                    Spacer()
                    VStack(spacing: 8) { shoulder("R2"); shoulder("R1") }
                }
                .padding(.horizontal, 18)
                HStack(alignment: .center) {
                    DPad { send(store, $0) }.frame(width: min(170, w * 0.42), height: min(170, w * 0.42))
                    Spacer()
                    FaceButtons { send(store, $0) }.frame(width: min(180, w * 0.44), height: min(180, w * 0.44))
                }
                .padding(.horizontal, 16)
                HStack(spacing: 18) {
                    small("SELECT", "select")
                    Button { send(store, "psbtn") } label: {
                        Image(systemName: "playstation.logo").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                            .frame(width: 58, height: 58)
                            .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                            .shadow(color: Theme.accent.opacity(0.6), radius: 12)
                    }
                    .buttonStyle(.plain)
                    small("START", "start")
                }
                HStack(spacing: 18) {
                    small("L3", "l3")
                    small(L.t("Back", "رجوع"), "cancel")
                    small(L.t("OK", "موافق"), "accept")
                    small("R3", "r3")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func shoulder(_ t: String) -> some View {
        Button { send(store, t.lowercased()) } label: {
            Text(t).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(.white)
                .frame(width: 92, height: 38).glass(14)
        }
        .buttonStyle(PressStyle())
    }

    private func small(_ t: String, _ b: String) -> some View {
        Button { send(store, b) } label: {
            Text(t).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(.white)
                .padding(.horizontal, 14).frame(height: 34).glass(17)
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// D-pad with auto-repeat while held.
struct DPad: View {
    let press: (String) -> Void
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 3
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).frame(width: s, height: s * 3)
                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).frame(width: s * 3, height: s)
                arrow("chevron.up", "up").frame(width: s, height: s).offset(y: -s)
                arrow("chevron.down", "down").frame(width: s, height: s).offset(y: s)
                arrow("chevron.left", "left").frame(width: s, height: s).offset(x: -s)
                arrow("chevron.right", "right").frame(width: s, height: s).offset(x: s)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private func arrow(_ icon: String, _ b: String) -> some View {
        RepeatButton(action: { press(b) }) {
            Image(systemName: icon).font(.system(size: 22, weight: .heavy)).foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct FaceButtons: View {
    let press: (String) -> Void
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 3
            ZStack {
                face("triangle", "triangle", Color(red: 0.36, green: 0.85, blue: 0.70)).frame(width: s, height: s).offset(y: -s)
                face("xmark", "cross", Color(red: 0.52, green: 0.72, blue: 1.0)).frame(width: s, height: s).offset(y: s)
                face("square", "square", Color(red: 0.93, green: 0.58, blue: 0.80)).frame(width: s, height: s).offset(x: -s)
                face("circle", "circle", Color(red: 0.98, green: 0.45, blue: 0.45)).frame(width: s, height: s).offset(x: s)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private func face(_ icon: String, _ b: String, _ c: Color) -> some View {
        Button { press(b) } label: {
            Image(systemName: icon).font(.system(size: 22, weight: .heavy)).foregroundColor(c)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(c.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(PressStyle())
    }
}

/// Fires once on touch, then repeats while held.
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        label()
            .scaleEffect(pressed ? 0.9 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if pressed { return }
                    pressed = true
                    action()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in action() }
                    }
                }
                .onEnded { _ in pressed = false; timer?.invalidate(); timer = nil })
    }
}

/// Swipe to move, tap for ✕, two-finger tap for ○.
struct TouchPad: View {
    @EnvironmentObject var store: HubStore
    @State private var last = ""

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.12)))
                VStack(spacing: 8) {
                    Image(systemName: "hand.draw").font(.system(size: 36)).foregroundColor(Theme.dim)
                    Text(L.t("Swipe to move · Tap = ✕ · Long press = ○", "اسحب للتنقل · نقرة = ✕ · ضغطة مطولة = ○"))
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(Theme.dim).multilineTextAlignment(.center)
                    if !last.isEmpty { Text(last).font(.system(size: 28, weight: .heavy)).foregroundColor(.white) }
                }
                .padding()
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                let b = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                last = ["right": "→", "left": "←", "down": "↓", "up": "↑"][b] ?? ""
                send(store, b)
            })
            .simultaneousGesture(TapGesture().onEnded { last = "✕"; send(store, "cross") })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in last = "○"; send(store, "circle") })
            .padding(.horizontal, 18)
            HStack(spacing: 12) {
                PillButton(title: "△", icon: "triangle", tint: Theme.accent2) { send(store, "triangle") }
                PillButton(title: "□", icon: "square", tint: Theme.accent) { send(store, "square") }
                PillButton(title: "PS", icon: "playstation.logo", tint: Theme.warm) { send(store, "psbtn") }
            }
            .padding(.bottom, 10)
        }
    }
}
