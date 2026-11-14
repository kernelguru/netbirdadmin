import SwiftUI
import UniformTypeIdentifiers

/// Schlüssel erzeugen/importieren, Public Key zum Signieren exportieren,
/// signiertes OpenSSH-Zertifikat (mit Principals) importieren.
struct SSHKeyView: View {
    @State private var pubKey = SSHKeyManager.publicKeyOpenSSH
    @State private var certInfo = SSHKeyManager.certInfo
    @State private var certText = ""
    @State private var importKeyText = ""
    @State private var passphrase = ""
    @State private var principal = "netbird-admin"
    @State private var message: String?
    @State private var confirmRegenerate = false
    @State private var showFileImporter = false

    var body: some View {
        Form {
            Section {
                if let pubKey {
                    Text(pubKey).font(.caption2.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = pubKey; message = "Public Key kopiert" } label: {
                        Label("Public Key kopieren", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: pubKey, preview: SharePreview("netbird-ios.pub")) {
                        Label("Public Key teilen", systemImage: "square.and.arrow.up")
                    }
                    Button("Neuen Schlüssel erzeugen", role: .destructive) { confirmRegenerate = true }
                } else {
                    Button { generate() } label: { Label("Ed25519-Schlüssel erzeugen", systemImage: "key.fill") }
                }
            } header: { Text("1 · Schlüssel") } footer: {
                Text("Der private Schlüssel verlässt das Gerät nicht (Keychain, nur dieses Gerät).")
            }

            if pubKey != nil {
                Section {
                    TextField("Principal", text: $principal).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(SSHKeyManager.signCommand(principal: principal))
                        .font(.caption2.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = SSHKeyManager.signCommand(principal: principal); message = "Befehl kopiert" } label: {
                        Label("Signier-Befehl kopieren", systemImage: "doc.on.doc")
                    }
                } header: { Text("2 · Auf dem Server signieren") } footer: {
                    Text("Voraussetzung: einmalig server/setup-ssh-ca.sh ausführen. Diese CA vertraut sshd; der Principal erlaubt den root-Login.")
                }

                Section {
                    if let info = certInfo {
                        LabeledContent("Key-ID", value: info.keyID)
                        LabeledContent("Principals", value: info.principals.joined(separator: ", "))
                        LabeledContent("Gültig ab", value: info.validAfter.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Gültig bis", value: info.validBefore?.formatted(date: .abbreviated, time: .shortened) ?? "unbegrenzt")
                        LabeledContent("Seriennr.", value: "\(info.serial)")
                        HStack {
                            Text("Status")
                            Spacer()
                            Pill(text: info.isValidNow ? "gültig" : "abgelaufen / noch nicht gültig", color: info.isValidNow ? .nbOnline : .red)
                        }
                        Button("Zertifikat entfernen", role: .destructive) {
                            SSHKeyManager.removeCertificate(); reload()
                        }
                    }
                    TextEditor(text: $certText)
                        .font(.caption2.monospaced()).frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if certText.isEmpty {
                                Text("ssh-ed25519-cert-v01@openssh.com AAAA…").font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Button("Aus Zwischenablage") { certText = UIPasteboard.general.string ?? "" }
                        Spacer()
                        Button("Datei …") { showFileImporter = true }
                    }
                    .buttonStyle(.borderless)
                    Button { importCert() } label: { Label("Zertifikat importieren", systemImage: "checkmark.seal") }
                        .disabled(certText.isEmpty)
                } header: { Text("3 · Zertifikat") }
            }

            Section {
                SecureField("-----BEGIN OPENSSH PRIVATE KEY-----", text: $importKeyText)
                    .font(.caption2.monospaced())
                SecureField("Passphrase (optional)", text: $passphrase)
                Button("Vorhandenen Ed25519-Key importieren") {
                    do {
                        try SSHKeyManager.importKey(openSSH: importKeyText, passphrase: passphrase)
                        importKeyText = ""; passphrase = ""
                        reload(); message = "Schlüssel importiert"
                    } catch { message = error.localizedDescription }
                }
                .disabled(importKeyText.isEmpty)
            } header: { Text("Alternativ") }
        }
        .glassScreen()
        .navigationTitle("SSH-Zertifikat")
        .navigationBarTitleDisplayMode(.inline)
        .errorBanner($message)
        .confirmationDialog("Neuen Schlüssel erzeugen? Das bestehende Zertifikat wird ungültig.",
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Neu erzeugen", role: .destructive) { generate() }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data, .plainText, .item]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                certText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    private func generate() {
        SSHKeyManager.generateKey()
        reload()
        message = "Neuer Schlüssel erzeugt – jetzt signieren lassen"
    }

    private func importCert() {
        do {
            try SSHKeyManager.importCertificate(certText)
            certText = ""
            reload()
            message = "Zertifikat importiert"
        } catch { message = error.localizedDescription }
    }

    private func reload() {
        pubKey = SSHKeyManager.publicKeyOpenSSH
        certInfo = SSHKeyManager.certInfo
    }
}

/// Einfache Befehls-Konsole (z. B. `docker compose ps`, Logs) über die Zertifikats-Verbindung.
struct SSHConsoleView: View {
    @Environment(AppStore.self) private var store
    @State private var command = ""
    @State private var output: [String] = []
    @State private var running = false

    private var installDir: String { SSHSession.shellQuote(store.current?.installDir ?? "/opt/netbird") }

    private var quick: [(String, String)] {
        [
            ("Container", "cd \(installDir) && docker compose ps"),
            ("Mgmt-Logs", "cd \(installDir) && docker compose logs --tail=80 management 2>/dev/null || docker compose logs --tail=80"),
            ("Proxy-Logs", "cd \(installDir) && docker compose logs --tail=80 proxy caddy traefik 2>/dev/null"),
            ("Neustart", "cd \(installDir) && docker compose restart"),
            ("Speicher", "df -h / && free -h"),
            ("IPv6", "ip -6 addr show scope global; sysctl net.ipv6.conf.all.forwarding"),
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(quick, id: \.0) { q in
                        Button(q.0) { Task { await run(q.1) } }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glass(cornerRadius: 14, interactive: true)
                    }
                }
                .padding(.horizontal)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(output.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.caption2.monospaced()).id(i).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .textSelection(.enabled)
                }
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .onChange(of: output.count) { _, c in proxy.scrollTo(c - 1, anchor: .bottom) }
            }
            HStack {
                TextField("Befehl", text: $command)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await run(command) } }
                Button { Task { await run(command) } } label: {
                    if running { ProgressView() } else { Image(systemName: "paperplane.fill") }
                }
                .disabled(running || command.isEmpty)
            }
            .padding(12)
            .glass(cornerRadius: 18)
            .padding([.horizontal, .bottom])
        }
        .background(GlassBackground())
        .navigationTitle("SSH-Konsole")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { output.removeAll() } label: { Image(systemName: "trash") } }
    }

    private func run(_ cmd: String) async {
        guard let p = store.current, !cmd.isEmpty else { return }
        running = true
        defer { running = false }
        output.append("$ \(cmd)")
        do {
            let s = try await SSHSession.connect(profile: p)
            if p.trustedHostKey == nil, let fp = s.hostKeyFingerprint {
                var np = p; np.trustedHostKey = fp; store.current = np
                output.append("ℹ︎ Host-Key gespeichert: \(fp)")
            }
            let code = try await s.run(cmd) { line in Task { @MainActor in output.append(line) } }
            await s.close()
            output.append("⏎ exit \(code)")
        } catch {
            output.append("✗ \(error.localizedDescription)")
        }
    }
}
