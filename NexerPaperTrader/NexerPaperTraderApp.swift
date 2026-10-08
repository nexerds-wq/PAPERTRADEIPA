import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Security
import Foundation

private enum NexerStyle {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.062)
    static let panel = Color(red: 0.085, green: 0.105, blue: 0.14)
    static let accent = Color(red: 0.21, green: 0.82, blue: 0.72)
}

@main
struct NexerPaperTraderApp: App {
    @StateObject private var api = NexerAPI()
    @State private var unlocked = false

    var body: some Scene {
        WindowGroup {
            Group {
                if unlocked {
                    NexerHome()
                        .environmentObject(api)
                } else {
                    SecretUnlockView { unlocked = true }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// A drag works with touch or an attached pointer. A Windows left-mouse version
// lives in WindowsAgent/nexer_desktop.py.
private struct SecretUnlockView: View {
    let onUnlock: () -> Void
    @State private var progress = 0
    private let code = ["up", "down", "left", "left", "right"]

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 48)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard max(abs(dx), abs(dy)) >= 65 else { return }
                        let direction = abs(dx) > abs(dy)
                            ? (dx > 0 ? "right" : "left")
                            : (dy > 0 ? "down" : "up")
                        if direction == code[progress] {
                            progress += 1
                            if progress == code.count {
                                progress = 0
                                onUnlock()
                            }
                        } else {
                            progress = direction == code[0] ? 1 : 0
                        }
                    }
            )
            .accessibilityLabel("Locked")
    }
}

private enum KeyStore {
    static let account = "agent-key"
    static let service = "com.nexer.repair.agent"
    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = token.data(using: .utf8), !token.isEmpty else { return }
        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(newItem as CFDictionary, nil)
    }
}

struct RepairTool: Codable, Identifiable {
    let id: String
    let label: String
    let risk: String
    let description: String
}
struct PendingRepair: Codable, Identifiable {
    let id: String
    let tool: String
    let label: String
    let risk: String
}
struct ScanResult: Codable, Identifiable {
    let id: String
    let label: String
    let status: String
    let output: String
}
struct HistoryEntry: Codable, Identifiable {
    let id: String
    let time: String
    let action: String
    let status: String
    let detail: String
}
struct StatusReply: Codable {
    let name: String
    let windows: String
    let agent: String
}
struct ToolListReply: Codable { let tools: [RepairTool] }
struct ScanReply: Codable { let results: [ScanResult] }
struct HistoryReply: Codable { let history: [HistoryEntry] }
struct ActionReply: Codable {
    let output: String?
    let pending: PendingRepair?
    let error: String?
}
struct ChatReply: Codable {
    let reply: String
    let pending: [PendingRepair]
}

@MainActor
final class NexerAPI: ObservableObject {
    @Published var address: String = UserDefaults.standard.string(forKey: "agent-address") ?? "http://127.0.0.1:8765"
    @Published var token: String = KeyStore.read()
    @Published var model: String = UserDefaults.standard.string(forKey: "ollama-model") ?? "qwen3:4b"
    @Published var visionModel: String = UserDefaults.standard.string(forKey: "vision-model") ?? "qwen3-vl:4b"
    @Published var online = false
    @Published var machine = "Not connected"
    @Published var tools: [RepairTool] = []
    @Published var history: [HistoryEntry] = []

