import SwiftUI

struct ServerView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: ServerProfile?
    @State private var addNew = false

    var body: some View {
        NavigationStack {
            List {
                Section("Wartung") {
                    NavigationLink { ServerUpdateView() } label: {
                        Label("Server-Update", systemImage: "arrow.down.circle.fill")
                    }
                    NavigationLink { SSHKeyView() } label: {
                        HStack {
                            Label("SSH-Zertifikat", systemImage: "key.viewfinder")
                            Spacer()
                            if let info = SSHKeyManager.certInfo {
                                Pill(text: info.isValidNow ? "gültig" : "abgelaufen", color: info.isValidNow ? .nbOnline : .red)
                            } else {
                                Pill(text: SSHKeyManager.hasKey ? "kein Zert." : "kein Key", color: .orange)
                            }
                        }
                    }
                    NavigationLink { SSHConsoleView() } label: {
                        Label("SSH-Konsole", systemImage: "terminal")
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Protokolle & Freigaben") {
                    NavigationLink { ApprovalsView() } label: {
                        HStack {
                            Label("Freigaben", systemImage: "person.badge.clock")
                            Spacer()
                            let n = store.pendingPeers.count + store.pendingUsers.count
                            if n > 0 { Pill(text: "\(n)", color: .nbOrange) }
                        }
                    }
                    NavigationLink { AuditLogView() } label: { Label("Audit-Log", systemImage: "list.bullet.rectangle") }
                    NavigationLink { ProxyAccessLogView() } label: { Label("Proxy-Zugriffe", systemImage: "arrow.left.arrow.right.square") }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("App") {
                    NavigationLink { AppSettingsView() } label: { Label("Face ID & Benachrichtigungen", systemImage: "bell.badge") }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Server") {
                    ForEach(store.profiles) { p in
                        HStack {
                            Button { store.select(p) } label: {
                                HStack {
                                    Image(systemName: p.id == store.selectedID ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(Color.nbOrange)
                                    VStack(alignment: .leading) {
                                        Text(p.name).foregroundStyle(.primary)
                                        Text(p.managementURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            Spacer()
                            Button { editing = p } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(p) } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                    Button { addNew = true } label: { Label("Server hinzufügen", systemImage: "plus") }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Info") {
                    LabeledContent("App-Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Link(destination: URL(string: "https://docs.netbird.io/api")!) { Label("NetBird API-Doku", systemImage: "book") }
                    Link(destination: URL(string: "https://github.com/netbirdio/netbird/releases")!) { Label("NetBird Releases", systemImage: "shippingbox") }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
            .glassScreen()
            .navigationTitle("Server")
            .sheet(item: $editing) { p in NavigationStack { ServerProfileEditView(profile: p, isNew: false) } }
            .sheet(isPresented: $addNew) { NavigationStack { ServerProfileEditView(profile: ServerProfile(), isNew: true) } }
        }
    }
}

struct ServerProfileEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var profile: ServerProfile
    let isNew: Bool
    @State private var token = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                TextField("https://netbird.example.com", text: $profile.managementURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Personal Access Token (nbp_…)", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Management-API") } footer: {
                Text("Token erstellen: Dashboard → Team → Service Users → Admin-Service-User → Token anlegen.")
            }
            Section {
                TextField("Host (leer = Management-Host)", text: $profile.sshHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("22", value: $profile.sshPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                }
                TextField("Benutzer", text: $profile.sshUser)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Installationsverzeichnis", text: $profile.installDir)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let fp = profile.trustedHostKey {
                    VStack(alignment: .leading) {
                        Text("Vertrauter Host-Key").font(.caption).foregroundStyle(.secondary)
                        Text(fp).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    Button("Host-Key vergessen", role: .destructive) { profile.trustedHostKey = nil }
                }
            } header: { Text("SSH (Updates)") } footer: {
                Text("Login per SSH-Zertifikat. Mit Principal „netbird-admin“ ist direkter root-Login möglich (siehe server/setup-ssh-ca.sh).")
            }
            Section {
                Picker("Update-Methode", selection: $profile.updateMode) {
                    ForEach(ServerProfile.UpdateMode.allCases) { Text($0.rawValue).tag($0) }
                }
                if profile.updateMode == .custom {
                    TextEditor(text: $profile.customUpdateCommand)
                        .font(.caption.monospaced()).frame(minHeight: 100)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } header: { Text("Update") } footer: {
                Text(profile.updateMode == .custom
                     ? "Platzhalter: {{version}} (z. B. 0.60.1) und {{tag}} (z. B. v0.60.1)."
                     : "Setzt die netbirdio-Images in der Compose-Datei auf das neue Release, zieht sie und startet die Container neu (mit Backup).")
            }
            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Verbindung testen")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .glassScreen()
        .navigationTitle(isNew ? "Server hinzufügen" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if !(isNew && store.profiles.isEmpty) { Button("Abbrechen") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { save() }.disabled(profile.apiBaseURL?.host == nil)
            }
        }
        .onAppear { token = profile.apiToken ?? "" }
    }

    private func save() {
        profile.apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsert(profile)
        if isNew || profile.id == store.selectedID { store.select(profile) }
        dismiss()
    }

    private func test() async {
        testing = true
        defer { testing = false }
        profile.apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let api = try NetBirdAPI(profile: profile)
            let peers = try await api.peers()
            var msg = "✓ API erreichbar – \(peers.count) Clients"
            if let v = try? await api.versionInfo() { msg += ", Management v\(v.managementCurrentVersion)" }
            testResult = msg
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }
}
