import Foundation

// MARK: - Peers

struct GroupMinimum: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    var peersCount: Int?
    var resourcesCount: Int?
}

struct NetworkAddress: Codable, Hashable {
    let netIp: String
    let mac: String?
}

struct Peer: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var ip: String
    var ipv6: String?
    var connectionIp: String?
    var connected: Bool
    var lastSeen: Date?
    var os: String
    var kernelVersion: String?
    var version: String
    var uiVersion: String?
    var groups: [GroupMinimum]
    var sshEnabled: Bool
    var hostname: String
    var dnsLabel: String
    var loginExpirationEnabled: Bool
    var loginExpired: Bool
    var inactivityExpirationEnabled: Bool?
    var approvalRequired: Bool?
    var countryCode: String?
    var cityName: String?
    var serialNumber: String?
    var ephemeral: Bool?
    var createdAt: Date?
    var lastLogin: Date?
    var userId: String?
    var networkAddresses: [NetworkAddress]?
}

struct PeerUpdateRequest: Encodable {
    var name: String
    var sshEnabled: Bool
    var loginExpirationEnabled: Bool
    var inactivityExpirationEnabled: Bool
    var approvalRequired: Bool?
}

// MARK: - Groups

struct NBGroup: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var peersCount: Int
    var resourcesCount: Int?
    var issued: String?
    var peers: [PeerMinimum]?
}

struct PeerMinimum: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

// MARK: - Setup Keys

struct SetupKey: Codable, Hashable, Identifiable {
    let id: String
    var key: String
    var name: String
    var expires: Date?
    var type: String
    var valid: Bool
    var revoked: Bool
    var usedTimes: Int
    var lastUsed: Date?
    var state: String
    var autoGroups: [String]
    var usageLimit: Int
    var ephemeral: Bool
    var allowExtraDnsLabels: Bool?
}

struct CreateSetupKeyRequest: Encodable {
    var name: String
    var type: String              // "one-off" | "reusable"
    var expiresIn: Int            // Sekunden (86400 ... 31536000)
    var autoGroups: [String]
    var usageLimit: Int
    var ephemeral: Bool
    var allowExtraDnsLabels: Bool
}

struct UpdateSetupKeyRequest: Encodable {
    var revoked: Bool
    var autoGroups: [String]
}

// MARK: - Routes (Exit Nodes)

struct NBRoute: Codable, Hashable, Identifiable {
    let id: String
    var networkType: String?
    var description: String
    var networkId: String
    var enabled: Bool
    var peer: String?
    var peerGroups: [String]?
    var network: String?
    var domains: [String]?
    var metric: Int
    var masquerade: Bool
    var groups: [String]
    var keepRoute: Bool
    var accessControlGroups: [String]?
    var skipAutoApply: Bool?

    var isExitNode: Bool { network == "0.0.0.0/0" || network == "::/0" }
    var isIPv6: Bool { network?.contains(":") ?? false }
}

struct RouteRequest: Encodable {
    var description: String
    var networkId: String
    var enabled: Bool
    var peer: String?
    var peerGroups: [String]?
    var network: String?
    var domains: [String]?
    var metric: Int
    var masquerade: Bool
    var groups: [String]
    var keepRoute: Bool
    var accessControlGroups: [String]?
    var skipAutoApply: Bool

    init(from r: NBRoute) {
        description = r.description
        networkId = r.networkId
        enabled = r.enabled
        peer = r.peer
        peerGroups = (r.peerGroups?.isEmpty ?? true) ? nil : r.peerGroups
        if peer != nil { peerGroups = nil }
        network = (r.domains?.isEmpty ?? true) ? (r.network ?? "0.0.0.0/0") : nil
        domains = (r.domains?.isEmpty ?? true) ? nil : r.domains
        metric = r.metric
        masquerade = r.masquerade
        groups = r.groups
        keepRoute = r.keepRoute
        accessControlGroups = r.accessControlGroups
        skipAutoApply = r.skipAutoApply ?? false
    }

    init(description: String, networkId: String, enabled: Bool, peer: String?, peerGroups: [String]?,
         network: String, metric: Int, masquerade: Bool, groups: [String], skipAutoApply: Bool) {
        self.description = description
        self.networkId = networkId
        self.enabled = enabled
        self.peer = peer
        self.peerGroups = peerGroups
        self.network = network
        self.metric = metric
        self.masquerade = masquerade
        self.groups = groups
        self.keepRoute = true
        self.accessControlGroups = nil
        self.skipAutoApply = skipAutoApply
    }
}

// MARK: - Account

struct NBAccount: Decodable, Identifiable {
    let id: String
    var settings: JSONValue
    var domain: String?
}

// MARK: - Instance

struct InstanceVersionInfo: Codable {
    var managementCurrentVersion: String
    var dashboardAvailableVersion: String?
    var managementAvailableVersion: String?
    var managementUpdateAvailable: Bool
}

// MARK: - Reverse Proxy

