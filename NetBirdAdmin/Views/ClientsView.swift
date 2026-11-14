import SwiftUI

struct ClientsView: View {
    @Environment(AppStore.self) private var store
    @State private var segment = 0
    @State private var search = ""
    @State private var filter: PeerFilter = .all
    @State private var showCreateKey = false

    enum PeerFilter: String, CaseIterable, Identifiable {
        case all = "Alle", online = "Online", offline = "Offline", outdated = "Veraltet"
        var id: String { rawValue }
    }

    var filteredPeers: [Peer] {
        store.peers.filter { p in
            let matches = search.isEmpty
                || p.name.localizedCaseInsensitiveContains(search)
                || p.ip.contains(search)
                || (p.ipv6?.localizedCaseInsensitiveContains(search) ?? false)
                || p.os.localizedCaseInsensitiveContains(search)
            switch filter {
            case .all: return matches
            case .online: return matches && p.connected
            case .offline: return matches && !p.connected
            case .outdated: return matches && store.peerIsOutdated(p)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $segment) {
                        Text("Clients (\(store.peers.count))").tag(0)
                        Text("Setup-Keys (\(store.setupKeys.count))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if segment == 0 { peersSection } else { SetupKeysSection() }
            }
            .glassScreen()
            .navigationTitle("Clients")
            .searchable(text: $search, prompt: "Name, IP, OS …")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateKey = true } label: { Label("Neuer Client", systemImage: "plus.circle.fill") }
                }
                if segment == 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Filter", selection: $filter) {
                                ForEach(PeerFilter.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                }
            }
            .sheet(isPresented: $showCreateKey) { NavigationStack { CreateSetupKeyView() } }
        }
    }

    @ViewBuilder private var peersSection: some View {
        Section {
            if filteredPeers.isEmpty {
                Text(store.peers.isEmpty ? "Keine Clients" : "Kein Treffer").foregroundStyle(.secondary)
            }
            ForEach(filteredPeers) { p in
                NavigationLink { PeerDetailView(peerID: p.id) } label: { PeerRow(peer: p) }
            }
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }
}

struct PeerRow: View {
    @Environment(AppStore.self) private var store
    let peer: Peer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: osIcon)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(online: peer.connected)
                    Text(peer.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(peer.ip).font(.caption.monospaced())
                    if let v6 = peer.ipv6, !v6.isEmpty {
                        Text(v6).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("v\(peer.version)").font(.caption2.monospaced())
                    .foregroundStyle(store.peerIsOutdated(peer) ? Color.nbOrange : .secondary)
                if !peer.connected, let ls = peer.lastSeen {
                    Text(ls.relative).font(.caption2).foregroundStyle(.tertiary)
                }
                if peer.loginExpired { Pill(text: "Login abgelaufen", color: .red) }
            }
        }
        .padding(.vertical, 2)
    }

    private var osIcon: String {
        let os = peer.os.lowercased()
        if os.contains("darwin") || os.contains("mac") { return "laptopcomputer" }
        if os.contains("ios") { return "iphone" }
        if os.contains("android") { return "candybarphone" }
        if os.contains("windows") { return "pc" }
        if os.contains("linux") || os.contains("ubuntu") || os.contains("debian") { return "server.rack" }
        return "desktopcomputer"
    }
}

struct PeerDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let peerID: String
    @State private var name = ""
    @State private var ssh = false
    @State private var loginExp = false
    @State private var inactExp = false
    @State private var saving = false
    @State private var confirmDelete = false

    var peer: Peer? { store.peers.first { $0.id == peerID } }

    var body: some View {
        Form {
            if let p = peer {
                Section {
                    HStack {
                        StatusDot(online: p.connected)
                        Text(p.connected ? "Verbunden" : "Offline").font(.headline)
                        Spacer()
                        if let ls = p.lastSeen { Text("zuletzt \(ls.relative)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("Netzwerk") {
                    info("NetBird IPv4", p.ip, mono: true)
                    info("NetBird IPv6", (p.ipv6?.isEmpty ?? true) ? "nicht zugewiesen" : p.ipv6!, mono: true)
                    info("DNS", p.dnsLabel, mono: true)
                    info("Öffentliche IP", p.connectionIp ?? "–", mono: true)
                    if let city = p.cityName, !city.isEmpty { info("Standort", "\(city) \(p.countryCode ?? "")") }
                }
                Section("System") {
                    info("Hostname", p.hostname)
                    info("Betriebssystem", p.os)
                    info("Kernel", p.kernelVersion ?? "–")
                    HStack {
                        Text("NetBird-Version")
                        Spacer()
                        Text(p.version).monospaced().foregroundStyle(store.peerIsOutdated(p) ? Color.nbOrange : .secondary)
                        if store.peerIsOutdated(p), let l = store.latestRelease { Pill(text: "→ \(l.tagName)", color: .nbOrange) }
                    }
                    if let s = p.serialNumber, !s.isEmpty { info("Seriennummer", s, mono: true) }
                }
                Section("Gruppen") {
                    if p.groups.isEmpty { Text("Keine").foregroundStyle(.secondary) }
                    ForEach(p.groups) { g in Text(g.name) }
                }
                Section("Einstellungen") {
                    TextField("Name", text: $name)
                    Toggle("SSH-Server aktiviert", isOn: $ssh)
                    Toggle("Login-Ablauf", isOn: $loginExp)
                    Toggle("Inaktivitäts-Ablauf", isOn: $inactExp)
                    Button {
                        Task { await save(p) }
                    } label: {
                        if saving { ProgressView() } else { Text("Speichern") }
                    }
                    .disabled(saving || !dirty(p))
                }
                Section {
                    Button("Client entfernen", role: .destructive) { confirmDelete = true }
                }
            } else {
                Text("Client nicht gefunden")
            }
        }
        .glassScreen()
        .navigationTitle(peer?.name ?? "Client")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .confirmationDialog("Client wirklich entfernen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                Task {
                    if await store.perform({ try await $0.deletePeer(peerID) }) {
                        store.peers.removeAll { $0.id == peerID }
                        dismiss()
                    }
                }
            }
        }
    }

    private func info(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).font(mono ? .callout.monospaced() : .callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func load() {
        guard let p = peer else { return }
        name = p.name; ssh = p.sshEnabled; loginExp = p.loginExpirationEnabled
        inactExp = p.inactivityExpirationEnabled ?? false
    }

    private func dirty(_ p: Peer) -> Bool {
        name != p.name || ssh != p.sshEnabled || loginExp != p.loginExpirationEnabled || inactExp != (p.inactivityExpirationEnabled ?? false)
    }

    private func save(_ p: Peer) async {
        saving = true
        defer { saving = false }
        let body = PeerUpdateRequest(name: name, sshEnabled: ssh, loginExpirationEnabled: loginExp,
                                     inactivityExpirationEnabled: inactExp, approvalRequired: nil)
        _ = await store.perform { api in
            let updated = try await api.updatePeer(p.id, body)
            if let i = store.peers.firstIndex(where: { $0.id == p.id }) { store.peers[i] = updated }
        }
    }
}
