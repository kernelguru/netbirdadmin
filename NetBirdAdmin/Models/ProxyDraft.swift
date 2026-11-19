import Foundation

/// Bearbeitbare Kopie eines Reverse-Proxy-Services. Unbekannte Felder bleiben
/// über `raw` erhalten und werden beim Speichern unverändert zurückgeschickt.
struct HeaderPair: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""
}

struct HeaderAuthDraft: Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var header = "X-API-Key"
    var value = ""
    var hadValue = false
}

struct TargetDraft: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case peer = "Peer", resource = "Ressource", direct = "Direkt"
        var id: String { rawValue }
    }

    var id = UUID()
    var raw: JSONValue = .object([:])
    var kind: Kind = .peer
    var targetId = ""
    var resourceType = "host"
    var host = ""
    var port = 80
    var proto = "http"
    var path = "/"
    var enabled = true
    var accessAction = "inherit"
    var skipTLS = false
    var requestTimeout = ""
    var preservePath = false
    var headers: [HeaderPair] = []
    var proxyProtocol = false
    var directUpstream = false
    var sessionIdleTimeout = ""

    init() {}

    init(raw: JSONValue) {
        self.raw = raw
        let type = raw["target_type"]?.stringValue ?? "peer"
        switch type {
        case "peer": kind = .peer
        case "cluster": kind = .direct
        default: kind = .resource; resourceType = type
        }
        targetId = raw["target_id"]?.stringValue ?? ""
        host = raw["host"]?.stringValue ?? ""
        port = raw["port"]?.intValue ?? 80
        proto = raw["protocol"]?.stringValue ?? "http"
        path = raw["path"]?.stringValue ?? "/"
        enabled = raw["enabled"]?.boolValue ?? true
        accessAction = raw["access_action"]?.stringValue ?? "inherit"
        let o = raw["options"]
        skipTLS = o?["skip_tls_verify"]?.boolValue ?? false
        requestTimeout = o?["request_timeout"]?.stringValue ?? ""
        preservePath = o?["path_rewrite"]?.stringValue == "preserve"
        proxyProtocol = o?["proxy_protocol"]?.boolValue ?? false
        directUpstream = o?["direct_upstream"]?.boolValue ?? false
        sessionIdleTimeout = o?["session_idle_timeout"]?.stringValue ?? ""
        headers = (o?["custom_headers"]?.objectValue ?? [:])
            .sorted { $0.key < $1.key }
            .map { HeaderPair(key: $0.key, value: $0.value.stringValue ?? "") }
    }

    var targetType: String {
        switch kind {
        case .peer: return "peer"
        case .resource: return resourceType
        case .direct: return "cluster"
        }
    }

    func json(mode: String) -> JSONValue {
        var t = raw
        if t.objectValue == nil { t = .object([:]) }
        let isHTTP = mode == "http"
        t["target_type"] = .string(targetType)
        t["target_id"] = .string(kind == .direct ? host : targetId)
        let needsHost = kind == .direct || (kind == .resource && resourceType == "subnet") || directUpstream
        t["host"] = needsHost && !host.isEmpty ? .string(host) : nil
        t["port"] = .int(port)
        t["protocol"] = .string(proto)
        t["enabled"] = .bool(isHTTP ? enabled : true)
        if isHTTP {
            t["path"] = .string(path.isEmpty ? "/" : path)
            t["access_action"] = .string(accessAction)
        } else {
            t["path"] = nil
            t["access_action"] = nil
        }
        var o = raw["options"]?.objectValue ?? [:]
        o["skip_tls_verify"] = skipTLS ? .bool(true) : nil
        o["request_timeout"] = requestTimeout.isEmpty ? nil : .string(requestTimeout)
        o["path_rewrite"] = isHTTP && preservePath ? .string("preserve") : nil
        o["proxy_protocol"] = !isHTTP && proxyProtocol ? .bool(true) : nil
        o["session_idle_timeout"] = mode == "udp" && !sessionIdleTimeout.isEmpty ? .string(sessionIdleTimeout) : nil
        o["direct_upstream"] = (directUpstream || kind == .direct) ? .bool(true) : nil
        let hs = headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        o["custom_headers"] = isHTTP && !hs.isEmpty
            ? .object(Dictionary(hs.map { ($0.key.trimmingCharacters(in: .whitespaces), JSONValue.string($0.value)) }, uniquingKeysWith: { a, _ in a }))
            : nil
        t["options"] = o.isEmpty ? nil : .object(o)
        return t
    }

    @MainActor func summary(_ store: AppStore) -> String {
        let name: String
        switch kind {
        case .peer: name = store.peerName(targetId)
        case .resource: name = store.resources.first { $0.id == targetId }?.name ?? targetId
        case .direct: name = host
        }
        return "\(proto)://\(name):\(port)"
    }
}

