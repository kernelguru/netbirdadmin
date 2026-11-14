import Foundation

/// Fragt die offiziellen NetBird-Releases auf GitHub ab (netbirdio/netbird).
enum GitHubReleases {
    static let repo = "netbirdio/netbird"

    static func latest(repo: String = repo) async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NetBirdAdmin-iOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, "GitHub-API nicht erreichbar (Rate-Limit?)") }
        return try NetBirdAPI.decoder.decode(GitHubRelease.self, from: data)
    }
}

/// Semantischer Versionsvergleich ("v0.52.1" vs "0.53.0").
struct SemVer: Comparable, CustomStringConvertible {
    let parts: [Int]
    let raw: String

    init?(_ s: String?) {
        guard var s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? s
        let p = core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        guard !p.isEmpty else { return nil }
        parts = p
        raw = core
    }

    var description: String { raw }

    static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}
