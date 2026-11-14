import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    serverHeader
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatTile(title: "Clients online", value: "\(store.onlinePeers)/\(store.peers.count)",
                                 systemImage: "dot.radiowaves.left.and.right", color: .nbOnline)
                        StatTile(title: "Exit-Nodes", value: "\(Set(store.exitNodes.map(\.networkId)).count)",
                                 systemImage: "door.right.hand.open", color: .nbBlue)
                        StatTile(title: "Proxy-Services", value: "\(store.services.filter(\.enabled).count)/\(store.services.count)",
                                 systemImage: "arrow.triangle.branch", color: .nbOrange)
                        StatTile(title: "Setup-Keys gültig", value: "\(store.setupKeys.filter(\.valid).count)",
                                 systemImage: "key.horizontal", color: .nbTeal)
                    }
                    versionCard
                    recentPeers
                }
                .padding()
            }
            .glassScreen()
            .navigationTitle("NetBird")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading { ProgressView() }
                }
            }
        }
    }

    private var serverHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "bird.fill")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.nbOrange.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.current?.name ?? "Kein Server").font(.headline)
                Text(store.current?.managementURL ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let d = store.lastRefresh {
                    Text("Aktualisiert \(d.relative)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if store.ipv6Enabled { Pill(text: "IPv6", color: .nbTeal, systemImage: "6.circle") }
        }
        .glassCard()
    }

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Versionen", systemImage: "shippingbox").font(.headline)
            HStack {
                VStack(alignment: .leading) {
                    Text("Offizielles Release").font(.caption).foregroundStyle(.secondary)
                    Text(store.latestRelease?.tagName ?? "–").font(.title3.bold())
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Veraltete Clients").font(.caption).foregroundStyle(.secondary)
                    Text("\(store.peers.filter { store.peerIsOutdated($0) }.count)").font(.title3.bold())
                }
            }
            NavigationLink { ServerUpdateView() } label: {
                Label("Server-Update prüfen", systemImage: "arrow.down.circle")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .glassCard()
    }

    private var recentPeers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Clients", systemImage: "laptopcomputer").font(.headline)
            if store.peers.isEmpty {
                Text("Keine Clients geladen").foregroundStyle(.secondary).font(.subheadline)
            }
            ForEach(store.peers.prefix(6)) { p in
                NavigationLink { PeerDetailView(peerID: p.id) } label: { PeerRow(peer: p) }
                    .buttonStyle(.plain)
                if p.id != store.peers.prefix(6).last?.id { Divider().opacity(0.4) }
            }
        }
        .glassCard()
    }
}
