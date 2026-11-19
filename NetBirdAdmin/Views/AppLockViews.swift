import SwiftUI
import LocalAuthentication

/// App-Sperre per Face ID / Touch ID / Gerätecode.
struct AppLockModifier: ViewModifier {
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @State private var hidden = false
    @State private var authenticating = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if lockEnabled && (locked || hidden) {
                    LockScreen(locked: locked, authenticating: authenticating) { Task { await unlock() } }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: locked)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: if lockEnabled { locked = true }
                case .inactive: hidden = true
                case .active:
                    hidden = false
                    if lockEnabled && locked { Task { await unlock() } }
                @unknown default: break
                }
            }
            .task { if lockEnabled && locked { await unlock() } }
    }

    @MainActor
    private func unlock() async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            locked = false   // kein Code gesetzt → Sperre nicht möglich
            return
        }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "NetBird Admin entsperren")) == true {
            locked = false
        }
    }
}

private struct LockScreen: View {
    let locked: Bool
    let authenticating: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            GlassBackground()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 44)).foregroundStyle(.white)
                    .frame(width: 92, height: 92)
                    .background(Color.nbOrange.gradient, in: RoundedRectangle(cornerRadius: 24))
                Text("NetBird Admin").font(.title2.bold())
                if locked {
                    Button(action: unlock) {
                        Label("Entsperren", systemImage: biometryIcon)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .frame(maxWidth: 240)
                    .disabled(authenticating)
                }
            }
        }
    }

    private var biometryIcon: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open"
        }
    }
}

extension View {
    func appLock() -> some View { modifier(AppLockModifier()) }
}

/// Einstellungen: App-Sperre und Benachrichtigungen.
struct AppSettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @State private var offline = Notifier.offlineEnabled
    @State private var online = Notifier.backOnlineEnabled
    @State private var release = Notifier.releaseEnabled
    @State private var groups = Notifier.watchedGroups
    @State private var permissionDenied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $lockEnabled) { Label("Mit Face ID sperren", systemImage: "faceid") }
            } footer: { Text("Beim Öffnen und nach dem Wechsel in den Hintergrund ist Face ID, Touch ID oder der Gerätecode nötig.") }

            Section {
                Toggle("Peer geht offline", isOn: $offline)
                Toggle("Peer wieder online", isOn: $online)
                Toggle("Neue NetBird-Version", isOn: $release)
                if permissionDenied {
                    Label("Mitteilungen sind in den iOS-Einstellungen deaktiviert.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: { Text("Benachrichtigungen") } footer: {
                Text("Geprüft wird beim Öffnen der App und per Hintergrund-Aktualisierung (iOS entscheidet über die Häufigkeit, typischerweise alle 15–60 Minuten).")
            }

            Section {
                GroupPicker(selection: $groups, excludeAll: true, allowCreate: false)
            } header: { Text("Nur diese Gruppen überwachen") } footer: { Text("Leer = alle Peers (ephemere Peers werden ignoriert).") }
        }
        .glassScreen()
        .navigationTitle("App-Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: offline) { _, v in Notifier.offlineEnabled = v; if v { Task { await ask() } } }
        .onChange(of: online) { _, v in Notifier.backOnlineEnabled = v; if v { Task { await ask() } } }
        .onChange(of: release) { _, v in Notifier.releaseEnabled = v; if v { Task { await ask() } } }
        .onChange(of: groups) { _, v in Notifier.watchedGroups = v }
    }

    private func ask() async {
        permissionDenied = !(await Notifier.requestPermission())
    }
}