struct ServiceDraft {
    var raw: JSONValue = .object([:])
    var isNew = true
    var domain = ""
    var mode = "http"
    var listenPort = 0
    var enabled = true
    var passHost = false
    var rewriteRedirects = false
    var targets: [TargetDraft] = []

    var ssoEnabled = false
    var ssoGroups: [String] = []
    var passwordEnabled = false
    var password = ""
    var hadPassword = false
    var pinEnabled = false
    var pin = ""
    var hadPin = false
    var linkEnabled = false
    var headerAuths: [HeaderAuthDraft] = []

    var isPrivate = false
    var accessGroups: [String] = []

    var allowedCIDRs = ""
    var blockedCIDRs = ""
    var allowedCountries = ""
    var blockedCountries = ""
    var crowdsec = "off"

    init() {}

    init(raw: JSONValue) {
        self.raw = raw
        isNew = false
        domain = raw["domain"]?.stringValue ?? ""
        mode = raw["mode"]?.stringValue ?? "http"
        listenPort = raw["listen_port"]?.intValue ?? 0
        enabled = raw["enabled"]?.boolValue ?? true
        passHost = raw["pass_host_header"]?.boolValue ?? false
        rewriteRedirects = raw["rewrite_redirects"]?.boolValue ?? false
        targets = (raw["targets"]?.arrayValue ?? []).map(TargetDraft.init(raw:))
        let a = raw["auth"]
        ssoEnabled = a?["bearer_auth"]?["enabled"]?.boolValue ?? false
        ssoGroups = a?["bearer_auth"]?["distribution_groups"]?.stringArray ?? []
        passwordEnabled = a?["password_auth"]?["enabled"]?.boolValue ?? false
        hadPassword = passwordEnabled
        pinEnabled = a?["pin_auth"]?["enabled"]?.boolValue ?? false
        hadPin = pinEnabled
        linkEnabled = a?["link_auth"]?["enabled"]?.boolValue ?? false
        headerAuths = (a?["header_auths"]?.arrayValue ?? []).map {
            HeaderAuthDraft(enabled: $0["enabled"]?.boolValue ?? false, header: $0["header"]?.stringValue ?? "",
                            value: "", hadValue: true)
        }
        isPrivate = raw["private"]?.boolValue ?? false
        accessGroups = raw["access_groups"]?.stringArray ?? []
        let r = raw["access_restrictions"]
        allowedCIDRs = (r?["allowed_cidrs"]?.stringArray ?? []).joined(separator: ", ")
        blockedCIDRs = (r?["blocked_cidrs"]?.stringArray ?? []).joined(separator: ", ")
        allowedCountries = (r?["allowed_countries"]?.stringArray ?? []).joined(separator: ", ")
        blockedCountries = (r?["blocked_countries"]?.stringArray ?? []).joined(separator: ", ")
        crowdsec = r?["crowdsec_mode"]?.stringValue ?? "off"
    }

