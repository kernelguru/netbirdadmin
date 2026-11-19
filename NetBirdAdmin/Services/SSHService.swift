import Foundation
import Crypto
import NIOCore
import NIOSSH
import Citadel

enum SSHServiceError: LocalizedError {
    case noKey
    case hostKeyChanged(expected: String, got: String)
    case authFailed
    case commandFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Kein SSH-Schlüssel/Zertifikat konfiguriert (Einstellungen → SSH)"
        case .hostKeyChanged(let e, let g): return "Host-Key hat sich geändert!\nErwartet: \(e)\nErhalten: \(g)"
        case .authFailed: return "SSH-Authentifizierung fehlgeschlagen – Zertifikat/Principal prüfen"
        case .commandFailed(let c): return "Befehl mit Exit-Code \(c) beendet"
        }
    }
}

/// Authentifiziert mit Ed25519-Schlüssel + OpenSSH-User-Zertifikat (falls vorhanden),
/// sonst mit dem reinen Public Key.
final class CertificateAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]

    init(username: String, key: Curve25519.Signing.PrivateKey, certificate: NIOSSHCertifiedPublicKey?) {
        self.username = username
        let nioKey = NIOSSHPrivateKey(ed25519Key: key)
        var o: [NIOSSHUserAuthenticationOffer.Offer] = []
        if let certificate {
            o.append(.privateKey(.init(privateKey: nioKey, certifiedKey: certificate)))
        }
        o.append(.privateKey(.init(privateKey: nioKey)))
        self.offers = o
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !offers.isEmpty else {
            nextChallengePromise.succeed(nil)
            return
        }
        let offer = offers.removeFirst()
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
    }
}

/// Trust-on-first-use Host-Key-Prüfung über SHA256-Fingerprint.
final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let expected: String?
    private(set) var seen: String?

    init(expected: String?) { self.expected = expected }

    static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let parts = String(openSSHPublicKey: key).split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = SHA256.hash(data: blob)
        var b64 = Data(digest).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = Self.fingerprint(hostKey)
        seen = fp
        if let expected, expected != fp {
            validationCompletePromise.fail(SSHServiceError.hostKeyChanged(expected: expected, got: fp))
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

/// Eine SSH-Sitzung zu einem Server-Profil.
final class SSHSession {
    let client: SSHClient
    let hostKeyFingerprint: String?

    private init(client: SSHClient, fingerprint: String?) {
        self.client = client
        self.hostKeyFingerprint = fingerprint
    }

    static func connect(profile: ServerProfile) async throws -> SSHSession {
        try await connect(host: profile.effectiveSSHHost, port: profile.sshPort,
                          user: profile.sshUser, expectedHostKey: profile.trustedHostKey)
    }

    static func connect(host: String, port: Int, user: String, expectedHostKey: String?,
                        timeout: Int64 = 15) async throws -> SSHSession {
        guard let key = SSHKeyManager.privateKey else { throw SSHServiceError.noKey }
        let auth = CertificateAuthDelegate(username: user, key: key, certificate: SSHKeyManager.certificate)
        let hostDelegate = TOFUHostKeyDelegate(expected: expectedHostKey)
        do {
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .custom(auth),
                hostKeyValidator: .custom(hostDelegate),
                reconnect: .never,
                connectTimeout: .seconds(timeout)
            )
            return SSHSession(client: client, fingerprint: hostDelegate.seen)
        } catch let e as SSHServiceError {
            throw e
        } catch {
            if "\(error)".localizedCaseInsensitiveContains("auth") { throw SSHServiceError.authFailed }
            throw error
        }
    }

    /// Führt einen Befehl aus und liefert die Ausgabe (stdout+stderr) zeilenweise.
    /// Der Exit-Code wird über eine Markerzeile ermittelt, damit auch Fehler-Ausgaben
    /// vollständig ankommen.
    func run(_ command: String, onOutput: @escaping (String) -> Void) async throws -> Int {
        let marker = "__NBADMIN_EXIT__"
        let wrapped = "( \(command)\n) 2>&1; echo \"\(marker)$?\""
        let stream = try await client.executeCommandStream("sh -c \(Self.shellQuote(wrapped))")
        var exitCode = 0
        var pending = ""
        for try await chunk in stream {
            let buffer: ByteBuffer
            switch chunk {
            case .stdout(let b): buffer = b
            case .stderr(let b): buffer = b
            }
            pending += String(buffer: buffer)
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                if line.hasPrefix(marker) {
                    exitCode = Int(line.dropFirst(marker.count)) ?? -1
                } else {
                    onOutput(line)
                }
            }
        }
        if !pending.isEmpty {
            if pending.hasPrefix(marker) { exitCode = Int(pending.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1 }
            else { onOutput(pending) }
        }
        return exitCode
    }

    /// Kurzer Befehl, gesamte Ausgabe als String.
    func capture(_ command: String) async throws -> String {
        var lines: [String] = []
        _ = try await run(command) { lines.append($0) }
        return lines.joined(separator: "\n")
    }

    func close() async { try? await client.close() }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
