import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case missingToken
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ungültige Management-URL"
        case .missingToken: return "Kein API-Token (Personal Access Token) hinterlegt"
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decoding(let msg): return "Antwort konnte nicht gelesen werden: \(msg)"
        }
    }
}

/// Client für die NetBird Management REST-API (`/api/...`).
/// Auth: `Authorization: Token <PAT>` (Personal Access Token eines Service-Users).
struct NetBirdAPI {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    init(profile: ServerProfile) throws {
        guard let url = profile.apiBaseURL, url.host != nil else { throw APIError.invalidURL }
        guard let token = profile.apiToken, !token.isEmpty else { throw APIError.missingToken }
        self.baseURL = url
        self.token = token
    }

    // MARK: Coding

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = DateParsing.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ungültiges Datum: \(s)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// Für JSONValue-Roundtrips: keine Key-Konvertierung.
    static let rawDecoder = JSONDecoder()
    static let rawEncoder = JSONEncoder()

    // MARK: Core

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(0, "Keine HTTP-Antwort") }
        guard (200..<300).contains(http.statusCode) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let m = obj["message"] as? String { msg = m }
            throw APIError.http(http.statusCode, msg)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request("GET", path)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B) async throws -> T {
        let data = try await request(method, path, body: try Self.encoder.encode(body))
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    private func delete(_ path: String) async throws {
        _ = try await request("DELETE", path)
    }

    func rawSend(_ method: String, _ path: String, _ value: JSONValue) async throws -> JSONValue {
        let data = try await request(method, path, body: try Self.rawEncoder.encode(value))
        return (try? Self.rawDecoder.decode(JSONValue.self, from: data)) ?? .null
    }

    /// JSONValue (snake_case) in ein typisiertes Modell umwandeln.
    static func typed<T: Decodable>(_ value: JSONValue) throws -> T {
        do { return try decoder.decode(T.self, from: try rawEncoder.encode(value)) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    func rawGet(_ path: String) async throws -> JSONValue {
        try Self.rawDecoder.decode(JSONValue.self, from: try await request("GET", path))
    }

    @discardableResult
    func rawPut(_ path: String, _ value: JSONValue) async throws -> JSONValue {
        let data = try await request("PUT", path, body: try Self.rawEncoder.encode(value))
        return (try? Self.rawDecoder.decode(JSONValue.self, from: data)) ?? .null
    }

    // MARK: Instance

    func versionInfo() async throws -> InstanceVersionInfo { try await get("/instance/version") }

    // MARK: Peers

    func peers() async throws -> [Peer] { try await get("/peers") }
    func peer(_ id: String) async throws -> Peer { try await get("/peers/\(id)") }
    func updatePeer(_ id: String, _ body: PeerUpdateRequest) async throws -> Peer { try await send("PUT", "/peers/\(id)", body) }
    func deletePeer(_ id: String) async throws { try await delete("/peers/\(id)") }

    // MARK: Groups

    func groups() async throws -> [NBGroup] { try await get("/groups") }
    func createGroup(_ body: GroupCreateRequest) async throws -> NBGroup { try await send("POST", "/groups", body) }
    func deleteGroup(_ id: String) async throws { try await delete("/groups/\(id)") }

    /// Gruppe umbenennen / Mitglieder setzen. Ressourcen bleiben erhalten.
    func updateGroup(_ id: String, name: String? = nil, peers: [String]) async throws -> NBGroup {
        let raw = try await rawGet("/groups/\(id)")
        let resources = raw["resources"] ?? .array([])
        let body: JSONValue = .object([
            "name": .string(name ?? raw["name"]?.stringValue ?? ""),
            "peers": .array(peers.map { .string($0) }),
            "resources": resources == .null ? .array([]) : resources,
        ])
        return try Self.typed(try await rawPut("/groups/\(id)", body))
    }

    func addPeer(_ peerID: String, toGroup groupID: String) async throws -> NBGroup {
        let g: NBGroup = try await get("/groups/\(groupID)")
        var ids = (g.peers ?? []).map(\.id)
        if !ids.contains(peerID) { ids.append(peerID) }
        return try await updateGroup(groupID, peers: ids)
    }

    func removePeer(_ peerID: String, fromGroup groupID: String) async throws -> NBGroup {
        let g: NBGroup = try await get("/groups/\(groupID)")
        return try await updateGroup(groupID, peers: (g.peers ?? []).map(\.id).filter { $0 != peerID })
    }

    // MARK: Users

    func users() async throws -> [NBUser] { try await get("/users") }
    func serviceUsers() async throws -> [NBUser] { try await get("/users?service_user=true") }
    func createUser(_ body: UserCreateRequest) async throws -> NBUser { try await send("POST", "/users", body) }
    func updateUser(_ id: String, _ body: UserUpdateRequest) async throws -> NBUser { try await send("PUT", "/users/\(id)", body) }
    func deleteUser(_ id: String) async throws { try await delete("/users/\(id)") }
    func resendInvite(_ id: String) async throws { _ = try await request("POST", "/users/\(id)/invite") }

    func approveUser(_ id: String) async throws { _ = try await request("POST", "/users/\(id)/approve") }
    func rejectUser(_ id: String) async throws { _ = try await request("DELETE", "/users/\(id)/reject") }

    // MARK: Peer-Freigabe & Debug-Paket

    /// Peer freigeben (approval_required = false). Übrige Felder bleiben unverändert.
    func approvePeer(_ p: Peer) async throws -> Peer {
        let body = PeerUpdateRequest(name: p.name, sshEnabled: p.sshEnabled, loginExpirationEnabled: p.loginExpirationEnabled,
                                     inactivityExpirationEnabled: p.inactivityExpirationEnabled ?? false, approvalRequired: false)
        return try await updatePeer(p.id, body)
    }

    func peerJobs(_ peerID: String) async throws -> [PeerJob] { try await get("/peers/\(peerID)/jobs") }
    func peerJob(_ peerID: String, _ jobID: String) async throws -> PeerJob { try await get("/peers/\(peerID)/jobs/\(jobID)") }

    func requestDebugBundle(_ peerID: String, minutes: Int, logFiles: Int, anonymize: Bool) async throws -> PeerJob {
        var params: [String: JSONValue] = [
            "bundle_for": .bool(minutes > 0),
            "bundle_for_time": .int(max(1, min(5, minutes))),
            "log_file_count": .int(logFiles),
            "anonymize": .bool(anonymize),
        ]
        if anonymize { params["anonymize_level"] = .string("default") }
        let body: JSONValue = .object(["workload": .object(["type": .string("bundle"), "parameters": .object(params)])])
        return try Self.typed(try await rawSend("POST", "/peers/\(peerID)/jobs", body))
    }

    // MARK: Zugriffsrichtlinien

    func policies() async throws -> [NBPolicy] { try await get("/policies") }
    func rawPolicy(_ id: String) async throws -> JSONValue { try await rawGet("/policies/\(id)") }
    func createPolicyRaw(_ body: JSONValue) async throws -> NBPolicy { try Self.typed(try await rawSend("POST", "/policies", body)) }
    func updatePolicyRaw(_ id: String, _ body: JSONValue) async throws -> NBPolicy { try Self.typed(try await rawPut("/policies/\(id)", body)) }
    func deletePolicy(_ id: String) async throws { try await delete("/policies/\(id)") }

    // MARK: DNS

    func nameserverGroups() async throws -> [NameserverGroup] { try await get("/dns/nameservers") }
    func createNameserverGroup(_ b: NameserverGroupRequest) async throws -> NameserverGroup { try await send("POST", "/dns/nameservers", b) }
    func updateNameserverGroup(_ id: String, _ b: NameserverGroupRequest) async throws -> NameserverGroup { try await send("PUT", "/dns/nameservers/\(id)", b) }
    func deleteNameserverGroup(_ id: String) async throws { try await delete("/dns/nameservers/\(id)") }

    func dnsZones() async throws -> [DNSZone] { try await get("/dns/zones") }
    func createDNSZone(_ b: DNSZoneRequest) async throws -> DNSZone { try await send("POST", "/dns/zones", b) }
    func updateDNSZone(_ id: String, _ b: DNSZoneRequest) async throws -> DNSZone { try await send("PUT", "/dns/zones/\(id)", b) }
    func deleteDNSZone(_ id: String) async throws { try await delete("/dns/zones/\(id)") }
    func createDNSRecord(_ zone: String, _ b: DNSRecordRequest) async throws -> DNSRecord { try await send("POST", "/dns/zones/\(zone)/records", b) }
    func updateDNSRecord(_ zone: String, _ id: String, _ b: DNSRecordRequest) async throws -> DNSRecord { try await send("PUT", "/dns/zones/\(zone)/records/\(id)", b) }
    func deleteDNSRecord(_ zone: String, _ id: String) async throws { try await delete("/dns/zones/\(zone)/records/\(id)") }

    // MARK: Logs

    func auditEvents() async throws -> [AuditEvent] { try await get("/events/audit") }
    func proxyAccessLogs(page: Int = 1, pageSize: Int = 50, search: String? = nil) async throws -> ProxyAccessLogPage {
        var q = "/events/proxy?page=\(page)&page_size=\(pageSize)&sort_by=timestamp&sort_order=desc"
        if let search, !search.isEmpty, let e = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { q += "&search=\(e)" }
        return try await get(q)
    }

    // MARK: Networks

    func networks() async throws -> [NBNetwork] { try await get("/networks") }
    func networkResources(_ networkID: String) async throws -> [NetworkResource] { try await get("/networks/\(networkID)/resources") }
    func networkResourceDetails(_ networkID: String) async throws -> [NetworkResourceDetail] { try await get("/networks/\(networkID)/resources") }
    func createNetwork(_ b: NetworkRequest) async throws -> NBNetwork { try await send("POST", "/networks", b) }
    func updateNetwork(_ id: String, _ b: NetworkRequest) async throws -> NBNetwork { try await send("PUT", "/networks/\(id)", b) }
    func deleteNetwork(_ id: String) async throws { try await delete("/networks/\(id)") }
    func createNetworkResource(_ net: String, _ b: NetworkResourceRequest) async throws -> NetworkResourceDetail { try await send("POST", "/networks/\(net)/resources", b) }
    func updateNetworkResource(_ net: String, _ id: String, _ b: NetworkResourceRequest) async throws -> NetworkResourceDetail { try await send("PUT", "/networks/\(net)/resources/\(id)", b) }
    func deleteNetworkResource(_ net: String, _ id: String) async throws { try await delete("/networks/\(net)/resources/\(id)") }
    func networkRouters(_ net: String) async throws -> [NetworkRouter] { try await get("/networks/\(net)/routers") }
    func createNetworkRouter(_ net: String, _ b: NetworkRouterRequest) async throws -> NetworkRouter { try await send("POST", "/networks/\(net)/routers", b) }
    func updateNetworkRouter(_ net: String, _ id: String, _ b: NetworkRouterRequest) async throws -> NetworkRouter { try await send("PUT", "/networks/\(net)/routers/\(id)", b) }
    func deleteNetworkRouter(_ net: String, _ id: String) async throws { try await delete("/networks/\(net)/routers/\(id)") }

    // MARK: Setup Keys

    func setupKeys() async throws -> [SetupKey] { try await get("/setup-keys") }
    func createSetupKey(_ body: CreateSetupKeyRequest) async throws -> SetupKey { try await send("POST", "/setup-keys", body) }
    func updateSetupKey(_ id: String, _ body: UpdateSetupKeyRequest) async throws -> SetupKey { try await send("PUT", "/setup-keys/\(id)", body) }
    func deleteSetupKey(_ id: String) async throws { try await delete("/setup-keys/\(id)") }

    // MARK: Routes / Exit Nodes

    func routes() async throws -> [NBRoute] { try await get("/routes") }
    func createRoute(_ body: RouteRequest) async throws -> NBRoute { try await send("POST", "/routes", body) }
    func updateRoute(_ id: String, _ body: RouteRequest) async throws -> NBRoute { try await send("PUT", "/routes/\(id)", body) }
    func deleteRoute(_ id: String) async throws { try await delete("/routes/\(id)") }

    // MARK: Account (IPv6)

    func accounts() async throws -> [NBAccount] {
        // Settings werden roh (snake_case) gelesen, damit ein PUT keine Felder verliert.
        let raw = try await rawGet("/accounts")
        return (raw.arrayValue ?? []).compactMap { v in
            guard let id = v["id"]?.stringValue, let settings = v["settings"] else { return nil }
            return NBAccount(id: id, settings: settings, domain: v["domain"]?.stringValue)
        }
    }

    func updateAccountSettings(_ accountId: String, settings: JSONValue) async throws {
        // Read-only Felder dürfen nicht mitgeschickt werden
        let clean = settings.removing(["embedded_idp_enabled", "local_auth_disabled"])
        try await rawPut("/accounts/\(accountId)", .object(["settings": clean]))
    }

    // MARK: Reverse Proxy

    func proxyServices() async throws -> [ProxyService] { try await get("/reverse-proxies/services") }
    func proxyClusters() async throws -> [ProxyCluster] { try await get("/reverse-proxies/clusters") }
    func proxyDomains() async throws -> [ReverseProxyDomain] { try await get("/reverse-proxies/domains") }

    func createProxyService(_ body: ProxyServiceRequest) async throws -> ProxyService {
        try await send("POST", "/reverse-proxies/services", body)
    }

    /// Schaltet einen Service an/aus. Das Objekt wird roh geladen und nur `enabled`
    /// geändert, damit Auth-/Restriction-Konfiguration erhalten bleibt.
    func setProxyService(_ id: String, enabled: Bool) async throws {
        var raw = try await rawGet("/reverse-proxies/services/\(id)")
        raw["enabled"] = .bool(enabled)
        let body = raw.removing(["id", "meta", "terminated", "port_auto_assigned", "proxy_cluster"])
        try await rawPut("/reverse-proxies/services/\(id)", body)
    }

    func rawProxyService(_ id: String) async throws -> JSONValue { try await rawGet("/reverse-proxies/services/\(id)") }

    static let proxyReadOnlyKeys = ["id", "meta", "terminated", "port_auto_assigned", "proxy_cluster"]

    func createProxyServiceRaw(_ body: JSONValue) async throws -> ProxyService {
        try Self.typed(try await rawSend("POST", "/reverse-proxies/services", body.removing(Self.proxyReadOnlyKeys)))
    }

    func updateProxyServiceRaw(_ id: String, _ body: JSONValue) async throws -> ProxyService {
        try Self.typed(try await rawPut("/reverse-proxies/services/\(id)", body.removing(Self.proxyReadOnlyKeys)))
    }

    func deleteProxyService(_ id: String) async throws { try await delete("/reverse-proxies/services/\(id)") }

    func createProxyDomain(_ body: ReverseProxyDomainRequest) async throws -> ReverseProxyDomain {
        try await send("POST", "/reverse-proxies/domains", body)
    }

    func validateProxyDomain(_ id: String) async throws {
        _ = try await request("GET", "/reverse-proxies/domains/\(id)/validate")
    }

    func deleteProxyDomain(_ id: String) async throws { try await delete("/reverse-proxies/domains/\(id)") }
}

enum DateParsing {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        if s.isEmpty || s.hasPrefix("0001-01-01") { return nil }
        if let d = frac.date(from: s) ?? plain.date(from: s) { return d }
        // Go liefert bis zu 9 Nachkommastellen – auf 3 kürzen
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = s[s.index(after: dot)..<end].prefix(3)
            return frac.date(from: String(s[..<dot]) + "." + digits + String(s[end...]))
        }
        return nil
    }
}

/// Tolerantes Dekodieren optionaler Datumsfelder: NetBird (Go) liefert für
/// „nie“ den Nullwert `0001-01-01T00:00:00Z`, teils auch leere Strings.
/// Solche und unlesbare Werte werden zu `nil` statt die ganze Antwort scheitern zu lassen.
extension KeyedDecodingContainer {
    func decodeIfPresent(_ type: Date.Type, forKey key: Key) throws -> Date? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let s = try? decode(String.self, forKey: key) {
            return DateParsing.parse(s)
        }
        return try? decode(Date.self, forKey: key)
    }
}

/// Go serialisiert leere Slices teils als `null`. Pflicht-Listen werden deshalb
/// bei `null` oder fehlendem Schlüssel als leere Liste gelesen.
extension KeyedDecodingContainer {
    func decode<E: Decodable>(_ type: [E].Type, forKey key: Key) throws -> [E] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        return try decodeIfPresent([E].self, forKey: key) ?? []
    }
}