    static func list(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Prüft offensichtliche Fehler vor dem Senden.
    var validationError: String? {
        if domain.isEmpty { return "Domain fehlt" }
        if targets.isEmpty { return "Mindestens ein Ziel ist nötig" }
        if mode != "http" && targets.count != 1 { return "\(mode.uppercased())-Services haben genau ein Ziel" }
        for (i, t) in targets.enumerated() {
            if t.kind == .direct && t.host.isEmpty { return "Ziel \(i + 1): Host fehlt" }
            if t.kind != .direct && t.targetId.isEmpty { return "Ziel \(i + 1): kein Peer/keine Ressource gewählt" }
            if t.kind == .resource && t.resourceType == "subnet" && t.host.isEmpty { return "Ziel \(i + 1): Für Subnetz-Ressourcen eine IP angeben" }
            if !(1...65535).contains(t.port) { return "Ziel \(i + 1): ungültiger Port" }
        }
        if isPrivate {
            if mode != "http" { return "Private Services gibt es nur im HTTP-Modus" }
            if accessGroups.isEmpty { return "Private Services brauchen mindestens eine Zugriffs-Gruppe" }
        } else {
            if passwordEnabled && !hadPassword && password.isEmpty { return "Passwort fehlt" }
            if pinEnabled && !hadPin && pin.isEmpty { return "PIN fehlt" }
            if ssoEnabled && ssoGroups.isEmpty { return "SSO braucht mindestens eine Gruppe" }
            for h in headerAuths where h.enabled && (h.header.isEmpty || (!h.hadValue && h.value.isEmpty)) {
                return "Header-Auth: Name und Wert angeben"
            }
        }
        for c in Self.list(allowedCountries) + Self.list(blockedCountries) where c.count != 2 {
            return "Ländercodes sind 2-stellig (ISO), z. B. DE"
        }
        return nil
    }

    func json() -> JSONValue {
        var s = raw
        if s.objectValue == nil { s = .object([:]) }
        s["name"] = .string(domain)
        s["domain"] = .string(domain)
        s["mode"] = .string(mode)
        s["listen_port"] = mode == "http" ? nil : .int(listenPort)
        s["enabled"] = .bool(enabled)
        s["pass_host_header"] = mode == "http" ? .bool(passHost) : nil
        s["rewrite_redirects"] = mode == "http" ? .bool(rewriteRedirects) : nil
        s["targets"] = .array(targets.map { $0.json(mode: mode) })

        var auth: [String: JSONValue] = [:]
        if !isPrivate && mode == "http" {
            auth["bearer_auth"] = .object(["enabled": .bool(ssoEnabled), "distribution_groups": .strings(ssoEnabled ? ssoGroups : [])])
            auth["password_auth"] = .object(["enabled": .bool(passwordEnabled), "password": .string(passwordEnabled ? password : "")])
            auth["pin_auth"] = .object(["enabled": .bool(pinEnabled), "pin": .string(pinEnabled ? pin : "")])
            auth["link_auth"] = .object(["enabled": .bool(linkEnabled)])
            let hs = headerAuths.filter { !$0.header.isEmpty }
            auth["header_auths"] = .array(hs.map {
                .object(["enabled": .bool($0.enabled), "header": .string($0.header), "value": .string($0.value)])
            })
        }
        s["auth"] = .object(auth)
        s["private"] = .bool(isPrivate)
        s["access_groups"] = isPrivate ? .strings(accessGroups) : nil

        let r: [String: JSONValue] = [
            "allowed_cidrs": .strings(Self.list(allowedCIDRs)),
            "blocked_cidrs": .strings(Self.list(blockedCIDRs)),
            "allowed_countries": .strings(Self.list(allowedCountries).map { $0.uppercased() }),
            "blocked_countries": .strings(Self.list(blockedCountries).map { $0.uppercased() }),
            "crowdsec_mode": .string(crowdsec),
        ]
        s["access_restrictions"] = .object(r)
        return s
    }
}
