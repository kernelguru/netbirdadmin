import SwiftUI
import CoreImage.CIFilterBuiltins

struct SetupKeysSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Section {
            if store.setupKeys.isEmpty { Text("Keine Setup-Keys").foregroundStyle(.secondary) }
            ForEach(store.setupKeys) { k in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(k.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Pill(text: stateText(k), color: k.valid ? .nbOnline : .gray)
                    }
                    HStack(spacing: 8) {
                        Text(k.type == "reusable" ? "Wiederverwendbar" : "Einmalig")
                        Text("·")
                        Text("\(k.usedTimes)\(k.usageLimit > 0 ? "/\(k.usageLimit)" : "") genutzt")
                        if k.ephemeral { Text("· ephemer") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let e = k.expires { Text("Läuft ab \(e.relative)").font(.caption2).foregroundStyle(.tertiary) }
                    if !k.autoGroups.isEmpty {
                        Text(k.autoGroups.map { store.groupName($0) }.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task {
                            if await store.perform({ try await $0.deleteSetupKey(k.id) }) {
                                store.setupKeys.removeAll { $0.id == k.id }
                            }
                        }
                    } label: { Label("Löschen", systemImage: "trash") }
                    if !k.revoked {
                        Button {
                            Task {
                                _ = await store.perform { api in
                                    let u = try await api.updateSetupKey(k.id, .init(revoked: true, autoGroups: k.autoGroups))
                                    if let i = store.setupKeys.firstIndex(where: { $0.id == k.id }) { store.setupKeys[i] = u }
                                }
                            }
                        } label: { Label("Widerrufen", systemImage: "nosign") }
                        .tint(.orange)
                    }
                }
            }
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    private func stateText(_ k: SetupKey) -> String {
        switch k.state {
        case "valid": return "gültig"
        case "expired": return "abgelaufen"
        case "revoked": return "widerrufen"
        case "overused": return "aufgebraucht"
        default: return k.state
        }
    }
}

struct CreateSetupKeyView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var reusable = false
    @State private var expiresDays = 7
    @State private var usageLimit = 0
    @State private var ephemeral = false
    @State private var extraDNS = false
    @State private var selectedGroups: Set<String> = []
    @State private var creating = false
    @State private var created: SetupKey?

    var body: some View {
        Group {
            if let created {
                SetupKeyResultView(key: created)
            } else {
                form
            }
        }
        .navigationTitle(created == nil ? "Neuer Client" : "Setup-Key erstellt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(created == nil ? "Abbrechen" : "Fertig") { dismiss() } }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name (z. B. Laptop Marc)", text: $name)
                Toggle("Wiederverwendbar", isOn: $reusable)
                if reusable {
                    Stepper("Nutzungslimit: \(usageLimit == 0 ? "unbegrenzt" : "\(usageLimit)")", value: $usageLimit, in: 0...1000)
                }
                Stepper("Gültig: \(expiresDays) Tag\(expiresDays == 1 ? "" : "e")", value: $expiresDays, in: 1...365)
                Toggle("Ephemerer Peer", isOn: $ephemeral)
                Toggle("Zusätzliche DNS-Labels erlauben", isOn: $extraDNS)
            } header: { Text("Setup-Key") } footer: {
                Text("Ephemere Peers werden nach 10 Minuten Inaktivität automatisch entfernt.")
            }
            Section("Automatisch zugewiesene Gruppen") {
                if store.groups.isEmpty { Text("Keine Gruppen").foregroundStyle(.secondary) }
                ForEach(store.groups.filter { $0.name != "All" }) { g in
                    Button {
                        if selectedGroups.contains(g.id) { selectedGroups.remove(g.id) } else { selectedGroups.insert(g.id) }
                    } label: {
                        HStack {
                            Text(g.name).foregroundStyle(.primary)
                            Spacer()
                            if selectedGroups.contains(g.id) { Image(systemName: "checkmark").foregroundStyle(Color.nbOrange) }
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await create() }
                } label: {
                    if creating { ProgressView().frame(maxWidth: .infinity) } else { Text("Key erstellen") }
                }
                .buttonStyle(GlassButtonStyle())
                .listRowBackground(Color.clear)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
        }
        .glassScreen()
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let req = CreateSetupKeyRequest(name: name, type: reusable ? "reusable" : "one-off",
                                        expiresIn: expiresDays * 86400, autoGroups: Array(selectedGroups),
                                        usageLimit: reusable ? usageLimit : 1, ephemeral: ephemeral,
                                        allowExtraDnsLabels: extraDNS)
        _ = await store.perform { api in
            let k = try await api.createSetupKey(req)
            store.setupKeys.insert(k, at: 0)
            withAnimation { created = k }
        }
    }
}

struct SetupKeyResultView: View {
    @Environment(AppStore.self) private var store
    let key: SetupKey
    @State private var copied: String?

    var mgmtURL: String {
        var s = store.current?.managementURL ?? ""
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var linuxCmd: String {
        "curl -fsSL https://pkgs.netbird.io/install.sh | sh\nnetbird up --management-url \(mgmtURL) --setup-key \(key.key)"
    }
    var dockerCmd: String {
        "docker run -d --name netbird --cap-add=NET_ADMIN --cap-add=SYS_ADMIN --cap-add=SYS_RESOURCE --network host --restart unless-stopped -e NB_SETUP_KEY=\(key.key) -e NB_MANAGEMENT_URL=\(mgmtURL) -v netbird-client:/var/lib/netbird netbirdio/netbird:latest"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Color.nbOnline)
                    Text(key.name).font(.title3.bold())
                    Text("Der Key wird nur jetzt im Klartext angezeigt.").font(.caption).foregroundStyle(.secondary)
                    if let qr = QRCode.image(for: key.key) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                    copyBox("Setup-Key", key.key)
                }
                .glassCard()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Linux / macOS", systemImage: "terminal").font(.headline)
                    copyBox("Installieren & verbinden", linuxCmd)
                    Label("Docker", systemImage: "shippingbox").font(.headline)
                    copyBox("Container", dockerCmd)
                    Label("Mobile / Desktop-App", systemImage: "iphone").font(.headline)
                    Text("In der NetBird-App unter „Erweitert“ die Management-URL \(mgmtURL) setzen und den Setup-Key eintragen oder den QR-Code scannen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .glassCard()
            }
            .padding()
        }
        .glassScreen()
    }

    private func copyBox(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    copied = title
                } label: {
                    Label(copied == title ? "Kopiert" : "Kopieren", systemImage: copied == title ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
            }
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
