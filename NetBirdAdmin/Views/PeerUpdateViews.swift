import SwiftUI

/// Remote-Update des NetBird-Clients auf einem Peer (per SSH-Zertifikat).
struct PeerRemoteUpdateView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let peer: Peer

    @State private var updater = PeerUpdater()
    @State private var hostChoice = HostChoice.overlay
    @State private var customHost = ""
    @State private var port = 22
    @State private var user = "root"
    @State private var showError = false
    @State private var confirm = false

    enum HostChoice: String, CaseIterable, Identifiable {
        case overlay = "NetBird-IP", dns = "DNS-Name", ipv6 = "NetBird-IPv6", publicIP = "Öffentliche IP", custom = "Eigene"
        var id: String { rawValue }
    }

    var host: String {
        switch hostChoice {
        case .overlay: return peer.ip
        case .dns: return peer.dnsLabel
        case .ipv6: return peer.ipv6 ?? ""
        case .publicIP: return peer.connectionIp ?? ""
        case .custom: return customHost
        }
    }

    var isWindows: Bool { peer.os.localizedCaseInsensitiveContains("windows") }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Installiert").font(.caption).foregroundStyle(.secondary)
                        Text(peer.version).font(.title3.bold().monospaced())
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Aktuell (GitHub)").font(.caption).foregroundStyle(.secondary)
                        Text(store.latestRelease?.tagName ?? "–").font(.title3.bold().monospaced())
                    }
                }
                if let after = updater.versionAfter {
                    Label("Jetzt: \(after)", systemImage: "checkmark.seal.fill").foregroundStyle(Color.nbOnline)
                }
            }
            if isWindows {
                Section {
                    Label("Windows-Peers können nicht per SSH-Skript aktualisiert werden. Nutze stattdessen das automatische Client-Update (Netzwerk → Client-Updates).",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }
            Section {
                Picker("Verbinden über", selection: $hostChoice) {
                    ForEach(HostChoice.allCases) { c in
                        if c != .ipv6 || !(peer.ipv6 ?? "").isEmpty { Text(c.rawValue).tag(c) }
                    }
                }
                if hostChoice == .custom {
                    TextField("Host", text: $customHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Text(host).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("22", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                }
                TextField("Benutzer", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let fp = PeerSSHConfig.load(peer.id)?.hostKey {
                    VStack(alignment: .leading) {
                        Text("Vertrauter Host-Key").font(.caption).foregroundStyle(.secondary)
                        Text(fp).font(.caption2.monospaced())
                    }
                    Button("Host-Key vergessen", role: .destructive) {
                        PeerSSHConfig.save(PeerSSHConfig(host: host, port: port, user: user, hostKey: nil), for: peer.id)
                    }
                }
            } header: { Text("SSH") } footer: {
                Text("Für die NetBird-IP muss dieses iPhone mit dem NetBird-Netz verbunden sein. Auf dem Peer muss die SSH-CA eingerichtet sein (server/setup-ssh-ca.sh).")
            }
            Section {
                Button { confirm = true } label: {
                    if updater.isRunning {
                        HStack { ProgressView().tint(.white); Text(statusText) }
                    } else {
                        Label("Client jetzt aktualisieren", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(updater.isRunning || host.isEmpty || !SSHKeyManager.hasKey || isWindows)
                if !SSHKeyManager.hasKey {
                    NavigationLink { SSHKeyView() } label: { Label("SSH-Zertifikat einrichten", systemImage: "key.viewfinder") }
                }
                if case .failed(let msg) = updater.phase {
                    Label(msg.components(separatedBy: "\n").first ?? msg, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.footnote)
                    Button("Fehlerdetails anzeigen") { showError = true }
                }
            }
            if !updater.log.isEmpty {
                Section("Protokoll") {
                    ForEach(Array(updater.log.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    Button { UIPasteboard.general.string = updater.log.joined(separator: "\n") } label: {
                        Label("Protokoll kopieren", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .glassScreen()
        .navigationTitle("Client-Update")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConfig)
        .confirmationDialog("NetBird auf \(peer.name) aktualisieren?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Update starten") { Task { await start() } }
        } message: {
            Text("Der NetBird-Dienst auf dem Peer wird neu gestartet. Die Verbindung bricht kurz ab.")
        }
        .alert("Update fehlgeschlagen", isPresented: $showError) {
            Button("Kopieren") { UIPasteboard.general.string = updater.errorDetail }
            Button("OK", role: .cancel) {}
        } message: {
            Text(updater.errorDetail ?? "Unbekannter Fehler")
        }
        .onChange(of: updater.errorDetail) { _, e in if e != nil { showError = true } }
    }

    private var statusText: String {
        switch updater.phase {
        case .connecting: return "Verbinde …"
        case .started: return "Gestartet …"
        case .waiting(let n): return "Warte auf Peer (\(n)) …"
        default: return "…"
        }
    }

    private func loadConfig() {
        guard let c = PeerSSHConfig.load(peer.id) else { return }
        port = c.port; user = c.user
        switch c.host {
        case peer.ip: hostChoice = .overlay
        case peer.dnsLabel: hostChoice = .dns
        case peer.ipv6 ?? "-": hostChoice = .ipv6
        case peer.connectionIp ?? "-": hostChoice = .publicIP
        default: hostChoice = .custom; customHost = c.host
        }
    }

    private func start() async {
        let known = PeerSSHConfig.load(peer.id)
        let sameHost = known?.host == host && known?.port == port
        let cfg = PeerSSHConfig(host: host, port: port, user: user, hostKey: sameHost ? known?.hostKey : nil)
        PeerSSHConfig.save(cfg, for: peer.id)
        let peerID = peer.id
        await updater.run(peer: peer, config: cfg) { fp in
            var c = cfg; c.hostKey = fp
            PeerSSHConfig.save(c, for: peerID)
        }
        await store.refreshAll()
    }
}

/// Automatisches Client-Update für alle Peers (Account-Einstellung, ab NetBird 0.5x).
struct ClientAutoUpdateView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "disabled"
    @State private var version = ""
    @State private var always = false
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                Picker("Modus", selection: $mode) {
                    Text("Aus").tag("disabled")
                    Text("Immer neueste").tag("latest")
                    Text("Feste Version").tag("pinned")
                }
                .pickerStyle(.segmented)
                if mode == "pinned" {
                    TextField("z. B. \(SemVer(store.latestRelease?.tagName)?.description ?? "0.60.0")", text: $version)
                        .keyboardType(.decimalPad).font(.body.monospaced())
                }
                Toggle("Im Hintergrund installieren", isOn: $always)
            } header: { Text("Client-Updates") } footer: {
                Text("Die NetBird-Clients aktualisieren sich selbst. Ohne „Im Hintergrund“ muss der Benutzer das Update in der Client-Oberfläche bestätigen. Unterstützt nur neuere Client-Versionen.")
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Speichern") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(saving || (mode == "pinned" && SemVer(version) == nil) || store.account == nil)
            }
        }
        .glassScreen()
        .navigationTitle("Client-Updates")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let v = store.account?.settings["auto_update_version"]?.stringValue ?? "disabled"
            if v == "latest" || v == "disabled" || v.isEmpty { mode = v.isEmpty ? "disabled" : v } else { mode = "pinned"; version = v }
            always = store.account?.settings["auto_update_always"]?.boolValue ?? false
        }
    }

    private func save() async {
        guard var account = store.account else { return }
        saving = true
        defer { saving = false }
        account.settings["auto_update_version"] = .string(mode == "pinned" ? (SemVer(version)?.description ?? version) : mode)
        account.settings["auto_update_always"] = .bool(always)
        let settings = account.settings
        if await store.perform({ try await $0.updateAccountSettings(account.id, settings: settings) }) {
            store.account = account
            dismiss()
        }
    }
}

/// Gruppen eines Peers zuweisen/entfernen.
struct PeerGroupsEditor: View {
    @Environment(AppStore.self) private var store
    let peerID: String
    @State private var busy: String?
    @State private var newGroup = ""

    var peer: Peer? { store.peers.first { $0.id == peerID } }

    var body: some View {
        List {
            Section {
                ForEach(store.groups.filter { $0.name != "All" }) { g in
                    let member = peer?.groups.contains { $0.id == g.id } ?? false
                    Button { Task { await toggle(g, member: member) } } label: {
                        HStack {
                            Text(g.name).foregroundStyle(.primary)
                            Spacer()
                            if busy == g.id { ProgressView() }
                            else if member { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.nbOrange) }
                            else { Image(systemName: "circle").foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(busy != nil || g.issued == "jwt" || g.issued == "integration")
                }
            } footer: { Text("Die Gruppe „All“ enthält immer alle Peers. JWT-/Integrations-Gruppen werden extern verwaltet.") }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            Section("Neue Gruppe") {
                HStack {
                    TextField("Name", text: $newGroup)
                    Button("Anlegen & zuweisen") { Task { await create() } }
                        .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                }
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle("Gruppen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ g: NBGroup, member: Bool) async {
        busy = g.id
        defer { busy = nil }
        _ = await store.perform { api in
            if member {
                _ = try await api.removePeer(peerID, fromGroup: g.id)
            } else {
                _ = try await api.addPeer(peerID, toGroup: g.id)
            }
        }
        await store.reloadPeersAndGroups()
    }

    private func create() async {
        busy = "new"
        defer { busy = nil }
        let name = newGroup.trimmingCharacters(in: .whitespaces)
        if await store.perform({ api in _ = try await api.createGroup(.init(name: name, peers: [peerID])) }) {
            newGroup = ""
            await store.reloadPeersAndGroups()
        }
    }
}
