import Foundation
import SwiftUI

/// Zentraler App-Zustand: Server-Profile + gecachte Daten des aktiven Servers.
@MainActor
@Observable
final class AppStore {
    var profiles: [ServerProfile] = [] { didSet { persist() } }
    var selectedID: UUID? { didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedProfile") } }

    var peers: [Peer] = []
    var groups: [NBGroup] = []
    var setupKeys: [SetupKey] = []
    var routes: [NBRoute] = []
    var services: [ProxyService] = []
    var clusters: [ProxyCluster] = []
    var domains: [ReverseProxyDomain] = []
    var account: NBAccount?
    var users: [NBUser] = []
    var resources: [NetworkResource] = []
    var latestRelease: GitHubRelease?

    var isLoading = false
    var lastError: String?
    var proxyAvailable = true
    var lastRefresh: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let p = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = p
        }
        if let s = UserDefaults.standard.string(forKey: "selectedProfile"), let id = UUID(uuidString: s) {
            selectedID = id
        }
        if selectedID == nil { selectedID = profiles.first?.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
        }
    }

    var current: ServerProfile? {
        get { profiles.first { $0.id == selectedID } }
        set {
            guard let newValue, let i = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[i] = newValue
        }
    }

    func api() throws -> NetBirdAPI {
        guard let current else { throw APIError.invalidURL }
        return try NetBirdAPI(profile: current)
    }

    func upsert(_ p: ServerProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        if selectedID == nil { selectedID = p.id }
    }

    func remove(_ p: ServerProfile) {
        KeychainStore.delete(p.tokenKey)
        profiles.removeAll { $0.id == p.id }
        if selectedID == p.id { selectedID = profiles.first?.id; clear() }
    }

    func select(_ p: ServerProfile) {
        selectedID = p.id
        clear()
        Task { await refreshAll() }
    }

    func clear() {
        peers = []; groups = []; setupKeys = []; routes = []
        services = []; clusters = []; domains = []; account = nil
        users = []; resources = []
    }

    // MARK: Abgeleitete Werte

    var onlinePeers: Int { peers.filter(\.connected).count }
    var exitNodes: [NBRoute] { routes.filter(\.isExitNode) }
    var ipv6Enabled: Bool {
        guard let s = account?.settings else { return false }
        return !(s["ipv6_enabled_groups"]?.stringArray.isEmpty ?? true)
    }

    func groupName(_ id: String) -> String { groups.first { $0.id == id }?.name ?? id }
    func peerName(_ id: String) -> String { peers.first { $0.id == id }?.name ?? id }
    func userName(_ id: String) -> String { users.first { $0.id == id }?.displayName ?? id }

    func peerIsOutdated(_ p: Peer) -> Bool {
        guard let l = SemVer(latestRelease?.tagName), let v = SemVer(p.version) else { return false }
        return v < l
    }

    // MARK: Laden

    func refreshAll() async {
        guard current != nil else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            let api = try api()
            async let p = api.peers()
            async let g = api.groups()
            async let k = api.setupKeys()
            async let r = api.routes()
            async let a = try? api.accounts()
            async let rel = try? GitHubReleases.latest()
            peers = try await p.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
            groups = try await g.sorted { $0.name.lowercased() < $1.name.lowercased() }
            setupKeys = try await k
            routes = try await r
            account = await a?.first
            if let release = await rel { latestRelease = release }
            lastRefresh = Date()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshProxy()
        await reloadUsers()
    }

    func reloadPeersAndGroups() async {
        guard let api = try? api() else { return }
        do {
            async let p = api.peers()
            async let g = api.groups()
            peers = try await p.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
            groups = try await g.sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch { lastError = error.localizedDescription }
    }

    func reloadUsers() async {
        guard let api = try? api() else { return }
        do {
            async let u = api.users()
            async let su = try? api.serviceUsers()
            var all = try await u
            for s in await su ?? [] where !all.contains(where: { $0.id == s.id }) { all.append(s) }
            users = all.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        } catch { lastError = error.localizedDescription }
    }

    func loadResources() async {
        guard let api = try? api() else { return }
        guard let nets = try? await api.networks() else { return }
        var all: [NetworkResource] = []
        for n in nets {
            if var rs = try? await api.networkResources(n.id) {
                for i in rs.indices { rs[i].networkName = n.name }
                all += rs
            }
        }
        resources = all
    }

    func refreshProxy() async {
        guard let api = try? api() else { return }
        do {
            async let s = api.proxyServices()
            async let c = try? api.proxyClusters()
            async let d = try? api.proxyDomains()
            services = try await s
            clusters = await c ?? []
            domains = await d ?? []
            proxyAvailable = true
        } catch APIError.http(let code, _) where code == 404 || code == 403 {
            proxyAvailable = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Führt eine Aktion aus und zeigt Fehler zentral an.
    func perform(_ action: (NetBirdAPI) async throws -> Void) async -> Bool {
        do {
            try await action(try api())
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
