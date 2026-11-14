import Foundation
import Crypto
import NIOSSH
import Citadel

/// Verwaltet den SSH-Client-Schlüssel und das zugehörige OpenSSH-Zertifikat.
///
/// Ablauf:
/// 1. App erzeugt ein Ed25519-Schlüsselpaar (privater Schlüssel bleibt in der Keychain).
/// 2. Den Public Key auf dem Server mit der SSH-CA signieren:
///    `ssh-keygen -s /etc/ssh/netbird_admin_ca -I ios-admin -n netbird-admin -V +52w ios.pub`
/// 3. Das erzeugte `ios-cert.pub` in die App importieren.
/// 4. sshd vertraut der CA (`TrustedUserCAKeys`) und erlaubt dem Principal `netbird-admin`
///    den Login als root (`AuthorizedPrincipalsFile`).
enum SSHKeyManager {
    private static let keyTag = "ssh-ed25519-private"
    private static let certTag = "ssh-user-cert"

    enum KeyError: LocalizedError {
        case noKey, invalidCert(String), certMismatch, unsupportedKey
        var errorDescription: String? {
            switch self {
            case .noKey: return "Kein SSH-Schlüssel vorhanden"
            case .invalidCert(let m): return "Ungültiges Zertifikat: \(m)"
            case .certMismatch: return "Das Zertifikat gehört nicht zum Schlüssel dieser App"
            case .unsupportedKey: return "Nur unverschlüsselte OpenSSH Ed25519-Schlüssel werden unterstützt"
            }
        }
    }

    // MARK: Key

    static var privateKey: Curve25519.Signing.PrivateKey? {
        guard let raw = KeychainStore.data(for: keyTag) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    static var hasKey: Bool { privateKey != nil }

    @discardableResult
    static func generateKey() -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        KeychainStore.set(key.rawRepresentation, for: keyTag)
        KeychainStore.delete(certTag) // altes Zertifikat passt nicht mehr
        return key
    }

    /// Import eines vorhandenen OpenSSH-Ed25519-Schlüssels (-----BEGIN OPENSSH PRIVATE KEY-----)
    static func importKey(openSSH: String, passphrase: String?) throws {
        let pw = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        guard let key = try? Curve25519.Signing.PrivateKey(sshEd25519: openSSH, decryptionKey: pw) else {
            throw KeyError.unsupportedKey
        }
        KeychainStore.set(key.rawRepresentation, for: keyTag)
        KeychainStore.delete(certTag)
    }

    static func deleteAll() {
        KeychainStore.delete(keyTag)
        KeychainStore.delete(certTag)
    }

    /// Public Key im OpenSSH-Format (`ssh-ed25519 AAAA... netbird-admin-ios`)
    static var publicKeyOpenSSH: String? {
        guard let key = privateKey else { return nil }
        let pub = NIOSSHPrivateKey(ed25519Key: key).publicKey
        return String(openSSHPublicKey: pub) + " netbird-admin-ios"
    }

    // MARK: Certificate

    static var certificateString: String? { KeychainStore.string(for: certTag) }

    static var certificate: NIOSSHCertifiedPublicKey? {
        guard let s = certificateString,
              let pub = try? NIOSSHPublicKey(openSSHPublicKey: s) else { return nil }
        return NIOSSHCertifiedPublicKey(pub)
    }

    static func importCertificate(_ text: String) throws {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pub: NIOSSHPublicKey
        do { pub = try NIOSSHPublicKey(openSSHPublicKey: line) }
        catch { throw KeyError.invalidCert(String(describing: error)) }
        guard let cert = NIOSSHCertifiedPublicKey(pub) else { throw KeyError.invalidCert("Kein *-cert-v01@openssh.com Schlüssel") }
        guard let key = privateKey else { throw KeyError.noKey }
        guard cert.key == NIOSSHPrivateKey(ed25519Key: key).publicKey else { throw KeyError.certMismatch }
        KeychainStore.setString(line, for: certTag)
    }

    static func removeCertificate() { KeychainStore.delete(certTag) }

    struct CertInfo {
        var keyID: String
        var principals: [String]
        var validAfter: Date
        var validBefore: Date?
        var serial: UInt64
        var extensions: [String]
        var isValidNow: Bool {
            let now = Date()
            return now >= validAfter && (validBefore.map { now < $0 } ?? true)
        }
    }

    static var certInfo: CertInfo? {
        guard let c = certificate else { return nil }
        let before: Date? = c.validBefore == UInt64.max ? nil : Date(timeIntervalSince1970: TimeInterval(c.validBefore))
        return CertInfo(keyID: c.keyID,
                        principals: c.validPrincipals,
                        validAfter: Date(timeIntervalSince1970: TimeInterval(c.validAfter)),
                        validBefore: before,
                        serial: c.serial,
                        extensions: c.extensions.keys.sorted())
    }

    /// Befehl, den man auf dem Server (bzw. dort wo die CA liegt) ausführt.
    static func signCommand(principal: String = "netbird-admin", validity: String = "+52w") -> String {
        """
        cat > /tmp/netbird-ios.pub <<'KEY'
        \(publicKeyOpenSSH ?? "<public key>")
        KEY
        ssh-keygen -s /etc/ssh/netbird_admin_ca -I netbird-admin-ios -n \(principal) -V \(validity) /tmp/netbird-ios.pub
        cat /tmp/netbird-ios-cert.pub
        """
    }
}
