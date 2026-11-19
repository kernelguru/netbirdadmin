import SwiftUI

/// Netzwerk-Route anlegen oder bearbeiten (CIDR IPv4/IPv6 oder Domains).
struct RouteEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let routeID: String?

    @State private var networkId = ""
    @State private var descriptionText = ""
    @State private var useDomains = false
    @State private var network = ""
    @State private var domains = ""
    @State private var viaGroup = false
    @State private var peerID = ""
    @State private var peerGroups: [String] = []
    @State private var groups: [String] = []
    @State private var accessGroups: [String] = []
    @State private var metric = 9999
    @State private var masquerade = true
    @State private var enabled = true
    @State private var keepRoute = true
    @State private var saving = false
    @State private var errorText: String?
    @State private var loaded = false
    @State private var confirmDelete = false

    var route: NBRoute? { routeID.flatMap { id in store.routes.first { $0.id == id } } }

    var body: some View {
        Form {
            Section {
                TextField("Kennung (z. B. buero-lan)", text: $networkId).textInputAutocapitalization(.never)
                TextField("Beschreibung", text: $descriptionText)
                Toggle("Aktiv", isOn: $enabled)
            } header: { Text("Route") }

            Section {
                Picker("Ziel", selection: $useDomains) {
                    Text("Netz (CIDR)").tag(false)
                    Text("Domains").tag(true)
                }
                .pickerStyle(.segmented)
                if useDomains {
                    TextField("example.com, *.intern.example.com", text: $domains, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Aufgelöste IPs behalten", isOn: $keepRoute)
                } else {
                    TextField("192.168.10.0/24 oder 2001:db8::/48", text: $network)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                    if let fam = family { Pill(text: fam, color: fam == "IPv6" ? .nbTeal : .nbBlue) }
                }
            } header: { Text("Netz") } footer: {
                Text(useDomains ? "Bis zu 32 Domains; die Routing-Peers lösen sie auf und leiten den Verkehr weiter." : "IPv4- und IPv6-Netze möglich. 0.0.0.0/0 bzw. ::/0 machen den Peer zum Exit-Node.")
            }

            Section {
                Picker("Routing über", selection: $viaGroup) {
                    Text("Peer").tag(false)
                    Text("Peer-Gruppe").tag(true)
                }
                .pickerStyle(.segmented)
                if viaGroup {
                    GroupPicker(selection: $peerGroups, excludeAll: true, allowCreate: false)
                } else {
                    Picker("Routing-Peer", selection: $peerID) {
                        Text("wählen …").tag("")
                        ForEach(store.peers) { p in Text("\(p.connected ? "●" : "○") \(p.name)").tag(p.id) }
                    }
                }
                Toggle("Masquerade (NAT)", isOn: $masquerade)
                Stepper("Metrik: \(metric)", value: $metric, in: 1...9999, step: 10)
            } header: { Text("Routing-Peer") } footer: {
                Text("Mit einer Peer-Gruppe entsteht Hochverfügbarkeit; die niedrigste Metrik gewinnt.")
            }

            Section {
                GroupPicker(selection: $groups, excludeAll: false)
            } header: { Text("Verteilen an") } footer: { Text("Peers dieser Gruppen erhalten die Route.") }

            Section {
                GroupPicker(selection: $accessGroups, excludeAll: false, allowCreate: false)
            } header: { Text("Zugriffskontrolle (optional)") } footer: {
                Text("Wenn gesetzt, gilt die Route nur in Verbindung mit Zugriffsrichtlinien auf diese Gruppen.")
            }

            Section {
                if let v = validationError {
                    Label(v, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text(routeID == nil ? "Route anlegen" : "Speichern") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(saving || validationError != nil)
                if routeID != nil {
                    Button("Route löschen", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .glassScreen()
        .navigationTitle(routeID == nil ? "Neue Route" : networkId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if routeID == nil { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .onAppear(perform: load)
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Route löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task {
                    guard let id = routeID else { return }
                    if await store.perform({ try await $0.deleteRoute(id) }) {
                        store.routes.removeAll { $0.id == id }
                        dismiss()
                    }
                }
            }
        }
    }

    private var family: String? {
        let n = network.trimmingCharacters(in: .whitespaces)
        guard n.contains("/") else { return nil }
        return n.contains(":") ? "IPv6" : "IPv4"
    }

    private var domainList: [String] { ServiceDraft.list(domains) }

    private var validationError: String? {
        if networkId.trimmingCharacters(in: .whitespaces).isEmpty { return "Kennung fehlt" }
        if networkId.count > 40 { return "Kennung max. 40 Zeichen" }
        if useDomains {
            if domainList.isEmpty { return "Mindestens eine Domain angeben" }
            if domainList.count > 32 { return "Maximal 32 Domains" }
        } else if !Self.isCIDR(network) {
            return "Netz im CIDR-Format angeben, z. B. 10.0.0.0/24"
        }
        if viaGroup ? peerGroups.isEmpty : peerID.isEmpty { return "Routing-Peer oder -Gruppe wählen" }
        if groups.isEmpty { return "Mindestens eine Verteil-Gruppe wählen" }
        return nil
    }

    static func isCIDR(_ s: String) -> Bool {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        let addr = String(parts[0])
        if addr.contains(":") {
            return bits >= 0 && bits <= 128 && addr.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let oct = addr.split(separator: ".", omittingEmptySubsequences: false)
        return bits >= 0 && bits <= 32 && oct.count == 4 && oct.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let r = route else {
            if let all = store.groups.first(where: { $0.name == "All" }) { groups = [all.id] }
            return
        }
        networkId = r.networkId
        descriptionText = r.description
        useDomains = !(r.domains?.isEmpty ?? true)
        network = r.network ?? ""
        domains = (r.domains ?? []).joined(separator: ", ")
        viaGroup = r.peer == nil
        peerID = r.peer ?? ""
        peerGroups = r.peerGroups ?? []
        groups = r.groups
        accessGroups = r.accessControlGroups ?? []
        metric = r.metric
        masquerade = r.masquerade
        enabled = r.enabled
        keepRoute = r.keepRoute
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var req = RouteRequest(description: descriptionText, networkId: networkId.trimmingCharacters(in: .whitespaces),
                               enabled: enabled, peer: viaGroup ? nil : peerID, peerGroups: viaGroup ? peerGroups : nil,
                               network: network.trimmingCharacters(in: .whitespaces), metric: metric,
                               masquerade: masquerade, groups: groups, skipAutoApply: route?.skipAutoApply ?? false)
        if useDomains {
            req.network = nil
            req.domains = domainList
        }
        req.keepRoute = keepRoute
        req.accessControlGroups = accessGroups.isEmpty ? nil : accessGroups
        do {
            let api = try store.api()
            if let id = routeID {
                let r = try await api.updateRoute(id, req)
                if let i = store.routes.firstIndex(where: { $0.id == id }) { store.routes[i] = r }
            } else {
                store.routes.append(try await api.createRoute(req))
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
