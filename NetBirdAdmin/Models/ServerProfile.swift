import Foundation

/// Ein verwalteter NetBird-Server (Management-API + SSH-Zugang für Updates).
struct ServerProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String = "Mein NetBird"
    /// z. B. https://netbird.example.com  (ohne /api)
    var managementURL: String = "https://"

    // SSH
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUser: String = "root"
    /// Verzeichnis mit docker-compose.yml / management.json der NetBird-Installation
    var installDir: String = "/opt/netbird"
    var updateMode: UpdateMode = .dockerCompose
    var customUpdateCommand: String = ""
    /// Fingerprint des Host-Keys (Trust on first use)
    var trustedHostKey: String?

    enum UpdateMode: String, Codable, CaseIterable, Identifiable {
        case dockerCompose = "Docker Compose"
        case custom = "Eigener Befehl"
        var id: String { rawValue }
    }

    // Secrets liegen in der Keychain, nicht in UserDefaults
    var tokenKey: String { "pat-\(id.uuidString)" }
    var apiToken: String? {
        get { KeychainStore.string(for: tokenKey) }
        nonmutating set { KeychainStore.setString(newValue, for: tokenKey) }
    }

    var apiBaseURL: URL? {
        var s = managementURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api") { s.removeLast(4) }
        return URL(string: s + "/api")
    }

    var effectiveSSHHost: String {
        if !sshHost.isEmpty { return sshHost }
        return URL(string: managementURL)?.host ?? ""
    }
}
