import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConnectView: View {
    @StateObject private var settings = RPSettings()
    @State private var showPlayer = false
    @State private var showImporter = false
    @State private var message = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("PS3"), footer: Text("On the PS3 open Network > Remote Play before connecting.")) {
                    TextField("PS3 IP address", text: $settings.host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Registration keys"),
                        footer: Text("Create them on a computer with tools/ps3rp.py, then import ps3rp.json here.")) {
                    TextField("Device ID (32 hex digits)", text: $settings.pspID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Key (32 hex digits)", text: $settings.pkey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Device MAC (12 hex digits)", text: $settings.mac)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Nickname", text: $settings.nickname)
                        .disableAutocorrection(true)
                    Button("Import ps3rp.json file") { showImporter = true }
                    Button("Paste ps3rp.json from clipboard") { pasteKeys() }
                }
                Section(header: Text("Quality")) {
                    Picker("Bitrate", selection: $settings.bitrate) {
                        Text("256 kbps").tag(256000)
                        Text("384 kbps").tag(384000)
                        Text("512 kbps").tag(512000)
                        Text("768 kbps").tag(768000)
                        Text("1024 kbps").tag(1024000)
                    }
                }
                Section {
                    Button(action: connect) {
                        Text("Connect").bold().frame(maxWidth: .infinity)
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("PS3 Remote Play")
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.json, UTType.plainText, UTType.data]) { result in
            switch result {
            case .success(let url):
                importFile(url)
            case .failure:
                message = "Could not open that file."
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen(settings: settings) { text in
                message = text
                showPlayer = false
            }
            .ignoresSafeArea()
        }
    }

    private func connect() {
        if let problem = settings.problem {
            message = problem
            return
        }
        message = ""
        showPlayer = true
    }

    private func pasteKeys() {
        let text = UIPasteboard.general.string ?? ""
        message = settings.importJSON(text) ? "" : "The clipboard does not hold a ps3rp.json."
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            message = "Could not read that file."
            return
        }
        message = settings.importJSON(text) ? "" : "That file does not hold Remote Play keys."
    }
}

/// Hosts the UIKit player inside SwiftUI.
struct PlayerScreen: UIViewControllerRepresentable {
    let settings: RPSettings
    let onClose: (String) -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        let controller = PlayerViewController()
        controller.config = PlayerConfig(host: settings.trimmedHost, pspID: settings.pspID, pkey: settings.pkey,
                                         mac: settings.mac, nickname: settings.nickname, bitrate: settings.bitrate)
        controller.onClose = onClose
        return controller
    }

    func updateUIViewController(_ uiViewController: PlayerViewController, context: Context) {}
}
