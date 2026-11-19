import Foundation

/// SSH-Zugangsdaten pro Peer (Host, Port, Benutzer, vertrauter Host-Key).
struct PeerSSHConfig: Codable, Hashable {
    var host: String
    var port: Int = 22
    var user: String = "root"
    var hostKey: String?

    private static let key = "peerSSHConfigs"

    static func load(_ peerID: String) -> PeerSSHConfig? { all()[peerID] }

    static func save(_ cfg: PeerSSHConfig, for peerID: String) {
        var a = all()
        a[peerID] = cfg
        if let d = try? JSONEncoder().encode(a) { UserDefaults.standard.set(d, forKey: key) }
    }

    private static func all() -> [String: PeerSSHConfig] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let a = try? JSONDecoder().decode([String: PeerSSHConfig].self, from: d) else { return [:] }
        return a
    }
}

/// Aktualisiert den NetBird-Client eines Peers per SSH (Zertifikat).
///
/// Weil ein Neustart des NetBird-Dienstes die SSH-Verbindung über das Overlay trennt,
/// läuft das Update losgelöst (nohup) auf dem Peer. Die App verbindet sich danach
/// erneut und liest Exit-Code und Protokoll aus.
@MainActor
@Observable
final class PeerUpdater {
    enum Phase: Equatable {
        case idle, connecting, started, waiting(Int), done(Bool), failed(String)
    }

    var phase: Phase = .idle
    var log: [String] = []
    var versionBefore: String?
    var versionAfter: String?
    /// Fehlertext für die Alert-Anzeige
    var errorDetail: String?
    var newHostKey: String?

    var isRunning: Bool {
        switch phase {
        case .connecting, .started, .waiting: return true
        default: return false
        }
    }

    static let logFile = "/var/log/netbird-admin-update.log"
    static let statusFile = "/var/tmp/netbird-admin-update.status"

