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

    static let appGroup = "group.de.kernelguru.netbirdadmin"
    private static let key = "widgetSnapshot"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let d = defaults?.data(forKey: key) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(self) { Self.defaults?.set(d, forKey: Self.key) }
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
