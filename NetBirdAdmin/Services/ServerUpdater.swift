import Foundation

/// Prüft die installierte NetBird-Version gegen das offizielle GitHub-Release
/// und führt das Update per SSH (Zertifikat, root) aus.
@MainActor
@Observable
final class ServerUpdater {
    enum Phase: Equatable {
        case idle, checking, ready, updating, done(Bool), failed(String)
    }

    var phase: Phase = .idle
    var latest: GitHubRelease?
    var apiVersion: InstanceVersionInfo?
    var sshVersion: String?
    var dashboardAvailable: String?
    var log: [String] = []
    var hostKeyToTrust: String?

    var localVersion: String? { sshVersion ?? apiVersion?.managementCurrentVersion }

    var updateAvailable: Bool {
        guard let l = SemVer(latest?.tagName), let c = SemVer(localVersion) else {
            return apiVersion?.managementUpdateAvailable ?? false
        }
        return c < l
    }

    // MARK: Check

    func check(profile: ServerProfile, viaSSH: Bool) async {
        phase = .checking
        log.removeAll()
        async let rel = try? GitHubReleases.latest()
        async let api = Self.fetchAPIVersion(profile)
        latest = await rel
        apiVersion = await api
        dashboardAvailable = apiVersion?.dashboardAvailableVersion

        if viaSSH {
            do {
                let s = try await SSHSession.connect(profile: profile)
                defer { Task { await s.close() } }
                if profile.trustedHostKey == nil { hostKeyToTrust = s.hostKeyFingerprint }
                let out = try await s.capture(Self.versionProbe(installDir: profile.installDir))
                sshVersion = Self.parseVersion(out)
                append("Lokale Version (SSH): \(sshVersion ?? "unbekannt")")
            } catch {
                append("SSH-Prüfung fehlgeschlagen: \(error.localizedDescription)")
            }
        }

        if latest == nil && apiVersion == nil {
            phase = .failed("Weder GitHub noch Management-API erreichbar")
        } else {
            phase = .ready
        }
    }

    nonisolated static func fetchAPIVersion(_ profile: ServerProfile) async -> InstanceVersionInfo? {
        guard let a = try? NetBirdAPI(profile: profile) else { return nil }
        return try? await a.versionInfo()
    }

    // MARK: Update

    func runUpdate(profile: ServerProfile) async {
        phase = .updating
        log.removeAll()
        let target = latest?.tagName ?? "latest"
        append("▶︎ Verbinde mit \(profile.sshUser)@\(profile.effectiveSSHHost):\(profile.sshPort) …")
        do {
            let s = try await SSHSession.connect(profile: profile)
            if profile.trustedHostKey == nil { hostKeyToTrust = s.hostKeyFingerprint }
            append("✓ Angemeldet (Host-Key \(s.hostKeyFingerprint ?? "?"))")
            let cmd = Self.updateCommand(profile: profile, targetTag: target)
            append("▶︎ \(cmd.components(separatedBy: "\n").first ?? cmd) …")
            let code = try await s.run(cmd) { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }
            // Version nach dem Update erneut ermitteln
            if let out = try? await s.capture(Self.versionProbe(installDir: profile.installDir)) {
                sshVersion = Self.parseVersion(out)
            }
            await s.close()
            if code == 0 {
                append("✓ Update abgeschlossen – Version jetzt \(sshVersion ?? "?")")
                phase = .done(true)
            } else {
                append("✗ Update fehlgeschlagen (Exit-Code \(code))")
                phase = .done(false)
            }
        } catch {
            append("✗ \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func append(_ line: String) { log.append(line) }

    // MARK: Shell-Snippets

    /// Ermittelt die laufende Management-Version (Docker oder Binary).
    static func versionProbe(installDir: String) -> String {
        let dir = SSHSession.shellQuote(installDir)
        return """
        cd \(dir) 2>/dev/null
        C=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'management|netbird-server' | head -n1)
        if [ -n "$C" ]; then docker exec "$C" /go/bin/netbird-mgmt --version 2>/dev/null || docker exec "$C" /go/bin/netbird-mgmt version 2>/dev/null || docker inspect --format '{{.Config.Image}}' "$C"; \
        elif command -v netbird-mgmt >/dev/null; then netbird-mgmt --version; \
        else netbird version 2>/dev/null; fi
        """
    }

    static func parseVersion(_ s: String) -> String? {
        // sucht die erste x.y.z-Folge
        let pattern = #"v?(\d+\.\d+\.\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func updateCommand(profile: ServerProfile, targetTag: String) -> String {
        switch profile.updateMode {
        case .custom:
            return profile.customUpdateCommand
                .replacingOccurrences(of: "{{version}}", with: targetTag.trimmingCharacters(in: CharacterSet(charactersIn: "v")))
                .replacingOccurrences(of: "{{tag}}", with: targetTag)
        case .dockerCompose:
            let dir = SSHSession.shellQuote(profile.installDir)
            return """
            set -e
            cd \(dir)
            F=$(ls docker-compose.yml docker-compose.yaml compose.yml compose.yaml 2>/dev/null | head -n1)
            [ -n "$F" ] || { echo "Keine Compose-Datei in \(profile.installDir) gefunden"; exit 2; }
            cp "$F" "$F.bak-$(date +%Y%m%d%H%M%S)"
            echo "Sicherung von $F angelegt"
            # Gepinnte netbirdio-Images (außer dashboard) auf das neue Release setzen
            sed -i -E 's#(image:[[:space:]]*"?netbirdio/(management|signal|relay|netbird-server|server|proxy))(:[^"[:space:]]+)?#\\1:\(targetTag.trimmingCharacters(in: CharacterSet(charactersIn: "v")))#' "$F"
            sed -i -E 's#(image:[[:space:]]*"?netbirdio/dashboard)(:[^"[:space:]]+)?#\\1:latest#' "$F"
            if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
            $DC -f "$F" pull
            $DC -f "$F" up -d --remove-orphans
            docker image prune -f >/dev/null 2>&1 || true
            $DC -f "$F" ps
            """
        }
    }
}
