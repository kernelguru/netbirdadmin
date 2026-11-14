import SwiftUI

struct ServerUpdateView: View {
    @Environment(AppStore.self) private var store
    @State private var updater = ServerUpdater()
    @State private var confirm = false
    @State private var useSSH = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                versionsCard
                if let fp = updater.hostKeyToTrust, store.current?.trustedHostKey == nil {
                    hostKeyCard(fp)
                }
                actionCard
                if let notes = updater.latest?.body, !notes.isEmpty {
                    DisclosureGroup("Release Notes \(updater.latest?.tagName ?? "")") {
                        Text(notes).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .glassCard()
                }
                if !updater.log.isEmpty { logCard }
            }
            .padding()
        }
        .glassScreen()
        .navigationTitle("Server-Update")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
        .refreshable { await check() }
        .confirmationDialog("NetBird auf \(updater.latest?.tagName ?? "latest") aktualisieren?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Update starten") { Task { if let p = store.current { await updater.runUpdate(profile: p) } } }
        } message: {
            Text("Die Container werden neu gestartet. Clients verbinden sich danach automatisch wieder.")
        }
    }

    private func check() async {
        guard let p = store.current else { return }
        await updater.check(profile: p, viaSSH: useSSH && SSHKeyManager.hasKey)
    }

    private var versionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("NetBird", systemImage: "shippingbox.fill").font(.headline)
                Spacer()
                if updater.phase == .checking { ProgressView() }
            }
            HStack(alignment: .top) {
                versionColumn("Installiert", updater.localVersion ?? "–",
                              sub: updater.sshVersion != nil ? "via SSH" : (updater.apiVersion != nil ? "via API" : nil))
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 20)
                versionColumn("Offiziell (GitHub)", updater.latest?.tagName ?? "–",
                              sub: updater.latest?.publishedAt?.formatted(date: .abbreviated, time: .omitted))
            }
            if let d = updater.dashboardAvailable {
                Text("Dashboard verfügbar: \(d)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: updater.updateAvailable ? "exclamationmark.arrow.circlepath" : "checkmark.seal.fill")
                Text(updater.updateAvailable ? "Update verfügbar" : "Aktuell")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(updater.updateAvailable ? Color.nbOrange : Color.nbOnline)
        }
        .glassCard(tint: updater.updateAvailable ? .nbOrange : .nbOnline)
    }

    private func versionColumn(_ title: String, _ value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospaced())
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hostKeyCard(_ fp: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Neuer Host-Key", systemImage: "lock.shield").font(.headline)
            Text("Vergleiche den Fingerprint mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` auf dem Server.")
                .font(.caption).foregroundStyle(.secondary)
            Text(fp).font(.caption.monospaced()).textSelection(.enabled)
            Button("Host-Key vertrauen") {
                if var p = store.current { p.trustedHostKey = fp; store.current = p }
                updater.hostKeyToTrust = nil
            }
            .buttonStyle(GlassButtonStyle(tint: .nbBlue))
        }
        .glassCard(tint: .nbBlue)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Lokale Version per SSH prüfen", isOn: $useSSH)
            if let p = store.current {
                LabeledContent("Ziel", value: "\(p.sshUser)@\(p.effectiveSSHHost):\(p.sshPort)")
                    .font(.footnote)
                LabeledContent("Methode", value: p.updateMode.rawValue).font(.footnote)
            }
            if !SSHKeyManager.hasKey || SSHKeyManager.certificate == nil {
                NavigationLink { SSHKeyView() } label: {
                    Label("SSH-Zertifikat einrichten", systemImage: "key.viewfinder")
                }
            }
            Button {
                confirm = true
            } label: {
                if updater.phase == .updating {
                    HStack { ProgressView().tint(.white); Text("Update läuft …") }
                } else {
                    Label(updater.updateAvailable ? "Jetzt aktualisieren" : "Update trotzdem ausführen",
                          systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(GlassButtonStyle(tint: updater.updateAvailable ? .nbOrange : .gray))
            .disabled(updater.phase == .updating || !SSHKeyManager.hasKey || store.current?.trustedHostKey == nil && updater.hostKeyToTrust != nil)
            if case .done(let ok) = updater.phase {
                Label(ok ? "Erfolgreich aktualisiert" : "Update mit Fehlern beendet",
                      systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.nbOnline : .red)
            }
            if case .failed(let msg) = updater.phase {
                Text(msg).font(.footnote).foregroundStyle(.red)
            }
        }
        .glassCard()
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Protokoll", systemImage: "terminal").font(.headline)
                Spacer()
                Button { UIPasteboard.general.string = updater.log.joined(separator: "\n") } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(updater.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.caption2.monospaced()).id(i)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 260)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: updater.log.count) { _, c in withAnimation { proxy.scrollTo(c - 1, anchor: .bottom) } }
            }
        }
        .glassCard()
    }
}
