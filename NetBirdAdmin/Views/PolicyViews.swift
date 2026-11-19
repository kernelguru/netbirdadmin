import SwiftUI

/// Zugriffsrichtlinien: welche Gruppe erreicht welche Gruppe/Ressource auf welchen Ports.
struct PoliciesView: View {
    @Environment(AppStore.self) private var store
    @State private var showCreate = false

    var body: some View {
        List {
            Section {
                if store.policies.isEmpty { Text("Keine Richtlinien").foregroundStyle(.secondary) }
                ForEach(store.policies) { p in
                    NavigationLink { PolicyEditorView(policyID: p.id) } label: { PolicyRow(policy: p) }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    if await store.perform({ try await $0.deletePolicy(p.id) }) {
                                        store.policies.removeAll { $0.id == p.id }
                                    }
                                }
                            } label: { Label("Löschen", systemImage: "trash") }
                            Button { Task { await toggle(p) } } label: {
                                Label(p.enabled ? "Aus" : "An", systemImage: "power")
                            }
                            .tint(.orange)
                        }
                }
            } footer: {
                Text("NetBird blockiert standardmäßig alles. Erst eine Richtlinie erlaubt Verbindungen zwischen Gruppen bzw. zu Netzwerk-Ressourcen.")
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle("Zugriffsrichtlinien")
        .refreshable { await store.loadPolicies() }
        .task { await store.loadPolicies() }
        .toolbar {
            Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
        }
        .sheet(isPresented: $showCreate) { NavigationStack { PolicyEditorView(policyID: nil) } }
    }

    private func toggle(_ p: NBPolicy) async {
        _ = await store.perform { api in
            var raw = try await api.rawPolicy(p.id)
            raw["enabled"] = .bool(!p.enabled)
            let updated = try await api.updatePolicyRaw(p.id, PolicyDraft.normalize(raw))
            if let i = store.policies.firstIndex(where: { $0.id == p.id }) { store.policies[i] = updated }
        }
    }
}

struct PolicyRow: View {
    @Environment(AppStore.self) private var store
    let policy: NBPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: policy.enabled ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(policy.enabled ? Color.nbOnline : .secondary)
                Text(policy.name).font(.subheadline.weight(.semibold))
            }
            ForEach(Array(policy.rules.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 4) {
                    Text((r.sources ?? []).map(\.name).joined(separator: ", "))
                    Image(systemName: r.bidirectional ? "arrow.left.arrow.right" : "arrow.right")
                    Text(r.destinationResource != nil
                         ? (store.resources.first { $0.id == r.destinationResource?.id }?.name ?? "Ressource")
                         : (r.destinations ?? []).map(\.name).joined(separator: ", "))
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Pill(text: r.protocol.uppercased(), color: .nbBlue)
                    if r.protocol == "tcp" || r.protocol == "udp" { Pill(text: r.portText, color: .gray) }
                    if r.action == "drop" { Pill(text: "blockieren", color: .red) }
                }
            }
        }
    }
}

/// Bearbeitet die erste Regel einer Richtlinie; weitere Regeln bleiben unverändert erhalten.
struct PolicyDraft {
    var name = ""
    var description = ""
    var enabled = true
    var action = "accept"
    var proto = "all"
    var bidirectional = true
    var ports = ""
    var sources: [String] = []
    var destinations: [String] = []
    var destinationResourceID = ""
    var useResource = false
    var raw: JSONValue = .object([:])

    init() {}

    init(raw: JSONValue) {
        self.raw = raw
        name = raw["name"]?.stringValue ?? ""
        description = raw["description"]?.stringValue ?? ""
        enabled = raw["enabled"]?.boolValue ?? true
        guard let r = raw["rules"]?.arrayValue?.first else { return }
        action = r["action"]?.stringValue ?? "accept"
        proto = r["protocol"]?.stringValue ?? "all"
        bidirectional = r["bidirectional"]?.boolValue ?? true
        let single = r["ports"]?.stringArray ?? []
        let ranges = (r["port_ranges"]?.arrayValue ?? []).compactMap { pr -> String? in
            guard let a = pr["start"]?.intValue, let b = pr["end"]?.intValue else { return nil }
            return a == b ? "\(a)" : "\(a)-\(b)"
        }
        ports = (single + ranges).joined(separator: ", ")
        sources = Self.ids(r["sources"])
        destinations = Self.ids(r["destinations"])
        if let id = r["destinationResource"]?["id"]?.stringValue, !id.isEmpty {
            useResource = true
            destinationResourceID = id
        }
    }

    static func ids(_ v: JSONValue?) -> [String] {
        (v?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["id"]?.stringValue }
    }

    /// Antwort-Format (Gruppen als Objekte) in Request-Format (IDs) umwandeln.
    static func normalize(_ raw: JSONValue) -> JSONValue {
        var p = raw.removing(["id"])
        let rules = (raw["rules"]?.arrayValue ?? []).map { r -> JSONValue in
            var r = r
            r["sources"] = .strings(ids(r["sources"]))
            r["destinations"] = .strings(ids(r["destinations"]))
            return r
        }
        p["rules"] = .array(rules)
        if p["source_posture_checks"] == nil { p["source_posture_checks"] = .array([]) }
        return p
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name fehlt" }
        if sources.isEmpty { return "Quell-Gruppe wählen" }
        if useResource ? destinationResourceID.isEmpty : destinations.isEmpty { return "Ziel wählen" }
        if proto == "tcp" || proto == "udp" {
            for p in ServiceDraft.list(ports) {
                let parts = p.split(separator: "-").map { Int($0) }
                if parts.isEmpty || parts.count > 2 || parts.contains(where: { $0 == nil || !(1...65535).contains($0!) }) {
                    return "Ungültiger Port: \(p)"
                }
            }
        }
        return nil
    }

