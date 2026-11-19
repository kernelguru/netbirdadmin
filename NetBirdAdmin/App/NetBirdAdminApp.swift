import SwiftUI
import BackgroundTasks

@main
struct NetBirdAdminApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.nbOrange)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}

/// Aktualisiert im Hintergrund die Daten für das Widget.
enum BackgroundRefresh {
    static let identifier = "de.kernelguru.netbirdadmin.refresh"

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    @MainActor
    static func run() async {
        schedule()
        let store = AppStore()
        await store.refreshAll()
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Übersicht", systemImage: "gauge.with.dots.needle.67percent") }
            ClientsView()
                .tabItem { Label("Clients", systemImage: "laptopcomputer.and.iphone") }
            ReverseProxyView()
                .tabItem { Label("Proxy", systemImage: "arrow.triangle.branch") }
            NetworkView()
                .tabItem { Label("Netzwerk", systemImage: "point.3.connected.trianglepath.dotted") }
            ServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
        }
        .errorBanner(Binding(get: { store.lastError }, set: { store.lastError = $0 }))
        .task {
            if store.profiles.isEmpty { showOnboarding = true }
            else { await store.refreshAll() }
        }
        .sheet(isPresented: $showOnboarding) {
            NavigationStack {
                ServerProfileEditView(profile: ServerProfile(), isNew: true)
            }
            .interactiveDismissDisabled(store.profiles.isEmpty)
        }
    }
}