    static let script = #"""
    set -u
    S=""; [ "$(id -u)" -ne 0 ] && S="sudo -n"
    echo "Version vorher: $(netbird version 2>/dev/null || echo unbekannt)"
    if command -v apt-get >/dev/null 2>&1 && dpkg -s netbird >/dev/null 2>&1; then
      echo "Paketquelle: apt"
      UI=""; dpkg -s netbird-ui >/dev/null 2>&1 && UI="netbird-ui"
      $S env DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
      $S env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade netbird $UI
    elif command -v dnf >/dev/null 2>&1 && rpm -q netbird >/dev/null 2>&1; then
      echo "Paketquelle: dnf"; $S dnf -y upgrade netbird
    elif command -v yum >/dev/null 2>&1 && rpm -q netbird >/dev/null 2>&1; then
      echo "Paketquelle: yum"; $S yum -y update netbird
    elif command -v brew >/dev/null 2>&1 && brew list netbird >/dev/null 2>&1; then
      echo "Paketquelle: Homebrew"; brew upgrade netbird
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Image}}' 2>/dev/null | grep -q 'netbirdio/netbird'; then
      echo "NetBird läuft als Docker-Container. Bitte Image aktualisieren: docker pull netbirdio/netbird && Container neu erstellen."
      exit 4
    elif command -v netbird >/dev/null 2>&1; then
      echo "Installationsskript (--update)"
      curl -fsSL https://pkgs.netbird.io/install.sh | $S sh -s -- --update
    else
      echo "NetBird ist auf diesem Host nicht installiert."
      exit 3
    fi
    RC=$?
    if [ $RC -eq 0 ]; then
      $S netbird service restart >/dev/null 2>&1 || $S systemctl restart netbird >/dev/null 2>&1 || true
      sleep 5
    fi
    echo "Version nachher: $(netbird version 2>/dev/null || echo unbekannt)"
    netbird status 2>/dev/null | head -n 12
    exit $RC
    """#

    func run(peer: Peer, config: PeerSSHConfig, onHostKey: @escaping (String) -> Void) async {
        log.removeAll()
        errorDetail = nil
        versionBefore = peer.version
        versionAfter = nil
        phase = .connecting
        append("▶︎ Verbinde mit \(config.user)@\(config.host):\(config.port) …")

        // 1. Update losgelöst starten
        do {
            let s = try await SSHSession.connect(host: config.host, port: config.port, user: config.user,
                                                 expectedHostKey: config.hostKey)
            if config.hostKey == nil, let fp = s.hostKeyFingerprint {
                onHostKey(fp)
                append("ℹ︎ Host-Key gespeichert: \(fp)")
            }
            let q = SSHSession.shellQuote(Self.script)
            let start = """
            rm -f \(Self.statusFile)
            printf '%s\\n' \(q) > /var/tmp/netbird-admin-update.sh
            nohup sh -c 'sh /var/tmp/netbird-admin-update.sh > \(Self.logFile) 2>&1; echo $? > \(Self.statusFile)' >/dev/null 2>&1 &
            echo gestartet
            """
            let out = try await s.capture(start)
            await s.close()
            guard out.contains("gestartet") else { throw PeerUpdateError.notStarted(out) }
            phase = .started
            append("✓ Update auf dem Peer gestartet – Verbindung kann kurz abbrechen")
        } catch {
            fail("Update konnte nicht gestartet werden:\n\(error.localizedDescription)")
            return
        }

        // 2. Auf Ergebnis warten (Neustart des Dienstes trennt den Tunnel)
        var lastError: String?
        for attempt in 1...40 {
            phase = .waiting(attempt)
            try? await Task.sleep(for: .seconds(attempt == 1 ? 8 : 5))
            do {
                var cfg = config
                if cfg.hostKey == nil { cfg.hostKey = PeerSSHConfig.load(peer.id)?.hostKey }
                let s = try await SSHSession.connect(host: cfg.host, port: cfg.port, user: cfg.user,
                                                     expectedHostKey: cfg.hostKey, timeout: 6)
                let res = try await s.capture("cat \(Self.statusFile) 2>/dev/null; echo '---LOG---'; cat \(Self.logFile) 2>/dev/null")
                await s.close()
                let parts = res.components(separatedBy: "---LOG---")
                let status = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !status.isEmpty, let code = Int(status) else { continue }   // läuft noch
                let lines = (parts.count > 1 ? parts[1] : "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                lines.filter { !$0.isEmpty }.forEach(append)
                versionAfter = lines.first { $0.hasPrefix("Version nachher:") }.flatMap { ServerUpdater.parseVersion($0) }
                if code == 0 {
                    append("✓ Client aktualisiert – Version \(versionAfter ?? "?")")
                    phase = .done(true)
                } else {
                    let tail = lines.filter { !$0.isEmpty }.suffix(12).joined(separator: "\n")
                    fail("Update auf dem Peer fehlgeschlagen (Exit-Code \(code)).\n\n\(tail)", keepLog: true)
                    phase = .done(false)
                }
                return
            } catch let e as SSHServiceError {
                if case .hostKeyChanged = e { fail(e.localizedDescription); return }
                lastError = e.localizedDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
        fail("Keine Rückmeldung vom Peer innerhalb von 3 Minuten.\nLetzter Fehler: \(lastError ?? "–")\n\nProtokoll auf dem Peer: \(Self.logFile)")
    }

    private func fail(_ msg: String, keepLog: Bool = false) {
        if !keepLog { append("✗ \(msg)") }
        errorDetail = msg
        phase = .failed(msg)
    }

    private func append(_ s: String) { log.append(s) }
}

enum PeerUpdateError: LocalizedError {
    case notStarted(String)
    var errorDescription: String? {
        switch self {
        case .notStarted(let out): return "Unerwartete Antwort: \(out.isEmpty ? "leer" : out)"
        }
    }
}
