import SwiftUI

/// Steuerung des NetBird Reverse Proxy (Services, Cluster, Domains).
struct ReverseProxyView: View {
    @Environment(AppStore.self) private var store
    @State private var showCreate = false
    @State private var showAddDomain = false

    var body: some View {
        NavigationStack {
            List {
                if !store.proxyAvailable {
                    EmptyStateView(title: "Reverse Proxy nicht verfügbar",
                                   systemImage: "arrow.triangle.branch",
                                   message: "Der Management-Server liefert keine Reverse-Proxy-API. Aktualisiere NetBird auf eine aktuelle Version und richte einen Proxy-Cluster ein.")
                        .listRowBackground(Color.clear)
                } else {
                    servicesSection
                    clustersSection
                    domainsSection
                }
            }
            .glassScreen()
            .navigationTitle("Reverse Proxy")
            .refreshable { await store.refreshProxy() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCreate = true } label: { Label("Service hinzufügen", systemImage: "plus") }
                        Button { showAddDomain = true } label: { Label("Eigene Domain", systemImage: "globe") }
                    } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(!store.proxyAvailable)
                }
            }
            .sheet(isPresented: $showCreate) { NavigationStack { CreateProxyServiceView() } }
            .sheet(isPresented: $showAddDomain) { NavigationStack { AddProxyDomainView() } }
        }
    }

    private var servicesSection: some View {
        Section("Services") {
            if store.services.isEmpty { Text("Keine Services").foregroundStyle(.secondary) }
            ForEach(store.services) { s in
                ProxyServiceRow(service: s)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteProxyService(s.id) }) {
                                    store.services.removeAll { $0.id == s.id }
                                }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
            }
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    private var clustersSection: some View {
        Section("Proxy-Cluster") {
            if store.clusters.isEmpty { Text("Keine Cluster").foregroundStyle(.secondary) }
            ForEach(store.clusters) { c in
                HStack {
                    StatusDot(online: c.online)
                    VStack(alignment: .leading) {
                        Text(c.address).font(.subheadline.monospaced())
                        Text("\(c.connectedProxies) Proxy-Knoten · \(c.type == "account" ? "eigener" : "geteilt")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if c.private == true { Pill(text: "privat", color: .nbTeal) }
                }
            }
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    private var domainsSection: some View {
        Section("Domains") {
            if store.domains.isEmpty { Text("Keine Domains").foregroundStyle(.secondary) }
            ForEach(store.domains) { d in
                HStack {
                    Image(systemName: d.validated ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(d.validated ? Color.nbOnline : .orange)
                    VStack(alignment: .leading) {
                        Text(d.domain).font(.subheadline)
                        Text(d.type == "free" ? "NetBird-Domain" : "Eigene Domain → \(d.targetCluster ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !d.validated {
                        Button("Prüfen") {
                            Task {
                                if await store.perform({ try await $0.validateProxyDomain(d.id) }) { await store.refreshProxy() }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .swipeActions {
                    if d.type == "custom" {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteProxyDomain(d.id) }) {
                                    store.domains.removeAll { $0.id == d.id }
                                }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
            }
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }
}

struct ProxyServiceRow: View {
    @Environment(AppStore.self) private var store
    let service: ProxyService
    @State private var busy = false

    var statusColor: Color {
        switch service.meta.status {
        case "active": return .nbOnline
        case "pending", "certificate_pending": return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.domain).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Pill(text: (service.mode ?? "http").uppercased(), color: .nbBlue)
                        Pill(text: service.meta.status.replacingOccurrences(of: "_", with: " "), color: statusColor)
                        if service.private == true { Pill(text: "privat", color: .nbTeal, systemImage: "lock") }
                        if let p = service.listenPort, p > 0 { Pill(text: ":\(p)", color: .gray) }
                    }
                }
                Spacer()
                if busy { ProgressView() }
                Toggle("", isOn: Binding(get: { service.enabled }, set: { v in Task { await toggle(v) } }))
                    .labelsHidden()
                    .disabled(busy || service.terminated == true)
            }
            ForEach(service.targets) { t in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                    Text("\(t.path ?? "/") → \(t.protocol)://\(targetName(t)):\(t.port)")
                        .font(.caption.monospaced()).lineLimit(1)
                    if !t.enabled { Text("(aus)").font(.caption2) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func targetName(_ t: ProxyTarget) -> String {
        if t.targetType == "peer" { return store.peerName(t.targetId) }
        return t.host ?? t.targetId
    }

    private func toggle(_ enabled: Bool) async {
        busy = true
        defer { busy = false }
        if await store.perform({ try await $0.setProxyService(service.id, enabled: enabled) }) {
            if let i = store.services.firstIndex(where: { $0.id == service.id }) { store.services[i].enabled = enabled }
        }
    }
}

struct CreateProxyServiceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var subdomain = ""
    @State private var domainID = ""
    @State private var mode = "http"
    @State private var listenPort = 0
    @State private var targetType = "peer"
    @State private var peerID = ""
    @State private var host = ""
    @State private var proto = "http"
    @State private var port = 80
    @State private var path = "/"
    @State private var passHost = false
    @State private var rewriteRedirects = false
    @State private var saving = false

    var baseDomain: ReverseProxyDomain? { store.domains.first { $0.id == domainID } }
    var fullDomain: String {
        guard let d = baseDomain?.domain else { return subdomain }
        return subdomain.isEmpty ? d : "\(subdomain).\(d)"
    }

    var body: some View {
        Form {
            Section("Öffentliche Adresse") {
                TextField("Subdomain (z. B. app)", text: $subdomain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Domain", selection: $domainID) {
                    Text("wählen …").tag("")
                    ForEach(store.domains.filter(\.validated)) { Text($0.domain).tag($0.id) }
                }
                Text(fullDomain).font(.callout.monospaced()).foregroundStyle(.secondary)
                Picker("Modus", selection: $mode) {
                    Text("HTTP (L7)").tag("http")
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("TLS").tag("tls")
                }
                if mode != "http" {
                    Stepper("Listen-Port: \(listenPort == 0 ? "automatisch" : "\(listenPort)")", value: $listenPort, in: 0...65535)
                }
            }
            Section("Ziel") {
                Picker("Typ", selection: $targetType) {
                    Text("Peer").tag("peer")
                    Text("Host/IP").tag("host")
                }
                .pickerStyle(.segmented)
                if targetType == "peer" {
                    Picker("Peer", selection: $peerID) {
                        Text("wählen …").tag("")
                        ForEach(store.peers) { Text($0.name).tag($0.id) }
                    }
                } else {
                    TextField("IP oder Hostname", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("Protokoll", selection: $proto) {
                    if mode == "http" {
                        Text("http").tag("http")
                        Text("https").tag("https")
                    } else {
                        Text("tcp").tag("tcp")
                        Text("udp").tag("udp")
                    }
                }
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("80", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                }
                if mode == "http" {
                    TextField("Pfad", text: $path).textInputAutocapitalization(.never)
                    Toggle("Host-Header durchreichen", isOn: $passHost)
                    Toggle("Redirects umschreiben", isOn: $rewriteRedirects)
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Service anlegen") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(!valid || saving)
            } footer: {
                Text("Authentifizierung (SSO, Passwort, PIN) und Zugriffsbeschränkungen lassen sich anschließend im NetBird-Dashboard verfeinern.")
            }
        }
        .glassScreen()
        .navigationTitle("Neuer Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        .onChange(of: mode) { _, m in proto = (m == "http") ? "http" : (m == "udp" ? "udp" : "tcp") }
        .onAppear { if domainID.isEmpty { domainID = store.domains.first(where: \.validated)?.id ?? "" } }
    }

    private var valid: Bool {
        baseDomain != nil && (1...65535).contains(port) && (targetType == "peer" ? !peerID.isEmpty : !host.isEmpty)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let target = ProxyTarget(targetId: targetType == "peer" ? peerID : host,
                                 targetType: targetType,
                                 path: mode == "http" ? (path.isEmpty ? "/" : path) : nil,
                                 protocol: proto,
                                 host: targetType == "host" ? host : nil,
                                 port: port,
                                 enabled: true)
        let req = ProxyServiceRequest(name: fullDomain, domain: fullDomain, mode: mode,
                                      listenPort: mode == "http" ? nil : listenPort,
                                      targets: [target], enabled: true,
                                      passHostHeader: passHost, rewriteRedirects: rewriteRedirects)
        if await store.perform({ api in
            let s = try await api.createProxyService(req)
            store.services.append(s)
        }) { dismiss() }
    }
}

struct AddProxyDomainView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var cluster = ""

    var body: some View {
        Form {
            Section {
                TextField("app.example.com", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Proxy-Cluster", selection: $cluster) {
                    Text("wählen …").tag("")
                    ForEach(store.clusters) { Text($0.address).tag($0.address) }
                }
            } footer: {
                if !cluster.isEmpty {
                    Text("Lege einen CNAME-Eintrag \(domain.isEmpty ? "<domain>" : domain) → \(cluster) an und prüfe die Domain anschließend.")
                }
            }
            Section {
                Button("Domain hinzufügen") {
                    Task {
                        if await store.perform({ api in
                            let d = try await api.createProxyDomain(.init(domain: domain, targetCluster: cluster))
                            store.domains.append(d)
                        }) { dismiss() }
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(domain.isEmpty || cluster.isEmpty)
            }
        }
        .glassScreen()
        .navigationTitle("Eigene Domain")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        .onAppear { if cluster.isEmpty { cluster = store.clusters.first?.address ?? "" } }
    }
}
