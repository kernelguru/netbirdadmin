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