    func json() -> JSONValue {
        var p = Self.normalize(raw)
        p["name"] = .string(name)
        p["description"] = .string(description)
        p["enabled"] = .bool(enabled)
        var rules = p["rules"]?.arrayValue ?? []
        var r: JSONValue = rules.first ?? .object([:])
        r["name"] = .string(name)
        r["description"] = .string(description)
        r["enabled"] = .bool(true)
        r["action"] = .string(action)
        r["protocol"] = .string(proto)
        // Ressourcen-Ziele sind immer einseitig
        r["bidirectional"] = .bool(useResource ? false : bidirectional)
        r["sources"] = .strings(sources)
        var single: [String] = []
        var ranges: [JSONValue] = []
        if proto == "tcp" || proto == "udp" {
            for x in ServiceDraft.list(ports) {
                let parts = x.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 { ranges.append(.object(["start": .int(parts[0]), "end": .int(parts[1])])) }
                else if parts.count == 1 { single.append(String(parts[0])) }
            }
        }
        r["ports"] = .strings(single)
        r["port_ranges"] = .array(ranges)
        if useResource, let type = r["destinationResource"]?["type"]?.stringValue ?? Optional("host") {
            r["destinations"] = .array([])
            r["destinationResource"] = .object(["id": .string(destinationResourceID), "type": .string(type)])
        } else {
            r["destinations"] = .strings(destinations)
            r["destinationResource"] = nil
        }
        if rules.isEmpty { rules = [r] } else { rules[0] = r }
        p["rules"] = .array(rules)
        return p
    }
}

struct PolicyEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let policyID: String?

    @State private var draft = PolicyDraft()
    @State private var loaded = false
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Beschreibung", text: $draft.description)
                Toggle("Aktiv", isOn: $draft.enabled)
                Picker("Aktion", selection: $draft.action) {
                    Text("Erlauben").tag("accept")
                    Text("Blockieren").tag("drop")
                }
                .pickerStyle(.segmented)
            } header: { Text("Richtlinie") }

            Section {
                GroupPicker(selection: $draft.sources, excludeAll: false)
            } header: { Text("Quelle – diese Gruppen …") }

            Section {
                Picker("Ziel", selection: $draft.useResource) {
                    Text("Gruppen").tag(false)
                    Text("Netzwerk-Ressource").tag(true)
                }
                .pickerStyle(.segmented)
                if draft.useResource {
                    Picker("Ressource", selection: $draft.destinationResourceID) {
                        Text("wählen …").tag("")
                        ForEach(store.resources) { r in Text("\(r.name) (\(r.address))").tag(r.id) }
                    }
                } else {
                    GroupPicker(selection: $draft.destinations, excludeAll: false)
                    Toggle("In beide Richtungen", isOn: $draft.bidirectional)
                }
            } header: { Text("… erreichen dieses Ziel") }

            Section {
                Picker("Protokoll", selection: $draft.proto) {
                    Text("Alle").tag("all")
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("ICMP").tag("icmp")
                    Text("NetBird-SSH").tag("netbird-ssh")
                }
                if draft.proto == "tcp" || draft.proto == "udp" {
                    TextField("Ports, z. B. 22, 443, 8000-8100 (leer = alle)", text: $draft.ports)
                        .keyboardType(.numbersAndPunctuation).font(.body.monospaced())
                }
            } header: { Text("Protokoll & Ports") }

            Section {
                if let v = draft.validationError {
                    Label(v, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text(policyID == nil ? "Richtlinie anlegen" : "Speichern") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(saving || draft.validationError != nil)
            } footer: {
                if (draft.raw["rules"]?.arrayValue?.count ?? 0) > 1 {
                    Text("Diese Richtlinie hat mehrere Regeln; bearbeitet wird die erste, die übrigen bleiben erhalten.")
                }
            }
        }
        .glassScreen()
        .navigationTitle(policyID == nil ? "Neue Richtlinie" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if policyID == nil { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .task { await load() }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        if store.resources.isEmpty { await store.loadResources() }
        guard let id = policyID else { return }
        do { draft = PolicyDraft(raw: try await store.api().rawPolicy(id)) }
        catch { errorText = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let api = try store.api()
            if let r = store.resources.first(where: { $0.id == draft.destinationResourceID }), draft.useResource {
                draft.raw["rules"] = draft.raw["rules"].map { rules in
                    var arr = rules.arrayValue ?? []
                    if !arr.isEmpty { arr[0]["destinationResource"] = .object(["id": .string(r.id), "type": .string(r.type)]) }
                    return .array(arr)
                }
                if draft.raw["rules"]?.arrayValue?.isEmpty ?? true {
                    draft.raw["rules"] = .array([.object(["destinationResource": .object(["id": .string(r.id), "type": .string(r.type)])])])
                }
            }
            let body = draft.json()
            if let id = policyID {
                let p = try await api.updatePolicyRaw(id, body)
                if let i = store.policies.firstIndex(where: { $0.id == id }) { store.policies[i] = p }
            } else {
                store.policies.append(try await api.createPolicyRaw(body))
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
