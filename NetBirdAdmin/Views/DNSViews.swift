import SwiftUI

struct DNSView: View {
    @Environment(AppStore.self) private var store
    @State private var editingNS: NameserverGroup?
    @State private var addNS = false
    @State private var addZone = false

    var body: some View {
        List {
            Section {
                if store.nameserverGroups.isEmpty { Text("Keine Nameserver-Gruppen").foregroundStyle(.secondary) }
                ForEach(store.nameserverGroups) { g in
                    Button { editingNS = g } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: g.enabled ? "server.rack" : "pause.circle").foregroundStyle(g.enabled ? Color.nbBlue : .secondary)
                                Text(g.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                Pill(text: g.primary ? "Standard" : "Split-DNS", color: g.primary ? .nbOrange : .nbTeal)
                            }
                            Text(g.nameservers.map { "\($0.ip):\($0.port)" }.joined(separator: ", "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if !g.primary && !g.domains.isEmpty {
                                Text(g.domains.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteNameserverGroup(g.id) }) {
                                    store.nameserverGroups.removeAll { $0.id == g.id }
                                }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
                Button { addNS = true } label: { Label("Nameserver-Gruppe hinzufügen", systemImage: "plus") }
            } header: { Text("Nameserver") } footer: {
                Text("Standard: alle Anfragen gehen an diese Server. Split-DNS: nur die angegebenen Domains.")
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            Section {
                if store.dnsZones.isEmpty { Text("Keine eigenen Zonen").foregroundStyle(.secondary) }
                ForEach(store.dnsZones) { z in
                    NavigationLink { DNSZoneView(zoneID: z.id) } label: {
                        HStack {
                            Image(systemName: "globe").foregroundStyle(z.enabled ? Color.nbTeal : .secondary)
                            VStack(alignment: .leading) {
                                Text(z.domain).font(.subheadline.monospaced().weight(.semibold))
                                Text("\(z.name) · \(z.records.count) Einträge").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteDNSZone(z.id) }) {
                                    store.dnsZones.removeAll { $0.id == z.id }
                                }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
                Button { addZone = true } label: { Label("Zone hinzufügen", systemImage: "plus") }
            } header: { Text("Eigene DNS-Zonen") } footer: {
                Text("Eigene A-, AAAA- und CNAME-Einträge, die NetBird an die gewählten Gruppen verteilt.")
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .glassScreen()
        .navigationTitle("DNS")
        .refreshable { await store.loadDNS() }
        .task { await store.loadDNS() }
        .sheet(item: $editingNS) { g in NavigationStack { NameserverGroupEditor(group: g) } }
        .sheet(isPresented: $addNS) { NavigationStack { NameserverGroupEditor(group: nil) } }
        .sheet(isPresented: $addZone) { NavigationStack { DNSZoneEditor(zone: nil) } }
    }
}

struct NameserverGroupEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let group: NameserverGroup?

    @State private var name = ""
    @State private var description = ""
    @State private var servers: [EditableNS] = [EditableNS()]
    @State private var enabled = true
    @State private var primary = true
    @State private var domains = ""
    @State private var searchDomains = false
    @State private var groups: [String] = []
    @State private var errorText: String?

    struct EditableNS: Identifiable, Hashable {
        var id = UUID()
        var ip = ""
        var port = 53
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Beschreibung", text: $description)
                Toggle("Aktiv", isOn: $enabled)
            }
            Section {
                ForEach($servers) { $s in
                    HStack {
                        TextField("IP (IPv4 oder IPv6)", text: $s.ip)
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).font(.body.monospaced())
                        TextField("53", value: $s.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad).frame(width: 60).multilineTextAlignment(.trailing)
                    }
                }
                .onDelete { servers.remove(atOffsets: $0) }
                if servers.count < 3 {
                    Button { servers.append(EditableNS()) } label: { Label("Server hinzufügen", systemImage: "plus") }
                }
            } header: { Text("Nameserver (max. 3)") }
            Section {
                Toggle("Für alle Domains (Standard)", isOn: $primary)
                if !primary {
                    TextField("intern.example.com, corp.local", text: $domains)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Als Suchdomains eintragen", isOn: $searchDomains)
                }
            } header: { Text("Domains") }
            Section("Verteilen an") { GroupPicker(selection: $groups, excludeAll: false) }
        }
        .glassScreen()
        .navigationTitle(group == nil ? "Nameserver-Gruppe" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Sichern") { Task { await save() } }.disabled(!valid) }
        }
        .onAppear {
            guard let g = group else {
                if let all = store.groups.first(where: { $0.name == "All" }) { groups = [all.id] }
                return
            }
            name = g.name; description = g.description ?? ""; enabled = g.enabled; primary = g.primary
            domains = g.domains.joined(separator: ", "); searchDomains = g.searchDomainsEnabled; groups = g.groups
            servers = g.nameservers.map { EditableNS(ip: $0.ip, port: $0.port) }
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var valid: Bool {
        !name.isEmpty && !groups.isEmpty && servers.contains { !$0.ip.isEmpty } && (primary || !ServiceDraft.list(domains).isEmpty)
    }

    private func save() async {
        let req = NameserverGroupRequest(
            name: name, description: description,
            nameservers: servers.filter { !$0.ip.isEmpty }.map { Nameserver(ip: $0.ip.trimmingCharacters(in: .whitespaces), nsType: "udp", port: $0.port) },
            enabled: enabled, groups: groups, primary: primary,
            domains: primary ? [] : ServiceDraft.list(domains), searchDomainsEnabled: primary ? false : searchDomains)
        do {
            let api = try store.api()
            if let g = group {
                let u = try await api.updateNameserverGroup(g.id, req)
                if let i = store.nameserverGroups.firstIndex(where: { $0.id == g.id }) { store.nameserverGroups[i] = u }
            } else {
                store.nameserverGroups.append(try await api.createNameserverGroup(req))
            }
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

struct DNSZoneEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let zone: DNSZone?

    @State private var name = ""
    @State private var domain = ""
    @State private var enabled = true
    @State private var search = false
    @State private var groups: [String] = []
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Domain (z. B. home.lan)", text: $domain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Aktiv", isOn: $enabled)
                Toggle("Als Suchdomain eintragen", isOn: $search)
            }
            Section("Verteilen an") { GroupPicker(selection: $groups, excludeAll: false) }
        }
        .glassScreen()
        .navigationTitle(zone == nil ? "Neue Zone" : domain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { Task { await save() } }.disabled(name.isEmpty || domain.isEmpty || groups.isEmpty)
            }
        }
        .onAppear {
            guard let z = zone else {
                if let all = store.groups.first(where: { $0.name == "All" }) { groups = [all.id] }
                return
            }
            name = z.name; domain = z.domain; enabled = z.enabled; search = z.enableSearchDomain; groups = z.distributionGroups
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func save() async {
        let req = DNSZoneRequest(name: name, domain: domain.trimmingCharacters(in: .whitespaces).lowercased(),
                                 enabled: enabled, enableSearchDomain: search, distributionGroups: groups)
        do {
            let api = try store.api()
            if let z = zone {
                let u = try await api.updateDNSZone(z.id, req)
                if let i = store.dnsZones.firstIndex(where: { $0.id == z.id }) { store.dnsZones[i] = u }
            } else {
                store.dnsZones.append(try await api.createDNSZone(req))
            }
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

struct DNSZoneView: View {
    @Environment(AppStore.self) private var store
    let zoneID: String
    @State private var editZone = false
    @State private var editingRecord: DNSRecord?
    @State private var addRecord = false

    var zone: DNSZone? { store.dnsZones.first { $0.id == zoneID } }

    var body: some View {
        List {
            if let z = zone {
                Section {
                    LabeledContent("Domain", value: z.domain)
                    LabeledContent("Verteilt an", value: z.distributionGroups.map { store.groupName($0) }.joined(separator: ", "))
                    Button("Zone bearbeiten") { editZone = true }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                Section("Einträge") {
                    ForEach(z.records) { r in
                        Button { editingRecord = r } label: {
                            HStack {
                                Pill(text: r.type, color: r.type == "AAAA" ? .nbTeal : (r.type == "CNAME" ? .nbOrange : .nbBlue))
                                VStack(alignment: .leading) {
                                    Text(r.name).font(.subheadline.monospaced()).foregroundStyle(.primary)
                                    Text("→ \(r.content) · TTL \(r.ttl)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    if await store.perform({ try await $0.deleteDNSRecord(zoneID, r.id) }) { await store.loadDNS() }
                                }
                            } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                    Button { addRecord = true } label: { Label("Eintrag hinzufügen", systemImage: "plus") }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
        }
        .glassScreen()
        .navigationTitle(zone?.domain ?? "Zone")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editZone) { NavigationStack { DNSZoneEditor(zone: zone) } }
        .sheet(item: $editingRecord) { r in NavigationStack { DNSRecordEditor(zoneID: zoneID, zoneDomain: zone?.domain ?? "", record: r) } }
        .sheet(isPresented: $addRecord) { NavigationStack { DNSRecordEditor(zoneID: zoneID, zoneDomain: zone?.domain ?? "", record: nil) } }
    }
}

struct DNSRecordEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let zoneID: String
    let zoneDomain: String
    let record: DNSRecord?

    @State private var name = ""
    @State private var type = "A"
    @State private var content = ""
    @State private var ttl = 300
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Picker("Typ", selection: $type) {
                    Text("A (IPv4)").tag("A")
                    Text("AAAA (IPv6)").tag("AAAA")
                    Text("CNAME").tag("CNAME")
                }
                .pickerStyle(.segmented)
                TextField("Name (z. B. nas.\(zoneDomain))", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(type == "CNAME" ? "Ziel-Hostname" : (type == "AAAA" ? "2001:db8::10" : "192.168.1.10"), text: $content)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                Stepper("TTL: \(ttl) s", value: $ttl, in: 0...86400, step: 60)
            }
            if let p = peerSuggestion {
                Section {
                    Button("NetBird-IP von \(p.name) übernehmen") { content = type == "AAAA" ? (p.ipv6 ?? "") : p.ip }
                }
            }
        }
        .glassScreen()
        .navigationTitle(record == nil ? "Neuer Eintrag" : "Eintrag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Sichern") { Task { await save() } }.disabled(name.isEmpty || content.isEmpty) }
        }
        .onAppear {
            guard let r = record else { return }
            name = r.name; type = r.type; content = r.content; ttl = r.ttl
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    /// Passender Peer zum eingegebenen Namen (z. B. "nas" → Peer "nas")
    private var peerSuggestion: Peer? {
        guard type != "CNAME" else { return nil }
        let short = name.split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        guard !short.isEmpty else { return nil }
        return store.peers.first { $0.name.lowercased() == short || $0.dnsLabel.lowercased().hasPrefix(short + ".") }
    }

    private func save() async {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if !n.hasSuffix(zoneDomain) { n = n.isEmpty ? zoneDomain : "\(n).\(zoneDomain)" }
        let req = DNSRecordRequest(name: n, type: type, content: content.trimmingCharacters(in: .whitespaces), ttl: ttl)
        do {
            let api = try store.api()
            if let r = record { _ = try await api.updateDNSRecord(zoneID, r.id, req) }
            else { _ = try await api.createDNSRecord(zoneID, req) }
            await store.loadDNS()
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}
