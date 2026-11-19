import SwiftUI

/// Anlegen und Bearbeiten eines Reverse-Proxy-Services inkl. Ziele, Authentifizierung,
/// Zugriff pro Ziel und Zugriffsbeschränkungen.
struct ProxyServiceEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let serviceID: String?

    @State private var draft = ServiceDraft()
    @State private var loading = false
    @State private var saving = false
    @State private var subdomain = ""
    @State private var domainID = ""
    @State private var errorText: String?
    @State private var confirmDelete = false

    var isNew: Bool { serviceID == nil }
    var isHTTP: Bool { draft.mode == "http" }

    var body: some View {
        Form {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                addressSection
                targetsSection
                if isHTTP { authSection }
                restrictionsSection
                saveSection
            }
        }
        .glassScreen()
        .navigationTitle(isNew ? "Neuer Service" : draft.domain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            if !isNew, let id = serviceID {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ShareServiceView(serviceID: id) } label: { Image(systemName: "person.badge.plus") }
                }
            }
        }
        .task { await load() }
        .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Service löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task {
                    guard let id = serviceID else { return }
                    if await store.perform({ try await $0.deleteProxyService(id) }) {
                        store.services.removeAll { $0.id == id }
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: Abschnitte

    private var addressSection: some View {
        Section {
            if isNew {
                TextField("Subdomain (z. B. app)", text: $subdomain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Domain", selection: $domainID) {
                    Text("wählen …").tag("")
                    ForEach(store.domains.filter(\.validated)) { Text($0.domain).tag($0.id) }
                }
                Text(composedDomain.isEmpty ? "–" : composedDomain).font(.callout.monospaced()).foregroundStyle(.secondary)
                Picker("Modus", selection: $draft.mode) {
                    Text("HTTP").tag("http")
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("TLS").tag("tls")
                }
                .pickerStyle(.segmented)
            } else {
                TextField("Domain", text: $draft.domain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Modus", value: draft.mode.uppercased())
            }
            if !isHTTP {
                Stepper("Listen-Port: \(draft.listenPort == 0 ? "automatisch" : "\(draft.listenPort)")",
                        value: $draft.listenPort, in: 0...65535)
            }
            Toggle("Aktiv", isOn: $draft.enabled)
            if isHTTP {
                Toggle("Host-Header durchreichen", isOn: $draft.passHost)
                Toggle("Redirects umschreiben", isOn: $draft.rewriteRedirects)
            }
        } header: { Text("Service") }
    }

    private var targetsSection: some View {
        Section {
            ForEach($draft.targets) { $t in
                NavigationLink { TargetEditorView(target: $t, mode: draft.mode) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if isHTTP { Text(t.path.isEmpty ? "/" : t.path).font(.subheadline.monospaced().weight(.semibold)) }
                            Text("→ \(t.summary(store))").font(.subheadline.monospaced()).lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Pill(text: t.kind.rawValue, color: .nbBlue)
                            if isHTTP { Pill(text: accessLabel(t.accessAction), color: accessColor(t.accessAction)) }
                            if !t.enabled { Pill(text: "aus", color: .gray) }
                            if t.directUpstream || t.kind == .direct { Pill(text: "direkt", color: .nbTeal) }
                        }
                    }
                }
            }
            .onDelete { draft.targets.remove(atOffsets: $0) }
            .onMove { draft.targets.move(fromOffsets: $0, toOffset: $1) }
            if isHTTP || draft.targets.isEmpty {
                Button {
                    var t = TargetDraft()
                    t.proto = isHTTP ? "http" : (draft.mode == "udp" ? "udp" : "tcp")
                    t.path = draft.targets.isEmpty ? "/" : "/neu"
                    draft.targets.append(t)
                } label: { Label("Ziel hinzufügen", systemImage: "plus") }
            }
        } header: { Text("Ziele") } footer: {
            Text(isHTTP ? "Pro Pfad ein Ziel. Je Ziel lässt sich festlegen, ob die Service-Authentifizierung gilt, umgangen wird oder der Pfad gesperrt ist." : "L4-Services haben genau ein Ziel.")
        }
    }

    private var authSection: some View {
        Group {
            Section {
                Toggle("Nur über NetBird erreichbar (privat)", isOn: $draft.isPrivate.animation())
                if draft.isPrivate {
                    GroupPicker(selection: $draft.accessGroups, excludeAll: false)
                }
            } header: { Text("Privater Service") } footer: {
                Text("Privat: kein öffentlicher Login – Peers der gewählten Gruppen greifen über ihren WireGuard-Tunnel zu. Benötigt einen privaten Proxy-Cluster; schließt SSO aus.")
            }
            if !draft.isPrivate {
                Section {
                    Toggle(isOn: $draft.ssoEnabled.animation()) { Label("SSO (NetBird-Login)", systemImage: "person.badge.key") }
                    if draft.ssoEnabled {
                        GroupPicker(selection: $draft.ssoGroups, excludeAll: false)
                    }
                    Toggle(isOn: $draft.passwordEnabled.animation()) { Label("Passwort", systemImage: "key") }
                    if draft.passwordEnabled {
                        SecureField(draft.hadPassword ? "unverändert lassen" : "Passwort", text: $draft.password)
                    }
                    Toggle(isOn: $draft.pinEnabled.animation()) { Label("PIN", systemImage: "number") }
                    if draft.pinEnabled {
                        SecureField(draft.hadPin ? "unverändert lassen" : "PIN", text: $draft.pin).keyboardType(.numberPad)
                    }
                    Toggle(isOn: $draft.linkEnabled) { Label("Magic-Link per E-Mail", systemImage: "link") }
                } header: { Text("Authentifizierung") } footer: {
                    Text("SSO: Nur Benutzer in den gewählten Gruppen erhalten Zugriff. Mehrere Verfahren können kombiniert werden; ohne Verfahren ist der Service öffentlich.")
                }
                Section {
                    ForEach($draft.headerAuths) { $h in
                        VStack(alignment: .leading) {
                            Toggle("Aktiv", isOn: $h.enabled)
                            TextField("Header (z. B. X-API-Key)", text: $h.header)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(h.hadValue ? "Wert unverändert lassen" : "Erwarteter Wert", text: $h.value)
                        }
                    }
                    .onDelete { draft.headerAuths.remove(atOffsets: $0) }
                    Button { draft.headerAuths.append(HeaderAuthDraft()) } label: { Label("Header-Auth hinzufügen", systemImage: "plus") }
                } header: { Text("Header-Authentifizierung") } footer: {
                    Text("Für API-Clients: Zugriff, wenn der Header den Wert enthält, z. B. „Authorization: Bearer …“.")
                }
            }
        }
    }

    private var restrictionsSection: some View {
        Section {
            TextField("Erlaubte Netze (CIDR, kommagetrennt)", text: $draft.allowedCIDRs)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
            TextField("Gesperrte Netze (CIDR)", text: $draft.blockedCIDRs)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
            TextField("Erlaubte Länder (z. B. DE, AT, CH)", text: $draft.allowedCountries)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            TextField("Gesperrte Länder", text: $draft.blockedCountries)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Picker("CrowdSec", selection: $draft.crowdsec) {
                Text("Aus").tag("off")
                Text("Beobachten").tag("observe")
                Text("Blockieren").tag("enforce")
            }
        } header: { Text("Zugriffsbeschränkungen") } footer: {
            Text("Gilt vor der Authentifizierung, auch für TCP/UDP. IPv4- und IPv6-Netze möglich. CrowdSec nur, wenn der Proxy-Cluster es unterstützt.")
        }
    }

    private var saveSection: some View {
        Section {
            if let v = draft.validationError {
                Label(v, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().frame(maxWidth: .infinity) } else { Text(isNew ? "Service anlegen" : "Speichern") }
            }
            .buttonStyle(GlassButtonStyle())
            .listRowBackground(Color.clear)
            .disabled(saving || draft.validationError != nil)
            if !isNew {
                Button("Service löschen", role: .destructive) { confirmDelete = true }
            }
        }
    }

    // MARK: Logik

    private var composedDomain: String {
        guard let d = store.domains.first(where: { $0.id == domainID })?.domain else { return "" }
        return subdomain.isEmpty ? d : "\(subdomain).\(d)"
    }

    private func load() async {
        if store.resources.isEmpty { await store.loadResources() }
        guard let id = serviceID else {
            if domainID.isEmpty { domainID = store.domains.first(where: \.validated)?.id ?? "" }
            if draft.targets.isEmpty { draft.targets = [TargetDraft()] }
            return
        }
        guard draft.isNew else { return }
        loading = true
        defer { loading = false }
        do {
            draft = ServiceDraft(raw: try await store.api().rawProxyService(id))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() async {
        if isNew { draft.domain = composedDomain }
        if let v = draft.validationError { errorText = v; return }
        saving = true
        defer { saving = false }
        do {
            let api = try store.api()
            let body = draft.json()
            if let id = serviceID {
                let s = try await api.updateProxyServiceRaw(id, body)
                if let i = store.services.firstIndex(where: { $0.id == id }) { store.services[i] = s }
                draft = ServiceDraft(raw: try await api.rawProxyService(id))
            } else {
                let s = try await api.createProxyServiceRaw(body)
                store.services.append(s)
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

func accessLabel(_ a: String) -> String {
    switch a {
    case "bypass": return "ohne Auth"
    case "block": return "gesperrt"
    default: return "Service-Auth"
    }
}

func accessColor(_ a: String) -> Color {
    switch a {
    case "bypass": return .orange
    case "block": return .red
    default: return .nbOnline
    }
}

/// Ein einzelnes Ziel bearbeiten.
struct TargetEditorView: View {
    @Environment(AppStore.self) private var store
    @Binding var target: TargetDraft
    let mode: String

    var isHTTP: Bool { mode == "http" }
    var resource: NetworkResource? { store.resources.first { $0.id == target.targetId } }

    var body: some View {
        Form {
            Section {
                Picker("Art", selection: $target.kind) {
                    ForEach(TargetDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch target.kind {
                case .peer:
                    Picker("Peer", selection: $target.targetId) {
                        Text("wählen …").tag("")
                        ForEach(store.peers) { p in Text("\(p.connected ? "●" : "○") \(p.name)").tag(p.id) }
                    }
                    Toggle("Direkt verbinden (eigene Adresse)", isOn: $target.directUpstream)
                    if target.directUpstream {
                        TextField("IP/Host (leer = Peer-IP)", text: $target.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                case .resource:
                    Picker("Ressource", selection: $target.targetId) {
                        Text("wählen …").tag("")
                        ForEach(store.resources) { r in Text("\(r.name) (\(r.address))").tag(r.id) }
                    }
                    if resource?.type == "subnet" {
                        TextField("IP im Subnetz \(resource?.address ?? "")", text: $target.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if store.resources.isEmpty {
                        Text("Keine Netzwerk-Ressourcen gefunden.").font(.caption).foregroundStyle(.secondary)
                    }
                case .direct:
                    TextField("Upstream-Adresse (IP/Host)", text: $target.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } header: { Text("Ziel") } footer: {
                if target.kind == .direct || target.directUpstream {
                    Text("Direkte Ziele werden vom Proxy ohne NetBird-Tunnel angesprochen und funktionieren nur mit einem privaten Proxy-Cluster.")
                }
            }
            Section {
                Picker("Protokoll", selection: $target.proto) {
                    if isHTTP {
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
                    TextField("80", value: $target.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                }
                if isHTTP {
                    TextField("Pfad", text: $target.path).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Ziel aktiv", isOn: $target.enabled)
                }
            } header: { Text("Verbindung") }
            if isHTTP {
                Section {
                    Picker("Zugriff", selection: $target.accessAction) {
                        Text("Service-Authentifizierung").tag("inherit")
                        Text("Ohne Authentifizierung").tag("bypass")
                        Text("Gesperrt").tag("block")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("Authentifizierung für diesen Pfad") } footer: {
                    Text("Z. B. /api ohne Login freigeben oder /admin sperren, während der Rest per SSO geschützt bleibt.")
                }
            }
            Section {
                if target.proto == "https" { Toggle("TLS-Zertifikat nicht prüfen", isOn: $target.skipTLS) }
                TextField("Timeout (z. B. 30s, 2m)", text: $target.requestTimeout)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if isHTTP {
                    Toggle("Pfad unverändert weitergeben", isOn: $target.preservePath)
                } else if mode != "udp" {
                    Toggle("PROXY-Protokoll v2", isOn: $target.proxyProtocol)
                }
                if mode == "udp" {
                    TextField("UDP-Session-Timeout (z. B. 2m)", text: $target.sessionIdleTimeout)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } header: { Text("Optionen") }
            if isHTTP {
                Section {
                    ForEach($target.headers) { $h in
                        HStack {
                            TextField("Header", text: $h.key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Wert", text: $h.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        .font(.callout.monospaced())
                    }
                    .onDelete { target.headers.remove(atOffsets: $0) }
                    Button { target.headers.append(HeaderPair()) } label: { Label("Header hinzufügen", systemImage: "plus") }
                } header: { Text("Zusätzliche Header an das Backend") }
            }
        }
        .glassScreen()
        .navigationTitle(isHTTP ? (target.path.isEmpty ? "/" : target.path) : "Ziel")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: target.kind) { _, k in
            target.targetId = ""
            if k == .resource { target.resourceType = "host" }
        }
        .onChange(of: target.targetId) { _, id in
            if target.kind == .resource, let r = store.resources.first(where: { $0.id == id }) { target.resourceType = r.type }
        }
    }
}

/// Service mit Benutzern teilen: Gruppe anlegen/wählen, Benutzern zuweisen,
/// Gruppe für SSO (bzw. privaten Zugriff) am Service freischalten.
struct ShareServiceView: View {
    @Environment(AppStore.self) private var store
    let serviceID: String

    @State private var groupID = ""
    @State private var newGroupName = ""
    @State private var selectedUsers: Set<String> = []
    @State private var busy = false
    @State private var result: String?
    @State private var errorText: String?
    @State private var showCreateUser = false

    var service: ProxyService? { store.services.first { $0.id == serviceID } }
    var serviceGroups: [String] { (service?.private == true ? service?.accessGroups : service?.bearerGroups) ?? [] }

    var body: some View {
        Form {
            if let s = service {
                Section {
                    LabeledContent("Service", value: s.domain)
                    LabeledContent("Zugriff", value: s.private == true ? "privat (NetBird)" : (s.authLabels.isEmpty ? "öffentlich" : s.authLabels.joined(separator: ", ")))
                }
                Section {
                    if serviceGroups.isEmpty { Text("Noch nicht geteilt").foregroundStyle(.secondary) }
                    ForEach(serviceGroups, id: \.self) { g in
                        DisclosureGroup {
                            let members = store.users.filter { $0.autoGroups.contains(g) }
                            if members.isEmpty { Text("Keine Benutzer").foregroundStyle(.secondary) }
                            ForEach(members) { u in
                                HStack {
                                    Text(u.displayName)
                                    Spacer()
                                    Button("Entziehen", role: .destructive) { Task { await revoke(u, group: g) } }
                                        .buttonStyle(.borderless).font(.caption)
                                }
                            }
                        } label: { Label(store.groupName(g), systemImage: "person.3") }
                    }
                } header: { Text("Aktuell freigegeben für") }

                Section {
                    Picker("Gruppe", selection: $groupID) {
                        Text("Neue Gruppe …").tag("")
                        ForEach(store.groups.filter { $0.name != "All" }) { Text($0.name).tag($0.id) }
                    }
                    if groupID.isEmpty {
                        TextField("Name der neuen Gruppe", text: $newGroupName)
                    }
                } header: { Text("1 · Gruppe") }

                Section {
                    ForEach(store.users.filter { $0.isServiceUser != true }) { u in
                        Button {
                            if selectedUsers.contains(u.id) { selectedUsers.remove(u.id) } else { selectedUsers.insert(u.id) }
                        } label: {
                            HStack {
                                UserRow(user: u)
                                Spacer()
                                Image(systemName: selectedUsers.contains(u.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedUsers.contains(u.id) ? Color.nbOrange : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showCreateUser = true } label: { Label("Neuen Benutzer einladen", systemImage: "person.badge.plus") }
                } header: { Text("2 · Benutzer") }

                Section {
                    Button {
                        Task { await share() }
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) } else { Text("Freigeben") }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .listRowBackground(Color.clear)
                    .disabled(busy || selectedUsers.isEmpty || (groupID.isEmpty && newGroupName.trimmingCharacters(in: .whitespaces).isEmpty))
                    if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(Color.nbOnline).font(.footnote) }
                } footer: {
                    Text(s.private == true
                         ? "Die Gruppe wird als Zugriffs-Gruppe des privaten Services eingetragen."
                         : "SSO wird für den Service aktiviert und die Gruppe freigeschaltet. Benutzer melden sich mit ihrem NetBird-Login an.")
                }
            } else {
                Text("Service nicht gefunden")
            }
        }
        .glassScreen()
        .navigationTitle("Teilen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if newGroupName.isEmpty, let s = service {
                newGroupName = "share-" + (s.domain.split(separator: ".").first.map(String.init) ?? "service")
            }
        }
        .sheet(isPresented: $showCreateUser) {
            NavigationStack {
                CreateUserView { u in selectedUsers.insert(u.id) }
            }
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func share() async {
        busy = true
        defer { busy = false }
        result = nil
        do {
            let api = try store.api()
            // 1. Gruppe
            var gid = groupID
            if gid.isEmpty {
                let g = try await api.createGroup(.init(name: newGroupName.trimmingCharacters(in: .whitespaces), peers: []))
                store.groups.append(g)
                gid = g.id
                groupID = g.id
            }
            // 2. Benutzern zuweisen
            for uid in selectedUsers {
                guard let u = store.users.first(where: { $0.id == uid }), !u.autoGroups.contains(gid) else { continue }
                let updated = try await api.updateUser(u.id, .init(role: u.role, autoGroups: u.autoGroups + [gid], isBlocked: u.isBlocked))
                if let i = store.users.firstIndex(where: { $0.id == u.id }) { store.users[i] = updated }
            }
            // 3. Service freischalten
            var draft = ServiceDraft(raw: try await api.rawProxyService(serviceID))
            if draft.isPrivate {
                if !draft.accessGroups.contains(gid) { draft.accessGroups.append(gid) }
            } else {
                draft.ssoEnabled = true
                if !draft.ssoGroups.contains(gid) { draft.ssoGroups.append(gid) }
            }
            let s = try await api.updateProxyServiceRaw(serviceID, draft.json())
            if let i = store.services.firstIndex(where: { $0.id == serviceID }) { store.services[i] = s }
            result = "Freigegeben für \(selectedUsers.count) Benutzer über „\(store.groupName(gid))“"
            selectedUsers.removeAll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ u: NBUser, group: String) async {
        _ = await store.perform { api in
            let updated = try await api.updateUser(u.id, .init(role: u.role, autoGroups: u.autoGroups.filter { $0 != group }, isBlocked: u.isBlocked))
            if let i = store.users.firstIndex(where: { $0.id == u.id }) { store.users[i] = updated }
        }
    }
}
