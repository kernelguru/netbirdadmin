import Foundation
import UserNotifications

/// Lokale Benachrichtigungen: Peers offline gegangen, neue NetBird-Version.
/// Wird nach jeder Aktualisierung aufgerufen (Vordergrund und Hintergrund-Refresh).
enum Notifier {
    private static let d = UserDefaults.standard

    static var offlineEnabled: Bool {
        get { d.bool(forKey: "notify.offline") }
        set { d.set(newValue, forKey: "notify.offline") }
    }
    static var backOnlineEnabled: Bool {
        get { d.bool(forKey: "notify.online") }
        set { d.set(newValue, forKey: "notify.online") }
    }
    static var releaseEnabled: Bool {
        get { d.bool(forKey: "notify.release") }
        set { d.set(newValue, forKey: "notify.release") }
    }
    /// Nur Peers dieser Gruppen überwachen (leer = alle)
    static var watchedGroups: [String] {
        get { d.stringArray(forKey: "notify.groups") ?? [] }
        set { d.set(newValue, forKey: "notify.groups") }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func evaluate(store: AppStore) {
        guard let server = store.current, store.lastError == nil, !store.peers.isEmpty else { return }
        let key = "notify.online.\(server.id.uuidString)"
        let watched = Set(watchedGroups)
        let relevant = store.peers.filter { p in
            p.ephemeral != true && (watched.isEmpty || p.groups.contains { watched.contains($0.id) })
        }
        let nowOnline = Set(relevant.filter(\.connected).map(\.id))
        let known = Set(relevant.map(\.id))

        if let prevList = d.stringArray(forKey: key) {
            let prev = Set(prevList)
            if offlineEnabled {
                let gone = prev.intersection(known).subtracting(nowOnline)
                let names = relevant.filter { gone.contains($0.id) }.map(\.name).sorted()
                if !names.isEmpty {
                    post(id: "offline-\(server.id)-\(names.joined())",
                         title: names.count == 1 ? "\(names[0]) ist offline" : "\(names.count) Peers offline",
                         body: names.count == 1 ? "Server: \(server.name)" : names.joined(separator: ", "))
                }
            }
            if backOnlineEnabled {
                let back = nowOnline.subtracting(prev)
                let names = relevant.filter { back.contains($0.id) }.map(\.name).sorted()
                if !names.isEmpty {
                    post(id: "online-\(server.id)-\(names.joined())",
                         title: names.count == 1 ? "\(names[0]) ist wieder online" : "\(names.count) Peers wieder online",
                         body: names.joined(separator: ", "))
                }
            }
        }
        d.set(Array(nowOnline), forKey: key)

        if releaseEnabled, let tag = store.latestRelease?.tagName {
            let relKey = "notify.release.\(server.id.uuidString)"
            let installed = store.versionInfo?.managementCurrentVersion
            let newer = SemVer(installed).flatMap { i in SemVer(tag).map { i < $0 } } ?? false
            if newer && d.string(forKey: relKey) != tag {
                post(id: "release-\(tag)", title: "NetBird \(tag) verfügbar",
                     body: "\(server.name) läuft mit \(installed ?? "?"). Update in der App unter Server → Server-Update.")
                d.set(tag, forKey: relKey)
            }
        }
    }

    private static func post(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
