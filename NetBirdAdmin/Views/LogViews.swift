import SwiftUI

struct AuditLogView: View {
    @Environment(AppStore.self) private var store
    @State private var events: [AuditEvent] = []
    @State private var search = ""
    @State private var loading = false

    var filtered: [AuditEvent] {
        guard !search.isEmpty else { return events }
        return events.filter {
            $0.activity.localizedCaseInsensitiveContains(search) || $0.initiator.localizedCaseInsensitiveContains(search)
                || ($0.meta?.values.contains { $0.localizedCaseInsensitiveContains(search) } ?? false)
        }
    }

    var body: some View {
        List {
            if loading && events.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            ForEach(filtered.prefix(500)) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: icon(e.activityCode)).foregroundStyle(color(e.activityCode))
                        Text(e.activity).font(.subheadline.weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        Text(e.initiator)
                        if let t = e.timestamp { Text("· \(t.formatted(date: .abbreviated, time: .shortened))") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let meta = e.meta, !meta.isEmpty {
                        Text(meta.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle("Audit-Log")
        .searchable(text: $search, prompt: "Aktion, Benutzer, Peer …")
        .refreshable { await load() }
        .task { if events.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        _ = await store.perform { api in
            events = try await api.auditEvents().sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        }
    }

    private func icon(_ code: String) -> String {
        if code.contains("delete") || code.contains("revoke") || code.contains("block") { return "trash.circle.fill" }
        if code.contains("add") || code.contains("create") || code.contains("join") { return "plus.circle.fill" }
        if code.contains("login") { return "person.badge.key.fill" }
        return "pencil.circle.fill"
    }

    private func color(_ code: String) -> Color {
        if code.contains("delete") || code.contains("revoke") || code.contains("block") { return .red }
        if code.contains("add") || code.contains("create") || code.contains("join") { return .nbOnline }
        if code.contains("login") { return .nbBlue }
        return .nbOrange
    }
}

struct ProxyAccessLogView: View {
    @Environment(AppStore.self) private var store
    @State private var logs: [ProxyAccessLog] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var search = ""
    @State private var loading = false

    var body: some View {
        List {
            if !store.proxyAvailable {
                Text("Reverse-Proxy auf diesem Server nicht verfügbar.").foregroundStyle(.secondary)
            }
            ForEach(logs) { l in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let code = l.statusCode {
                            Pill(text: "\(code)", color: code < 300 ? .nbOnline : (code < 400 ? .nbBlue : (code < 500 ? .orange : .red)))
                        }
                        Text(l.method ?? (l.protocol ?? "").uppercased()).font(.caption.monospaced().weight(.bold))
                        Text("\(l.host ?? "")\(l.path ?? "")").font(.caption.monospaced()).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(l.sourceIp ?? "–")
                        if let c = l.countryCode, !c.isEmpty { Text(flag(c)) }
                        if let u = l.userId, !u.isEmpty { Text("· \(store.userName(u))") }
                        if let a = l.authMethodUsed, !a.isEmpty { Text("· \(a)") }
                        if let d = l.durationMs { Text("· \(d) ms") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        if let t = l.timestamp { Text(t.formatted(date: .abbreviated, time: .standard)) }
                        if let r = l.reason, !r.isEmpty { Text("· \(r)").foregroundStyle(.orange) }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            if page < totalPages {
                Button { Task { await load(reset: false) } } label: {
                    if loading { ProgressView().frame(maxWidth: .infinity) } else { Text("Mehr laden").frame(maxWidth: .infinity) }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
        }
        .glassScreen()
        .navigationTitle("Proxy-Zugriffe")
        .searchable(text: $search, prompt: "Host, Pfad, IP, Benutzer …")
        .onSubmit(of: .search) { Task { await load(reset: true) } }
        .refreshable { await load(reset: true) }
        .task { if logs.isEmpty { await load(reset: true) } }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        let next = reset ? 1 : page + 1
        _ = await store.perform { api in
            let r = try await api.proxyAccessLogs(page: next, pageSize: 50, search: search)
            if reset { logs = r.data } else { logs += r.data }
            page = next
            totalPages = r.totalPages ?? 1
        }
    }

    private func flag(_ code: String) -> String {
        code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

/// Debug-Paket eines Peers anfordern (NetBird lädt es auf den Upload-Server).
struct DebugBundleView: View {
    @Environment(AppStore.self) private var store
    let peer: Peer

    @State private var minutes = 2
    @State private var logFiles = 10
    @State private var anonymize = true
    @State private var jobs: [PeerJob] = []
    @State private var requesting = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Stepper("Aufzeichnung: \(minutes == 0 ? "aus" : "\(minutes) min")", value: $minutes, in: 0...5)
                Stepper("Log-Dateien: \(logFiles)", value: $logFiles, in: 1...100)
                Toggle("Anonymisieren", isOn: $anonymize)
                Button {
                    Task { await request() }
                } label: {
                    if requesting { ProgressView().frame(maxWidth: .infinity) } else { Label("Debug-Paket anfordern", systemImage: "ladybug") }
                }
                .disabled(requesting || !peer.connected)
            } header: { Text("Neues Debug-Paket") } footer: {
                Text(peer.connected
                     ? "Der Client erstellt das Paket (optional mit Trace-Aufzeichnung) und lädt es hoch. Den Upload-Schlüssel kannst du an den NetBird-Support geben."
                     : "Der Peer ist offline – Debug-Pakete gehen nur bei verbundenen Peers.")
            }
            Section("Aufträge") {
                if jobs.isEmpty { Text("Keine").foregroundStyle(.secondary) }
                ForEach(jobs) { j in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Pill(text: statusText(j.status), color: j.status == "succeeded" ? .nbOnline : (j.status == "failed" ? .red : .orange))
                            if let d = j.createdAt { Text(d.relative).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let key = j.workload?.result?.uploadKey, !key.isEmpty {
                            HStack {
                                Text(key).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button { UIPasteboard.general.string = key } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if let r = j.failedReason, !r.isEmpty { Text(r).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .glassScreen()
        .navigationTitle("Debug-Paket")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadJobs() }
        .task {
            await loadJobs()
            // laufende Aufträge nachverfolgen
            while !Task.isCancelled, jobs.contains(where: { $0.status == "pending" }) {
                try? await Task.sleep(for: .seconds(5))
                await loadJobs()
            }
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func statusText(_ s: String) -> String {
        switch s {
        case "succeeded": return "fertig"
        case "failed": return "fehlgeschlagen"
        default: return "läuft"
        }
    }

    private func loadJobs() async {
        guard let api = try? store.api() else { return }
        if let j = try? await api.peerJobs(peer.id) {
            jobs = j.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
    }

    private func request() async {
        requesting = true
        defer { requesting = false }
        do {
            let j = try await store.api().requestDebugBundle(peer.id, minutes: minutes, logFiles: logFiles, anonymize: anonymize)
            jobs.insert(j, at: 0)
            while !Task.isCancelled, jobs.contains(where: { $0.status == "pending" }) {
                try? await Task.sleep(for: .seconds(5))
                await loadJobs()
            }
        } catch { errorText = error.localizedDescription }
    }
}

/// Peers und Benutzer, die auf Freigabe warten.
struct ApprovalsView: View {
    @Environment(AppStore.self) private var store
    @State private var peerApproval = false

    var body: some View {
        List {
            Section {
                if store.pendingPeers.isEmpty { Text("Keine Peers warten auf Freigabe").foregroundStyle(.secondary) }
                ForEach(store.pendingPeers) { p in
                    HStack {
                        PeerRow(peer: p)
                        Button("Freigeben") {
                            Task {
                                _ = await store.perform { api in
                                    let u = try await api.approvePeer(p)
                                    if let i = store.peers.firstIndex(where: { $0.id == p.id }) { store.peers[i] = u }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { if await store.perform({ try await $0.deletePeer(p.id) }) { store.peers.removeAll { $0.id == p.id } } }
                        } label: { Label("Ablehnen", systemImage: "xmark") }
                    }
                }
            } header: { Text("Neue Peers") }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            Section {
                if store.pendingUsers.isEmpty { Text("Keine Benutzer warten auf Freigabe").foregroundStyle(.secondary) }
                ForEach(store.pendingUsers) { u in
                    HStack {
                        UserRow(user: u)
                        Spacer()
                        Button("Freigeben") {
                            Task { if await store.perform({ try await $0.approveUser(u.id) }) { await store.reloadUsers() } }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { if await store.perform({ try await $0.rejectUser(u.id) }) { await store.reloadUsers() } }
                        } label: { Label("Ablehnen", systemImage: "xmark") }
                    }
                }
            } header: { Text("Neue Benutzer") }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            Section {
                Toggle("Neue Peers müssen freigegeben werden", isOn: $peerApproval)
                    .onChange(of: peerApproval) { _, v in Task { await setExtra("peer_approval_enabled", v) } }
                Toggle("Neue Benutzer müssen freigegeben werden", isOn: Binding(
                    get: { store.account?.settings["extra"]?["user_approval_required"]?.boolValue ?? false },
                    set: { v in Task { await setExtra("user_approval_required", v) } }))
            } header: { Text("Einstellungen") } footer: {
                Text("Die Peer-Freigabe ist laut NetBird eine Cloud-Funktion; selbst gehostete Server ignorieren sie ggf. Die Benutzer-Freigabe gilt für Benutzer, die über Domain-Zuordnung beitreten.")
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle("Freigaben")
        .refreshable { await store.refreshAll() }
        .onAppear { peerApproval = store.account?.settings["extra"]?["peer_approval_enabled"]?.boolValue ?? false }
    }

    private func setExtra(_ key: String, _ value: Bool) async {
        guard var account = store.account else { return }
        var extra = account.settings["extra"] ?? .object([:])
        if extra.objectValue == nil { extra = .object([:]) }
        guard extra[key]?.boolValue != value else { return }
        extra[key] = .bool(value)
        account.settings["extra"] = extra
        let settings = account.settings
        if await store.perform({ try await $0.updateAccountSettings(account.id, settings: settings) }) {
            store.account = account
        }
    }
}
