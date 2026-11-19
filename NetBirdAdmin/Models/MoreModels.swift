import Foundation

// MARK: - Zugriffsrichtlinien

struct ResourceRef: Codable, Hashable {
    var id: String
    var type: String
}

struct RulePortRange: Codable, Hashable {
    var start: Int
    var end: Int
}

struct NBPolicyRule: Decodable, Hashable {
    var id: String?
    var name: String
    var description: String?
    var enabled: Bool
    var action: String
    var bidirectional: Bool
    var `protocol`: String
    var ports: [String]?
    var portRanges: [RulePortRange]?
    var sources: [GroupMinimum]?
    var destinations: [GroupMinimum]?
    var destinationResource: ResourceRef?
    var sourceResource: ResourceRef?

    var portText: String {
        let p = (ports ?? []) + (portRanges ?? []).map { "\($0.start)-\($0.end)" }
        return p.isEmpty ? "alle Ports" : p.joined(separator: ", ")
    }
}

struct NBPolicy: Decodable, Hashable, Identifiable {
    let id: String
    var name: String
    var description: String?
    var enabled: Bool
    var rules: [NBPolicyRule]
    var sourcePostureChecks: [String]?
}

// MARK: - Netzwerke

struct NetworkRouter: Decodable, Hashable, Identifiable {
    let id: String
    var peer: String?
    var peerGroups: [String]?
    var metric: Int
    var masquerade: Bool
    var enabled: Bool
}

struct NetworkRouterRequest: Encodable {
    var peer: String?
    var peerGroups: [String]?
    var metric: Int
    var masquerade: Bool
    var enabled: Bool
}

struct NetworkRequest: Encodable {
    var name: String
    var description: String
}

struct NetworkResourceRequest: Encodable {
    var name: String
    var description: String
    var address: String
    var enabled: Bool
    var groups: [String]
}

struct NetworkResourceDetail: Decodable, Hashable, Identifiable {
    let id: String
    var type: String
    var name: String
    var description: String?
    var address: String
    var enabled: Bool
    var groups: [GroupMinimum]
}

// MARK: - DNS

struct Nameserver: Codable, Hashable {
    var ip: String
    var nsType: String = "udp"
    var port: Int = 53
}

struct NameserverGroup: Codable, Hashable, Identifiable {
    var id: String = ""
    var name: String
    var description: String?
    var nameservers: [Nameserver]
    var enabled: Bool
    var groups: [String]
    var primary: Bool
    var domains: [String]
    var searchDomainsEnabled: Bool
}

struct NameserverGroupRequest: Encodable {
    var name: String
    var description: String
    var nameservers: [Nameserver]
    var enabled: Bool
    var groups: [String]
    var primary: Bool
    var domains: [String]
    var searchDomainsEnabled: Bool
}

struct DNSRecord: Codable, Hashable, Identifiable {
    var id: String = ""
    var name: String
    var type: String     // A | AAAA | CNAME
    var content: String
    var ttl: Int
}

struct DNSRecordRequest: Encodable {
    var name: String
    var type: String
    var content: String
    var ttl: Int
}

struct DNSZone: Decodable, Hashable, Identifiable {
    let id: String
    var name: String
    var domain: String
    var enabled: Bool
    var enableSearchDomain: Bool
    var distributionGroups: [String]
    var records: [DNSRecord]
}

struct DNSZoneRequest: Encodable {
    var name: String
    var domain: String
    var enabled: Bool
    var enableSearchDomain: Bool
    var distributionGroups: [String]
}

// MARK: - Logs

struct AuditEvent: Decodable, Hashable, Identifiable {
    let id: String
    var timestamp: Date?
    var activity: String
    var activityCode: String
    var initiatorId: String?
    var initiatorName: String?
    var initiatorEmail: String?
    var targetId: String?
    var meta: [String: String]?

    var initiator: String {
        if let n = initiatorName, !n.isEmpty { return n }
        if let e = initiatorEmail, !e.isEmpty { return e }
        return initiatorId ?? "System"
    }
}

struct ProxyAccessLog: Decodable, Hashable, Identifiable {
    let id: String
    var serviceId: String?
    var timestamp: Date?
    var method: String?
    var host: String?
    var path: String?
    var durationMs: Int?
    var statusCode: Int?
    var sourceIp: String?
    var reason: String?
    var userId: String?
    var authMethodUsed: String?
    var countryCode: String?
    var cityName: String?
    var bytesUpload: Int?
    var bytesDownload: Int?
    var `protocol`: String?
}

struct ProxyAccessLogPage: Decodable {
    var data: [ProxyAccessLog]
    var page: Int?
    var pageSize: Int?
    var totalRecords: Int?
    var totalPages: Int?
}

// MARK: - Peer-Jobs (Debug-Paket)

struct PeerJob: Decodable, Hashable, Identifiable {
    let id: String
    var createdAt: Date?
    var completedAt: Date?
    var triggeredBy: String?
    var status: String          // pending | succeeded | failed
    var failedReason: String?
    var workload: JobWorkload?

    struct JobWorkload: Decodable, Hashable {
        var type: String?
        var result: JobResult?
    }
    struct JobResult: Decodable, Hashable {
        var uploadKey: String?
    }
}
