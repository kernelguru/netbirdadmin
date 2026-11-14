import SwiftUI

@main
struct NetBirdAdminApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.nbOrange)
        }
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