    func saveSettings() {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent-address")
        UserDefaults.standard.set(model, forKey: "ollama-model")
        UserDefaults.standard.set(visionModel, forKey: "vision-model")
        KeyStore.write(token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func request<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        let base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (base.hasPrefix("http://") || base.hasPrefix("https://")),
              let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else {
            throw NSError(domain: "NEXER", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid PC agent URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.timeoutInterval = 180
        req.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Nexer-Key")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "Server unavailable"
            throw NSError(domain: "NEXER", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: raw.prefix(400).description])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func refresh() async {
        do {
            let status: StatusReply = try await request("/status")
            online = true
            machine = status.name + " · " + status.windows
            let list: ToolListReply = try await request("/tools")
            tools = list.tools
        } catch {
            online = false
            machine = "Offline"
        }
    }
    func refreshHistory() async {
        if let log: HistoryReply = try? await request("/history") { history = log.history }
    }
}

struct NexerHome: View {
    @EnvironmentObject private var api: NexerAPI
    var body: some View {
        TabView {
            DashboardScreen()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
            ChatScreen()
                .tabItem { Label("Ollama", systemImage: "sparkles") }
            ToolsScreen()
                .tabItem { Label("Repairs", systemImage: "wrench.adjustable.fill") }
            HistoryScreen()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(NexerStyle.accent)
        .background(NexerStyle.background)
        .task { await api.refresh() }
    }
}

private struct DashboardScreen: View {
    @EnvironmentObject private var api: NexerAPI
    @State private var results: [ScanResult] = []
    @State private var busy = false
    @State private var error = ""
    private let categories: [(String, String)] = [
        ("Windows", "desktopcomputer"), ("Drivers", "cpu"), ("GPU", "display"),
        ("Network", "wifi"), ("Bluetooth", "dot.radiowaves.left.and.right"),
        ("Audio", "speaker.wave.2"), ("RAM", "memorychip"),
        ("Storage", "internaldrive"), ("Security", "shield.lefthalf.filled"),
        ("Crashes", "exclamationmark.triangle")
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NEXER").font(.system(size: 32, weight: .black, design: .rounded))
                            Text("Windows Repair Command Center")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(api.online ? .green : .red)
                            .frame(width: 12, height: 12)
                    }
                    panel {
                        Text(api.machine).font(.callout)
                        Text(api.online ? "PC connected" : "Connect to your Windows agent in Settings")
                            .font(.caption).foregroundStyle(api.online ? NexerStyle.accent : .orange)
                    }
                    Button {
                        busy = true
                        error = ""
                        Task {
                            do {
                                let scan: ScanReply = try await api.request("/diagnose", body: [:])
                                results = scan.results
                            } catch {
                                self.error = error.localizedDescription
                            }
                            busy = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                            Text(busy ? "Diagnosing PC..." : "DIAGNOSE MY PC")
                                .bold()
                        }
                        .frame(maxWidth: .infinity).padding(18)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NexerStyle.accent)
                    .disabled(!api.online || busy)
                    if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.caption) }
                    Text("SYSTEM MODULES").font(.headline)
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                        ForEach(categories.indices, id: \.self) { index in
                            let category = categories[index]
                            panel {
                                Image(systemName: category.1)
                                    .foregroundStyle(NexerStyle.accent)
                                    .font(.title2)
                                Text(category.0).bold()
                                Text("Available to scan").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !results.isEmpty {
                        Text("SCAN RESULTS").font(.headline)
                        ForEach(results) { result in
                            panel {
                                HStack {
                                    Text(result.label).bold()
                                    Spacer()
                                    Text(result.status.uppercased())
                                        .foregroundStyle(result.status == "ok" ? .green : .orange)
                                }
                                Text(result.output)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(8)
                            }
                        }
                    }
                    Text("Results show diagnostic output, not a guarantee the computer is healthy.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
            .background(NexerStyle.background)
            .navigationTitle("Dashboard")
        }
    }
}

private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 9, content: content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(NexerStyle.panel, in: RoundedRectangle(cornerRadius: 15))
}

private struct ChatLine: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}
private struct ChatScreen: View {
    @EnvironmentObject private var api: NexerAPI
    @State private var lines: [ChatLine] = [
        ChatLine(role: "assistant", text: "Ask me to diagnose Windows, drivers, audio, network, or a screenshot.")
    ]
    @State private var input = ""
    @State private var busy = false
    @State private var picked: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var showFiles = false
    @State private var pending: [PendingRepair] = []
    @State private var selectedRepair: PendingRepair?
    @State private var error = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(lines) { line in
                                HStack {
                                    if line.role == "user" { Spacer(minLength: 45) }
                                    Text(line.text)
                                        .padding(12)
                                        .background(line.role == "user" ? NexerStyle.accent.opacity(0.25) : NexerStyle.panel,
                                                    in: RoundedRectangle(cornerRadius: 14))
                                    if line.role != "user" { Spacer(minLength: 28) }
                                }
                                .id(line.id)
                            }
                            ForEach(pending) { item in
                                panel {
                                    Text("Repair approval needed").bold()
                                    Text(item.label + " · " + item.risk.uppercased()).font(.caption)
                                    Button("Review repair") { selectedRepair = item }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }.padding()
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                if imageData != nil {
                    HStack {
                        Label("Image attached", systemImage: "photo")
                        Spacer()
                        Button("Remove") { imageData = nil }
                    }.padding(.horizontal).font(.caption)
                }
                HStack {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    Button { showFiles = true } label: {
                        Image(systemName: "folder")
                    }
                    TextField("Ask NEXER...", text: $input, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                    Button { send() } label: {
                        Image(systemName: busy ? "hourglass" : "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(busy || !api.online || (input.isEmpty && imageData == nil))
                }.padding()
            }
            .background(NexerStyle.background)
            .navigationTitle("Ollama AI")
            .onChange(of: picked) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) {
                        imageData = compressImage(data)
                    }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        imageData = compressImage(data)
                    }
                }
            }
            .confirmationDialog(
                "Approve \(selectedRepair?.label ?? "repair")?",
                isPresented: Binding(get: { selectedRepair != nil }, set: { if !$0 { selectedRepair = nil } }),
                titleVisibility: .visible
            ) {
                Button("Approve and run repair") {
                    guard let item = selectedRepair else { return }
                    selectedRepair = nil
                    approve(item)
                }
                Button("Cancel", role: .cancel) { selectedRepair = nil }
            } message: {
                Text("This changes Windows settings. Run only on a PC you control.")
            }
        }
    }

    private func compressImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1400
        let ratio = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let rendered = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.68)
    }

    private func send() {
        let text = input
        let image = imageData?.base64EncodedString()
        input = ""
        imageData = nil
        lines.append(ChatLine(role: "user", text: text.isEmpty ? "[Image]" : text + (image == nil ? "" : " [image]")))
        busy = true
        error = ""
        Task {
            do {
                let result: ChatReply = try await api.request("/chat", body: [
                    "text": text,
                    "image": image ?? "",
                    "model": image == nil ? api.model : api.visionModel
                ])
                lines.append(ChatLine(role: "assistant", text: result.reply))
                pending.append(contentsOf: result.pending)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
    private func approve(_ item: PendingRepair) {
        Task {
            do {
                let result: ActionReply = try await api.request("/approve", body: ["id": item.id])
                lines.append(ChatLine(role: "assistant", text: result.output ?? "Repair request finished"))
                pending.removeAll { $0.id == item.id }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ToolsScreen: View {
    @EnvironmentObject private var api: NexerAPI
    @State private var output = ""
    @State private var pending: PendingRepair?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(api.tools) { tool in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(tool.label).bold()
                                Spacer()
                                Text(tool.risk.uppercased())
                                    .font(.caption2).foregroundStyle(tool.risk == "green" ? .green : .orange)
                            }
                            Text(tool.description).font(.caption).foregroundStyle(.secondary)
                            Button("Run / Request") { requestTool(tool.id) }
                                .font(.callout)
                                .disabled(busy)
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Approved repair engine tools") }
                if !output.isEmpty {
                    Section("Last result") {
                        Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NexerStyle.background)
            .navigationTitle("Repair Tools")
            .confirmationDialog(
                "Approve \(pending?.label ?? "repair")?",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button("Approve repair") {
                    if let item = pending { approve(item) }
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text("This can change system settings. Approval is required.")
            }
            .task { await api.refresh() }
        }
    }
    private func requestTool(_ id: String) {
        busy = true
        Task {
            do {
                let res: ActionReply = try await api.request("/run", body: ["tool": id])
                output = res.output ?? "Approval required."
                pending = res.pending
            } catch { output = error.localizedDescription }
            busy = false
        }
    }
    private func approve(_ item: PendingRepair) {
        Task {
            do {
                let res: ActionReply = try await api.request("/approve", body: ["id": item.id])
                output = res.output ?? "Finished"
            } catch { output = error.localizedDescription }
        }
    }
}

private struct HistoryScreen: View {
    @EnvironmentObject private var api: NexerAPI
    var body: some View {
        NavigationStack {
            List(api.history) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.action).bold()
                        Spacer()
                        Text(item.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.time).font(.caption2).foregroundStyle(.secondary)
                    Text(item.detail).font(.caption).lineLimit(4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NexerStyle.background)
            .navigationTitle("Repair History")
            .toolbar { Button("Refresh") { Task { await api.refreshHistory() } } }
            .task { await api.refreshHistory() }
        }
    }
}

private struct SettingsScreen: View {
    @EnvironmentObject private var api: NexerAPI
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Windows PC pairing") {
                    TextField("Agent URL", text: $api.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Pairing key", text: $api.token)
                        .textInputAutocapitalization(.never)
                    Button("Save and connect") {
                        api.saveSettings()
                        Task {
                            await api.refresh()
                            message = api.online ? "Connected to " + api.machine : "Could not connect. Check IP, key, and Windows firewall."
                        }
                    }
                    Text(message).font(.caption)
                    Text("Use the PC's LAN IP, such as http://192.168.1.20:8765. Never expose this agent directly to the internet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Ollama models on PC") {
                    TextField("Chat model", text: $api.model)
                    TextField("Vision model", text: $api.visionModel)
                    Button("Save models") { api.saveSettings() }
                }
                Section("Security") {
                    Text("Your pairing key is stored in iOS Keychain. Yellow repairs require approval. Red/destructive commands are unavailable.")
                        .font(.caption)
                    Text("The swipe unlock hides the interface. It does not replace device authentication.")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
