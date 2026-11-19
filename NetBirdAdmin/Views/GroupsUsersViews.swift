import SwiftUI

// MARK: - Gruppen

struct GroupsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Section {
            ForEach(store.groups) { g in
                NavigationLink { GroupDetailView(groupID: g.id) } label: {
                    HStack {
                        Image(systemName: "person.3.fill").foregroundStyle(Color.nbBlue)
                        Text(g.name)
                        Spacer()
                        if let issued = g.issued, issued != "api" { Pill(text: issued, color: .gray) }
                        Text("\(g.peersCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .swipeActions {
                    if g.name != "All" {
                        Button(role: .destructive) {
                            Task {
                                if await store.perform({ try await $0.deleteGroup(g.id) }) {
                                    store.groups.removeAll { $0.id == g.id }
                                }
                            }
                        } label: { Label("Löschen", systemImage: "trash") }
                    }
                }
            }
        } footer: { Text("Gruppen steuern Routen, Exit-Nodes, Zugriffsrichtlinien und das Teilen von Proxy-Services.") }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }
}

struct GroupDetailView: View {
    @Environment(AppStore.self) private var store
    let groupID: String
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var search = ""

    var group: NBGroup? { store.groups.first { $0.id == groupID } }
    var isAll: Bool { group?.name == "All" }
    var usersWithGroup: [NBUser] { store.users.filter { $0.autoGroups.contains(groupID) } }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name).disabled(isAll)
            }
            Section {
                ForEach(store.peers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in
                    Button {
                        if members.contains(p.id) { members.remove(p.id) } else { members.insert(p.id) }
                    } label: {
                        HStack {
                            StatusDot(online: p.connected)
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: members.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(members.contains(p.id) ? Color.nbOrange : .secondary)
                        }
                    }
                    .disabled(isAll)
                }
            } header: { Text("Peers (\(members.count))") }
            if !usersWithGroup.isEmpty {
                Section("Benutzer mit dieser Gruppe") {
                    ForEach(usersWithGroup) { u in Label(u.displayName, systemImage: "person") }
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Speichern") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(saving || isAll || name.isEmpty)
            }
        }
        .glassScreen()
        .searchable(text: $search, prompt: "Peer suchen")
        .navigationTitle(group?.name ?? "Gruppe")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded, let g = group else { return }
            name = g.name
            members = Set(store.peers.filter { p in p.groups.contains { $0.id == g.id } }.map(\.id))
            loaded = true
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let ids = Array(members), n = name
        if await store.perform({ api in _ = try await api.updateGroup(groupID, name: n, peers: ids) }) {
            await store.reloadPeersAndGroups()
        }
    }
}

