import Foundation
import Security

/// Datenaustausch App ↔ Widget, unabhängig davon, wie die App signiert wurde.
///
/// Signier-Dienste (AltStore, Sideloadly, KravaSigner, …) benennen App Groups oft um
/// oder nutzen Wildcard-Profile ganz ohne App Groups. Daher:
/// 1. App Groups aus dem eingebetteten Provisioning-Profil (App und Widget) + fester Name,
///    sofern der Prozess tatsächlich Zugriff hat → Datei im Group-Container.
/// 2. Gemeinsame Keychain-Gruppe (z. B. `TEAMID.*` aus Wildcard-Profilen) → Keychain-Eintrag.
enum SharedStore {
    static let fixedGroup = "group.de.kernelguru.netbirdadmin"
    static let keychainSuffix = "de.kernelguru.netbirdadmin.shared"
    static let keychainService = "de.kernelguru.netbirdadmin.widget"

    // MARK: Provisioning-Profile

    static func entitlements(ofProfileAt url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }

    /// Profile dieses Prozesses und (aus Sicht der App) der eingebetteten Widget-Erweiterung.
    static var profileEntitlements: [[String: Any]] {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") { urls.append(u) }
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            for appex in items where appex.pathExtension == "appex" {
                urls.append(appex.appendingPathComponent("embedded.mobileprovision"))
            }
        }
        // Aus Sicht des Widgets: Profil der Haupt-App (zwei Ebenen über dem .appex)
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if Bundle.main.bundleURL.pathExtension == "appex" {
            urls.append(appURL.appendingPathComponent("embedded.mobileprovision"))
        }
        return urls.compactMap(entitlements(ofProfileAt:))
    }

    static var candidateGroups: [String] {
        var groups: [String] = []
        for e in profileEntitlements {
            for g in (e["com.apple.security.application-groups"] as? [String]) ?? [] where !g.contains("*") && !groups.contains(g) {
                groups.append(g)
            }
        }
        if !groups.contains(fixedGroup) { groups.append(fixedGroup) }
        return groups
    }

    /// App Groups, auf die dieser Prozess wirklich zugreifen darf.
    static var accessibleGroups: [String] {
        candidateGroups.filter { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }

    static var keychainGroups: [String] {
        var out: [String] = []
        for e in profileEntitlements {
            for g in (e["keychain-access-groups"] as? [String]) ?? [] {
                let resolved = g.hasSuffix("*") ? String(g.dropLast()) + keychainSuffix : g
                if !out.contains(resolved) { out.append(resolved) }
            }
            if let team = e["com.apple.developer.team-identifier"] as? String {
                let g = "\(team).\(keychainSuffix)"
                if !out.contains(g) { out.append(g) }
            }
        }
        return out
    }

    // MARK: Lesen / Schreiben

    @discardableResult
    static func write(_ data: Data, name: String) -> [String] {
        var ok: [String] = []
        for g in accessibleGroups {
            if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g),
               (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                ok.append("App Group \(g)")
            }
        }
        for g in keychainGroups where keychainWrite(data, account: name, group: g) {
            ok.append("Keychain \(g)")
        }
        return ok
    }

    static func read(name: String) -> Data? {
        var best: (Date, Data)?
        for g in accessibleGroups {
            guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else { continue }
            let url = dir.appendingPathComponent(name)
            if let d = try? Data(contentsOf: url) {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || m > best!.0 { best = (m, d) }
            }
        }
        if let best { return best.1 }
        for g in keychainGroups {
            if let d = keychainRead(account: name, group: g) { return d }
        }
        return nil
    }

    private static func keychainWrite(_ data: Data, account: String, group: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func keychainRead(account: String, group: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Diagnose für die Einstellungen.
    static var diagnostics: [String] {
        var lines: [String] = []
        lines.append("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("Profile gefunden: \(profileEntitlements.count)")
        let cand = candidateGroups, acc = Set(accessibleGroups)
        for g in cand { lines.append("\(acc.contains(g) ? "✓" : "✗") App Group \(g)") }
        let kg = keychainGroups
        if kg.isEmpty { lines.append("✗ keine Keychain-Gruppe im Profil") }
        for g in kg { lines.append("• Keychain-Gruppe \(g)") }
        return lines
    }
}
