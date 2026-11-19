import SwiftUI

/// Netzwerke (neues Routing-Modell): Ressourcen + Routing-Peers.
struct NetworksView: View {
    @Environment(AppStore.self) private var store
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newDescription = ""

    var body: some View {
        List {
            Section {
                if store.networks.isEmpty { Text("Keine Netzwerke").foregroundStyle(.secondary) }
                ForEach(store.networks) { n in
                    NavigationLink { NetworkDetailView(networkID: n.id) } label: {
                        HStack {
                            Image(systemName: "network").foregroundStyle(Color.nbBlue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.name).font(.subheadline.weight(.semibold))
                                if let d = n.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                                HStack(spacing: 4) {
                                    Pill(text: "\(n.resources?.count ?? 0) Ressourcen", color: .nbTeal)
                                    Pill(text: "\(n.routingPeersCount ?? n.routers?.count ?? 0) Router", color: .nbBlue)
                                    if (n.policies ?? []).isEmpty { Pill(text: "keine Richtlinie", color: .orange) }
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteNetwork(n.id) }) {
                                    store.networks.removeAll { $0.id == n.id }
                                }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
            } footer: {
                Text("Ein Netzwerk bündelt Ressourcen (Hosts, Subnetze, Domains) hinter Routing-Peers. Zugriff gibt es erst mit einer Zugriffsrichtlinie auf die Ressource bzw. ihre Gruppe.")
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle("Netzwerke")
        .refreshable { await store.loadNetworks() }
        .task { await store.loadNetworks() }
        .toolbar { Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") } }
        .alert("Neues Netzwerk", isPresented: $showCreate) {
            TextField("Name", text: $newName)
            TextField("Beschreibung", text: $newDescription)
            Button("Anlegen") {
                Task {
                    let req = NetworkRequest(name: newName, description: newDescription)
                    _ = await store.perform { api in store.networks.append(try await api.createNetwork(req)) }
                    newName = ""; newDescription = ""
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}

struct NetworkDetailView: View {
    @Environment(AppStore.self) private var store
    let networkID: String

    @State private var resources: [NetworkResourceDetail] = []
    @State private var routers: [NetworkRouter] = []
    @State private var editingResource: NetworkResourceDetail?
    @State private var addResource = false
    @State private var editingRouter: NetworkRouter?
    @State private var addRouter = false
    @State private var name = ""
    @State private var descriptionText = ""

    var network: NBNetwork? { store.networks.first { $0.id == networkID } }

    var body: some View {
        List {
            Section("Netzwerk") {
                TextField("Name", text: $name)
                TextField("Beschreibung", text: $descriptionText)
                Button("Speichern") {
                    Task {
                        let req = NetworkRequest(name: name, description: descriptionText)
                        _ = await store.perform { api in
                            let n = try await api.updateNetwork(networkID, req)
                            if let i = store.networks.firstIndex(where: { $0.id == networkID }) { store.networks[i] = n }
                        }
                    }
                }
                .disabled(name.isEmpty || (name == network?.name && descriptionText == (network?.description ?? "")))
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            Section {
                ForEach(resources) { r in
                    Button { editingResource = r } label: {
                        HStack {
                            Image(systemName: icon(r.type)).foregroundStyle(r.enabled ? Color.nbTeal : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).foregroundStyle(.primary)
                                Text(r.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if !r.groups.isEmpty {
                                    Text(r.groups.map(\.name).joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if !r.enabled { Pill(text: "aus", color: .gray) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteNetworkResource(networkID, r.id) }) { await load() }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
                Button { addResource = true } label: { Label("Ressource hinzufügen", systemImage: "plus") }
            } header: { Text("Ressourcen") }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            Section {
                ForEach(routers) { r in
                    Button { editingRouter = r } label: {
                        HStack {
                            StatusDot(online: r.enabled && (r.peer.map { id in store.peers.first { $0.id == id }?.connected ?? false } ?? true))
                            VStack(alignment: .leading) {
                                Text(r.peer.map { store.peerName($0) } ?? (r.peerGroups ?? []).map { store.groupName($0) }.joined(separator: ", "))
                                    .foregroundStyle(.primary)
                                Text("Metrik \(r.metric)\(r.masquerade ? " · NAT" : "")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteNetworkRouter(networkID, r.id) }) { await load() }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
                Button { addRouter = true } label: { Label("Routing-Peer hinzufügen", systemImage: "plus") }
            } header: { Text("Routing-Peers") }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            Section {
                NavigationLink { PoliciesView() } label: { Label("Zugriffsrichtlinien verwalten", systemImage: "checkmark.shield") }
            } footer: { Text("Ressourcen sind erst erreichbar, wenn eine Richtlinie Zugriff auf sie (oder ihre Gruppen) erlaubt.") }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle(network?.name ?? "Netzwerk")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            name = network?.name ?? ""
            descriptionText = network?.description ?? ""
            await load()
        }
        .sheet(item: $editingResource) { r in NavigationStack { ResourceEditorView(networkID: networkID, resource: r) { Task { await load() } } } }
        .sheet(isPresented: $addResource) { NavigationStack { ResourceEditorView(networkID: networkID, resource: nil) { Task { await load() } } } }
        .sheet(item: $editingRouter) { r in NavigationStack { RouterEditorView(networkID: networkID, router: r) { Task { await load() } } } }
        .sheet(isPresented: $addRouter) { NavigationStack { RouterEditorView(networkID: networkID, router: nil) { Task { await load() } } } }
    }

    private func icon(_ type: String) -> String {
        switch type {
        case "subnet": return "square.grid.3x3"
        case "domain": return "globe"
        default: return "server.rack"
        }
    }

    private func load() async {
        guard let api = try? store.api() else { return }
        do {
            async let r = api.networkResourceDetails(networkID)
            async let ro = api.networkRouters(networkID)
            resources = try await r
            routers = try await ro
        } catch { store.lastError = error.localizedDescription }
        await store.loadResources()
    }
}

struct ResourceEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let networkID: String
    let resource: NetworkResourceDetail?
    var onSaved: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var address = ""
    @State private var enabled = true
    @State private var groups: [String] = []
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Beschreibung", text: $description)
                TextField("Adresse: 10.0.0.5, 10.0.0.0/24, 2001:db8::/64, *.intern.de", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                Toggle("Aktiv", isOn: $enabled)
            } footer: { Text("Einzelne IP → Host, CIDR → Subnetz, Name → Domain (Wildcards möglich).") }
            Section("Gruppen") { GroupPicker(selection: $groups) }
        }
        .glassScreen()
        .navigationTitle(resource == nil ? "Neue Ressource" : resource!.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { Task { await save() } }.disabled(name.isEmpty || address.isEmpty)
            }
        }
        .onAppear {
            guard let r = resource else { return }
            name = r.name; description = r.description ?? ""; address = r.address
            enabled = r.enabled; groups = r.groups.map(\.id)
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func save() async {
        let req = NetworkResourceRequest(name: name, description: description,
                                         address: address.trimmingCharacters(in: .whitespaces), enabled: enabled, groups: groups)
        do {
            let api = try store.api()
            if let r = resource { _ = try await api.updateNetworkResource(networkID, r.id, req) }
            else { _ = try await api.createNetworkResource(networkID, req) }
            onSaved()
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

struct RouterEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let networkID: String
    let router: NetworkRouter?
    var onSaved: () -> Void

    @State private var viaGroup = false
    @State private var peerID = ""
    @State private var peerGroups: [String] = []
    @State private var metric = 9999
    @State private var masquerade = true
    @State private var enabled = true
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Picker("Routing über", selection: $viaGroup) {
                    Text("Peer").tag(false)
                    Text("Peer-Gruppe").tag(true)
                }
                .pickerStyle(.segmented)
                if viaGroup {
                    GroupPicker(selection: $peerGroups, excludeAll: true, allowCreate: false)
                } else {
                    Picker("Peer", selection: $peerID) {
                        Text("wählen …").tag("")
                        ForEach(store.peers) { p in Text("\(p.connected ? "●" : "○") \(p.name)").tag(p.id) }
                    }
                }
                Toggle("Masquerade (NAT)", isOn: $masquerade)
                Stepper("Metrik: \(metric)", value: $metric, in: 1...9999, step: 10)
                Toggle("Aktiv", isOn: $enabled)
            }
        }
        .glassScreen()
        .navigationTitle(router == nil ? "Routing-Peer" : "Router bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { Task { await save() } }.disabled(viaGroup ? peerGroups.isEmpty : peerID.isEmpty)
            }
        }
        .onAppear {
            guard let r = router else { return }
            viaGroup = r.peer == nil
            peerID = r.peer ?? ""; peerGroups = r.peerGroups ?? []
            metric = r.metric; masquerade = r.masquerade; enabled = r.enabled
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func save() async {
        let req = NetworkRouterRequest(peer: viaGroup ? nil : peerID, peerGroups: viaGroup ? peerGroups : nil,
                                       metric: metric, masquerade: masquerade, enabled: enabled)
        do {
            let api = try store.api()
            if let r = router { _ = try await api.updateNetworkRouter(networkID, r.id, req) }
            else { _ = try await api.createNetworkRouter(networkID, req) }
            onSaved()
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}