struct CreateGroupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []

    var body: some View {
        Form {
            Section { TextField("Gruppenname", text: $name) }
            Section("Peers") {
                ForEach(store.peers) { p in
                    Button {
                        if members.contains(p.id) { members.remove(p.id) } else { members.insert(p.id) }
                    } label: {
                        HStack {
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            if members.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(Color.nbOrange) }
                        }
                    }
                }
            }
        }
        .glassScreen()
        .navigationTitle("Neue Gruppe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Anlegen") {
                    Task {
                        let n = name.trimmingCharacters(in: .whitespaces), ids = Array(members)
                        if await store.perform({ api in _ = try await api.createGroup(.init(name: n, peers: ids)) }) {
                            await store.reloadPeersAndGroups()
                            dismiss()
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Mehrfachauswahl von Gruppen (wiederverwendbar).
struct GroupPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: [String]
    var excludeAll = true
    var allowCreate = true
    @State private var newName = ""

    var body: some View {
        ForEach(store.groups.filter { !excludeAll || $0.name != "All" }) { g in
            Button {
                if let i = selection.firstIndex(of: g.id) { selection.remove(at: i) } else { selection.append(g.id) }
            } label: {
                HStack {
                    Text(g.name).foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(g.id) { Image(systemName: "checkmark").foregroundStyle(Color.nbOrange) }
                }
            }
        }
        if allowCreate {
            HStack {
                TextField("Neue Gruppe …", text: $newName)
                Button("Anlegen") {
                    Task {
                        let n = newName.trimmingCharacters(in: .whitespaces)
                        _ = await store.perform { api in
                            let g = try await api.createGroup(.init(name: n, peers: []))
                            store.groups.append(g)
                            selection.append(g.id)
                        }
                        newName = ""
                    }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Benutzer

struct UsersSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Section {
            if store.users.isEmpty { Text("Keine Benutzer geladen").foregroundStyle(.secondary) }
            ForEach(store.users) { u in
                NavigationLink { UserEditView(user: u) } label: { UserRow(user: u) }
                    .swipeActions {
                        if u.isCurrent != true && u.role != "owner" {
                            Button(role: .destructive) {
                                Task {
                                    if await store.perform({ try await $0.deleteUser(u.id) }) {
                                        store.users.removeAll { $0.id == u.id }
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

struct UserRow: View {
    @Environment(AppStore.self) private var store
    let user: NBUser
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: user.isServiceUser == true ? "gearshape.2.fill" : "person.crop.circle.fill")
                .font(.title2).foregroundStyle(user.isBlocked ? Color.red : Color.nbBlue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.displayName).font(.subheadline.weight(.semibold))
                    if user.isCurrent == true { Pill(text: "Du", color: .nbTeal) }
                }
                if let e = user.email, !e.isEmpty, e != user.displayName {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Pill(text: UserRole.label(user.role), color: .nbOrange)
                    if user.isBlocked { Pill(text: "gesperrt", color: .red) }
                    else if user.status == "invited" { Pill(text: "eingeladen", color: .gray) }
                }
            }
        }
    }
}

struct UserEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let user: NBUser
    @State private var role = "user"
    @State private var groups: [String] = []
    @State private var blocked = false
    @State private var saving = false

    var sharedServices: [ProxyService] {
        store.services.filter { s in !Set(s.bearerGroups).isDisjoint(with: groups) || !Set(s.accessGroups ?? []).isDisjoint(with: groups) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: user.displayName)
                if let e = user.email { LabeledContent("E-Mail", value: e) }
                if let l = user.lastLogin { LabeledContent("Letzter Login", value: l.relative) }
                LabeledContent("Status", value: user.status ?? "–")
            }
            Section {
                Picker("Rolle", selection: $role) {
                    ForEach(UserRole.assignable) { Text($0.label).tag($0.rawValue) }
                    if role == "owner" { Text(UserRole.owner.label).tag("owner") }
                }
                .disabled(role == "owner" || user.isCurrent == true)
                Toggle("Gesperrt", isOn: $blocked).disabled(user.isCurrent == true)
            } header: { Text("Berechtigungen") } footer: {
                Text("Benutzer: eigene Peers · Auditor: alles lesen · Netzwerk-Admin: Netzwerke/Routen/Richtlinien · Administrator: alles außer Eigentümer-Rechten.")
            }
            Section {
                GroupPicker(selection: $groups)
            } header: { Text("Gruppen") } footer: {
                Text("Gruppen des Benutzers – bestimmen u. a., welche per SSO geschützten Proxy-Services er öffnen darf. Peers, die der Benutzer registriert, erhalten diese Gruppen automatisch.")
            }
            if !sharedServices.isEmpty {
                Section("Zugriff auf Services") {
                    ForEach(sharedServices) { s in Label(s.domain, systemImage: "globe") }
                }
            }
            if user.status == "invited" {
                Section {
                    Button("Einladung erneut senden") {
                        Task { _ = await store.perform { try await $0.resendInvite(user.id) } }
                    }
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Speichern") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(saving)
            }
        }
        .glassScreen()
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { role = user.role; groups = user.autoGroups; blocked = user.isBlocked }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = UserUpdateRequest(role: role, autoGroups: groups, isBlocked: blocked)
        if await store.perform({ api in
            let u = try await api.updateUser(user.id, body)
            if let i = store.users.firstIndex(where: { $0.id == u.id }) { store.users[i] = u }
        }) { dismiss() }
    }
}

struct CreateUserView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var presetGroups: [String] = []
    var onCreated: ((NBUser) -> Void)? = nil

    @State private var email = ""
    @State private var name = ""
    @State private var role = "user"
    @State private var serviceUser = false
    @State private var groups: [String] = []
    @State private var created: NBUser?
    @State private var saving = false

    var body: some View {
        Form {
            if let created {
                Section {
                    Label("\(created.displayName) angelegt", systemImage: "checkmark.seal.fill").foregroundStyle(Color.nbOnline)
                    if let pw = created.password, !pw.isEmpty {
                        LabeledContent("Start-Passwort") { Text(pw).font(.callout.monospaced()).textSelection(.enabled) }
                        Button { UIPasteboard.general.string = pw } label: { Label("Passwort kopieren", systemImage: "doc.on.doc") }
                        Text("Wird nur jetzt angezeigt.").font(.caption).foregroundStyle(.secondary)
                    } else if !serviceUser {
                        Text("Eine Einladung wurde an \(created.email ?? email) verschickt (falls der Identity-Provider das unterstützt).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Toggle("Service-User (API-Zugang, kein Login)", isOn: $serviceUser)
                    if !serviceUser {
                        TextField("E-Mail", text: $email).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField("Name", text: $name)
                    Picker("Rolle", selection: $role) {
                        ForEach(UserRole.assignable) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section("Gruppen") { GroupPicker(selection: $groups) }
                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if saving { ProgressView().frame(maxWidth: .infinity) } else { Text(serviceUser ? "Service-User anlegen" : "Benutzer einladen") }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .listRowBackground(Color.clear)
                    .disabled(saving || name.isEmpty || (!serviceUser && !email.contains("@")))
                }
            }
        }
        .glassScreen()
        .navigationTitle("Neuer Benutzer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(created == nil ? "Abbrechen" : "Fertig") { dismiss() } } }
        .onAppear { if groups.isEmpty { groups = presetGroups } }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        let req = UserCreateRequest(email: serviceUser ? nil : email, name: name, role: role,
                                    autoGroups: groups, isServiceUser: serviceUser)
        _ = await store.perform { api in
            let u = try await api.createUser(req)
            store.users.append(u)
            created = u
            onCreated?(u)
        }
    }
}
