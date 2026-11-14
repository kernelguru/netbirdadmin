import SwiftUI

/// Exit-Nodes (0.0.0.0/0 und ::/0) sowie IPv6-Overlay-Einstellungen.
struct NetworkView: View {
    @Environment(AppStore.self) private var store
    @State private var showCreate = false

    /// Exit-Nodes nach network_id gruppiert (IPv4 + IPv6 gehören zusammen)
    var exitGroups: [(id: String, routes: [NBRoute])] {
        Dictionary(grouping: store.exitNodes, by: \.networkId)
            .map { (id: $0.key, routes: $0.value.sorted { !$0.isIPv6 && $1.isIPv6 }) }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if exitGroups.isEmpty {
                        Text("Keine Exit-Nodes konfiguriert").foregroundStyle(.secondary)
                    }
                    ForEach(exitGroups, id: \.id) { g in
                        NavigationLink { ExitNodeDetailView(networkID: g.id) } label: { ExitNodeRow(routes: g.routes) }
                    }
                } header: { Text("Exit-Nodes") } footer: {
                    Text("Ein Exit-Node leitet den gesamten Internet-Verkehr der Clients (0.0.0.0/0, bei IPv6 zusätzlich ::/0) über einen Peer.")
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                IPv6Section()

                Section("Weitere Routen") {
                    let others = store.routes.filter { !$0.isExitNode }
                    if others.isEmpty { Text("Keine").foregroundStyle(.secondary) }
                    ForEach(others) { r in
                        HStack {
                            Image(systemName: r.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(r.enabled ? Color.nbOnline : .secondary)
                            VStack(alignment: .leading) {
                                Text(r.networkId).font(.subheadline)
                                Text(r.network ?? r.domains?.joined(separator: ", ") ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
            .glassScreen()
            .navigationTitle("Netzwerk")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Label("Exit-Node", systemImage: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $showCreate) { NavigationStack { CreateExitNodeView() } }
        }
    }
}

struct ExitNodeRow: View {
    @Environment(AppStore.self) private var store
    let routes: [NBRoute]

    var body: some View {
        let r = routes[0]
        let routerOnline: Bool = {
            if let pid = r.peer { return store.peers.first { $0.id == pid }?.connected ?? false }
            return true
        }()
        HStack(spacing: 12) {
            Image(systemName: "door.right.hand.open")
                .font(.title3)
                .foregroundStyle(r.enabled ? Color.nbBlue : .secondary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(online: r.enabled && routerOnline)
                    Text(r.networkId).font(.subheadline.weight(.semibold))
                }
                Text(routerText(r)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(routes) { rr in Pill(text: rr.isIPv6 ? "IPv6 ::/0" : "IPv4 0.0.0.0/0", color: rr.isIPv6 ? .nbTeal : .nbBlue) }
                    if r.masquerade { Pill(text: "NAT", color: .gray) }
                }
            }
        }
    }

    private func routerText(_ r: NBRoute) -> String {
        if let p = r.peer { return "Peer: \(store.peerName(p))" }
        if let g = r.peerGroups, !g.isEmpty { return "Gruppen: " + g.map { store.groupName($0) }.joined(separator: ", ") }
        return ""
    }
}

struct ExitNodeDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let networkID: String
    @State private var confirmDelete = false
    @State private var busy = false

    var routes: [NBRoute] { store.exitNodes.filter { $0.networkId == networkID } }
    var hasV6: Bool { routes.contains(where: \.isIPv6) }

    var body: some View {
        Form {
            if let r = routes.first {
                Section("Routing") {
                    LabeledContent("Routing-Peer", value: r.peer.map { store.peerName($0) } ?? (r.peerGroups ?? []).map { store.groupName($0) }.joined(separator: ", "))
                    LabeledContent("Metrik", value: "\(r.metric)")
                    LabeledContent("Masquerade", value: r.masquerade ? "ja" : "nein")
                    LabeledContent("Verteilt an", value: r.groups.map { store.groupName($0) }.joined(separator: ", "))
                    if !r.description.isEmpty { LabeledContent("Beschreibung", value: r.description) }
                }
                Section("Status") {
                    ForEach(routes) { rr in
                        Toggle(isOn: Binding(get: { rr.enabled }, set: { v in Task { await setEnabled(rr, v) } })) {
                            VStack(alignment: .leading) {
                                Text(rr.isIPv6 ? "IPv6 (::/0)" : "IPv4 (0.0.0.0/0)")
                                Text(rr.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(isOn: Binding(get: { !(r.skipAutoApply ?? false) }, set: { v in Task { await setAutoApply(v) } })) {
                        VStack(alignment: .leading) {
                            Text("Automatisch anwenden")
                            Text("Clients nutzen den Exit-Node sofort, ohne manuelle Auswahl").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !hasV6 {
                    Section {
                        Button { Task { await addV6(r) } } label: {
                            Label("IPv6-Exit (::/0) ergänzen", systemImage: "6.circle")
                        }
                        .disabled(busy)
                    } footer: {
                        Text(store.ipv6Enabled ? "Leitet zusätzlich den IPv6-Verkehr über diesen Exit-Node." : "IPv6 ist im Account noch nicht aktiviert (siehe Netzwerk → IPv6).")
                    }
                }
                Section { Button("Exit-Node löschen", role: .destructive) { confirmDelete = true } }
            } else {
                Text("Nicht gefunden")
            }
        }
        .glassScreen()
        .navigationTitle(networkID)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Exit-Node löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await deleteAll() } }
        }
    }

    private func replace(_ r: NBRoute) {
        if let i = store.routes.firstIndex(where: { $0.id == r.id }) { store.routes[i] = r }
    }

    private func setEnabled(_ r: NBRoute, _ v: Bool) async {
        var req = RouteRequest(from: r)
        req.enabled = v
        _ = await store.perform { api in replace(try await api.updateRoute(r.id, req)) }
    }

    private func setAutoApply(_ v: Bool) async {
        for r in routes {
            var req = RouteRequest(from: r)
            req.skipAutoApply = !v
            _ = await store.perform { api in replace(try await api.updateRoute(r.id, req)) }
        }
    }

    private func addV6(_ r: NBRoute) async {
        busy = true
        defer { busy = false }
        var req = RouteRequest(from: r)
        req.network = "::/0"
        _ = await store.perform { api in store.routes.append(try await api.createRoute(req)) }
    }

    private func deleteAll() async {
        for r in routes {
            if await store.perform({ try await $0.deleteRoute(r.id) }) { store.routes.removeAll { $0.id == r.id } }
        }
        dismiss()
    }
}

struct CreateExitNodeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = "exit-node"
    @State private var peerID = ""
    @State private var distribution: Set<String> = []
    @State private var includeV6 = true
    @State private var masquerade = true
    @State private var autoApply = false
    @State private var metric = 9999
    @State private var saving = false

    var body: some View {
        Form {
            Section("Exit-Node") {
                TextField("Netzwerk-Kennung", text: $name).textInputAutocapitalization(.never)
                Picker("Routing-Peer", selection: $peerID) {
                    Text("wählen …").tag("")
                    ForEach(store.peers) { p in
                        Text("\(p.connected ? "●" : "○") \(p.name)").tag(p.id)
                    }
                }
                Toggle("Masquerade (NAT)", isOn: $masquerade)
                Stepper("Metrik: \(metric)", value: $metric, in: 1...9999, step: 100)
                Toggle("Automatisch anwenden", isOn: $autoApply)
            }
            Section {
                Toggle("IPv6 (::/0) ebenfalls routen", isOn: $includeV6)
            } footer: {
                Text(store.ipv6Enabled
                     ? "Legt zusätzlich eine ::/0-Route an, damit auch IPv6-Verkehr über den Exit-Node läuft."
                     : "Hinweis: IPv6-Overlay ist im Account nicht aktiv. Die ::/0-Route wird angelegt, wirkt aber erst nach Aktivierung.")
            }
            Section("Verteilen an Gruppen") {
                ForEach(store.groups) { g in
                    Button {
                        if distribution.contains(g.id) { distribution.remove(g.id) } else { distribution.insert(g.id) }
                    } label: {
                        HStack {
                            Text(g.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(g.peersCount)").foregroundStyle(.secondary)
                            if distribution.contains(g.id) { Image(systemName: "checkmark").foregroundStyle(Color.nbOrange) }
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Exit-Node anlegen") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(peerID.isEmpty || distribution.isEmpty || name.isEmpty || saving)
            }
        }
        .glassScreen()
        .navigationTitle("Neuer Exit-Node")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        .onAppear {
            if distribution.isEmpty, let all = store.groups.first(where: { $0.name == "All" }) { distribution = [all.id] }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let networks = includeV6 ? ["0.0.0.0/0", "::/0"] : ["0.0.0.0/0"]
        var ok = true
        for net in networks {
            let req = RouteRequest(description: "Exit-Node via NetBird Admin (iOS)", networkId: name, enabled: true,
                                   peer: peerID, peerGroups: nil, network: net, metric: metric,
                                   masquerade: masquerade, groups: Array(distribution), skipAutoApply: !autoApply)
            ok = await store.perform { api in store.routes.append(try await api.createRoute(req)) } && ok
        }
        if ok { dismiss() }
    }
}

/// IPv6-Overlay: Gruppen, deren Peers eine IPv6-Adresse erhalten, sowie IPv6-Netzbereich.
struct IPv6Section: View {
    @Environment(AppStore.self) private var store
    @State private var showEditor = false

    var body: some View {
        Section {
            if let s = store.account?.settings {
                let groups = s["ipv6_enabled_groups"]?.stringArray ?? []
                HStack {
                    Image(systemName: "6.circle.fill").foregroundStyle(groups.isEmpty ? Color.secondary : Color.nbTeal)
                    Text(groups.isEmpty ? "IPv6 deaktiviert" : "IPv6 aktiv")
                    Spacer()
                    Text("\(store.peers.filter { !($0.ipv6 ?? "").isEmpty }.count) Peers mit IPv6").font(.caption).foregroundStyle(.secondary)
                }
                if let range = s["network_range_v6"]?.stringValue, !range.isEmpty {
                    LabeledContent("Netzbereich", value: range).font(.callout.monospaced())
                }
                if !groups.isEmpty {
                    Text(groups.map { store.groupName($0) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                Button("IPv6 konfigurieren") { showEditor = true }
            } else {
                Text("Account-Einstellungen nicht verfügbar (Server zu alt oder fehlende Rechte).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("IPv6-Overlay") }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        .sheet(isPresented: $showEditor) { NavigationStack { IPv6EditorView() } }
    }
}

struct IPv6EditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var range = ""
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                Button("Für alle Peers aktivieren") {
                    if let all = store.groups.first(where: { $0.name == "All" }) { selected = [all.id] }
                }
                Button("IPv6 deaktivieren", role: .destructive) { selected = [] }
            }
            Section("Gruppen mit IPv6-Adressen") {
                ForEach(store.groups) { g in
                    Button {
                        if selected.contains(g.id) { selected.remove(g.id) } else { selected.insert(g.id) }
                    } label: {
                        HStack {
                            Text(g.name).foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(g.id) { Image(systemName: "checkmark").foregroundStyle(Color.nbTeal) }
                        }
                    }
                }
            }
            Section {
                TextField("fd00:1234:5678::/64 (leer = automatisch)", text: $range)
                    .font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("IPv6-Netzbereich (ULA)") } footer: {
                Text("Eine Änderung des Bereichs vergibt allen Peers neue IPv6-Adressen.")
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Speichern") }
                }
                .buttonStyle(GlassButtonStyle(tint: .nbTeal))
                .listRowBackground(Color.clear)
                .disabled(saving || !rangeValid)
            }
        }
        .glassScreen()
        .navigationTitle("IPv6")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        .onAppear {
            selected = Set(store.account?.settings["ipv6_enabled_groups"]?.stringArray ?? [])
            range = store.account?.settings["network_range_v6"]?.stringValue ?? ""
        }
    }

    private var rangeValid: Bool {
        range.isEmpty || (range.contains(":") && range.contains("/"))
    }

    private func save() async {
        guard var account = store.account else { return }
        saving = true
        defer { saving = false }
        account.settings["ipv6_enabled_groups"] = .array(selected.sorted().map { .string($0) })
        if !range.isEmpty { account.settings["network_range_v6"] = .string(range) }
        let settings = account.settings
        if await store.perform({ try await $0.updateAccountSettings(account.id, settings: settings) }) {
            store.account = account
            await store.refreshAll()
            dismiss()
        }
    }
}
