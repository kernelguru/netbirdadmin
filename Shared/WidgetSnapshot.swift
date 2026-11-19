import Foundation
import SwiftUI

/// Momentaufnahme für das Widget. Die App schreibt sie bei jeder Aktualisierung
/// in den gemeinsamen App-Group-Container, das Widget liest sie nur.
struct WidgetSnapshot: Codable {
    struct PeerItem: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var online: Bool
        var ip: String
        var outdated: Bool
    }

    var serverName: String
    var updatedAt: Date
    var peersOnline: Int
    var peersTotal: Int
    var exitNodes: Int
    var exitNodesEnabled: Int
    var servicesActive: Int
    var servicesTotal: Int
    var servicesWithIssues: Int
    var installedVersion: String?
    var latestVersion: String?
    var updateAvailable: Bool
    var outdatedClients: Int
    var ipv6Enabled: Bool
    var peers: [PeerItem]

    private static let fileName = "widget-snapshot.json"

    static func load() -> WidgetSnapshot? {
        guard let d = SharedStore.read(name: fileName) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }

    /// Speichert und liefert die Ablagen, in die erfolgreich geschrieben wurde.
    @discardableResult
    func save() -> [String] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(self) else { return [] }
        let targets = SharedStore.write(d, name: Self.fileName)
        UserDefaults.standard.set(targets, forKey: "widget.lastWriteTargets")
        UserDefaults.standard.set(Date(), forKey: "widget.lastWrite")
        return targets
    }

    static let placeholder = WidgetSnapshot(
        serverName: "NetBird", updatedAt: Date(), peersOnline: 12, peersTotal: 15,
        exitNodes: 2, exitNodesEnabled: 2, servicesActive: 4, servicesTotal: 5, servicesWithIssues: 0,
        installedVersion: "0.60.0", latestVersion: "0.60.1", updateAvailable: true, outdatedClients: 3,
        ipv6Enabled: true,
        peers: [
            .init(id: "1", name: "nas", online: true, ip: "100.92.0.10", outdated: false),
            .init(id: "2", name: "laptop-marc", online: true, ip: "100.92.0.11", outdated: true),
            .init(id: "3", name: "pi-garage", online: false, ip: "100.92.0.12", outdated: false),
            .init(id: "4", name: "exit-fra", online: true, ip: "100.92.0.13", outdated: false),
        ])
}

enum WidgetColors {
    static let orange = Color(red: 0.965, green: 0.514, blue: 0.188)
    static let blue = Color(red: 0.20, green: 0.42, blue: 0.95)
    static let teal = Color(red: 0.10, green: 0.75, blue: 0.70)
    static let online = Color(red: 0.20, green: 0.82, blue: 0.45)
}