struct ProxyService: Decodable, Hashable, Identifiable {
    let id: String
    var name: String
    var domain: String
    var mode: String?
    var listenPort: Int?
    var proxyCluster: String?
    var targets: [ProxyTarget]
    var enabled: Bool
    var terminated: Bool?
    var passHostHeader: Bool?
    var rewriteRedirects: Bool?
    var meta: ProxyServiceMeta
    var `private`: Bool?
    var auth: ServiceAuthSummary?
    var accessGroups: [String]?

    var bearerGroups: [String] {
        guard auth?.bearerAuth?.enabled == true else { return [] }
        return auth?.bearerAuth?.distributionGroups ?? []
    }

    /// Kurzbeschreibung der aktiven Authentifizierungen
    var authLabels: [String] {
        var l: [String] = []
        if auth?.bearerAuth?.enabled == true { l.append("SSO") }
        if auth?.passwordAuth?.enabled == true { l.append("Passwort") }
        if auth?.pinAuth?.enabled == true { l.append("PIN") }
        if auth?.linkAuth?.enabled == true { l.append("Link") }
        if (auth?.headerAuths ?? []).contains(where: { $0.enabled }) { l.append("Header") }
        return l
    }
}

struct ServiceAuthSummary: Decodable, Hashable {
    struct Flag: Decodable, Hashable { var enabled: Bool }
    struct Bearer: Decodable, Hashable { var enabled: Bool; var distributionGroups: [String]? }
    struct Header: Decodable, Hashable { var enabled: Bool; var header: String }
    var passwordAuth: Flag?
    var pinAuth: Flag?
    var bearerAuth: Bearer?
    var linkAuth: Flag?
    var headerAuths: [Header]?
}

struct ProxyServiceMeta: Codable, Hashable {
    var createdAt: Date?
    var certificateIssuedAt: Date?
    var status: String
}

struct ProxyTarget: Codable, Hashable, Identifiable {
    var targetId: String
    var targetType: String       // peer | host | domain | subnet | cluster
    var path: String?
    var `protocol`: String       // http | https | tcp | udp
    var host: String?
    var port: Int
    var enabled: Bool
    var accessAction: String?
    var id: String { targetId + (path ?? "") + "\(port)" }
}

struct ProxyCluster: Codable, Hashable, Identifiable {
    let id: String
    var address: String
    var type: String
    var online: Bool
    var connectedProxies: Int
    var supportsCustomPorts: Bool?
    var requireSubdomain: Bool?
    var `private`: Bool?
}

struct ReverseProxyDomain: Codable, Hashable, Identifiable {
    let id: String
    var domain: String
    var validated: Bool
    var type: String
    var targetCluster: String?
    var requireSubdomain: Bool?
    var supportsPrivate: Bool?
}

struct ReverseProxyDomainRequest: Encodable {
    var domain: String
    var targetCluster: String
}

struct ProxyServiceRequest: Encodable {
    var name: String
    var domain: String
    var mode: String
    var listenPort: Int?
    var targets: [ProxyTarget]
    var enabled: Bool
    var passHostHeader: Bool
    var rewriteRedirects: Bool
}

// MARK: - GitHub

struct GitHubRelease: Decodable, Identifiable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: URL?
    let publishedAt: Date?
    let prerelease: Bool
}

// MARK: - Users

struct NBUser: Decodable, Hashable, Identifiable {
    let id: String
    var email: String?
    var name: String
    var role: String
    var status: String?
    var autoGroups: [String]
    var isServiceUser: Bool?
    var isBlocked: Bool
    var isCurrent: Bool?
    var lastLogin: Date?
    var issued: String?
    var password: String?

    var displayName: String { name.isEmpty ? (email ?? id) : name }
}

struct UserCreateRequest: Encodable {
    var email: String?
    var name: String
    var role: String
    var autoGroups: [String]
    var isServiceUser: Bool
}

struct UserUpdateRequest: Encodable {
    var role: String
    var autoGroups: [String]
    var isBlocked: Bool
}

enum UserRole: String, CaseIterable, Identifiable {
    case user, admin, auditor, networkAdmin = "network_admin", billingAdmin = "billing_admin", owner
    var id: String { rawValue }
    var label: String {
        switch self {
        case .user: return "Benutzer"
        case .admin: return "Administrator"
        case .auditor: return "Auditor (nur lesen)"
        case .networkAdmin: return "Netzwerk-Admin"
        case .billingAdmin: return "Billing-Admin"
        case .owner: return "Eigentümer"
        }
    }
    static var assignable: [UserRole] { [.user, .auditor, .networkAdmin, .admin, .billingAdmin] }
    static func label(_ raw: String) -> String { UserRole(rawValue: raw)?.label ?? raw }
}

// MARK: - Networks

struct NBNetwork: Decodable, Hashable, Identifiable {
    let id: String
    var name: String
    var description: String?
    var resources: [String]?
}

struct NetworkResource: Decodable, Hashable, Identifiable {
    let id: String
    var type: String          // host | subnet | domain
    var name: String
    var description: String?
    var address: String
    var enabled: Bool
    var networkName: String?  // von der App gesetzt
}

struct GroupCreateRequest: Encodable {
    var name: String
    var peers: [String]
}
