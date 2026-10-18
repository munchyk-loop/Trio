import SwiftUI

@main struct SearchProbeApp: App {
    var body: some Scene { WindowGroup { ProbeTabs() } }
}

struct ProbeTabs: View {
    @State private var tab = 3
    @State private var path = NavigationPath()
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { Text("Home") }.tabItem { Label("Home", systemImage: "house") }.tag(0)
            SettingsSearchNavigationStack(path: $path) { search in ProbeSettings(search: search) }
                .tabItem { Label("Settings", systemImage: "gear") }.tag(3)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

struct ProbeSettings: View {
    @Binding var search: SettingsSearchSession
    @State private var showingModes = false

    var body: some View {
        List {
            if search.isPresented {
                Section { Text(search.query.isEmpty ? "Search Settings" : search.query).accessibilityIdentifier("results") }
            } else {
                Section { Text("Your Profile").accessibilityIdentifier("profile") }
                Section { NavigationLink("Notifications") { Text("Notifications") } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .modifier(SettingsSearchToolbar(session: $search))
        .toolbar {
            if !search.isPresented {
                ToolbarItem(id: "settings.loop-mode", placement: .topBarLeading) {
                    Button { showingModes = true } label: { Image(systemName: "circle") }
                        .accessibilityIdentifier("settings.loop-mode")
                }
            }
        }
        .onDisappear { search.dismiss() }
        .sheet(isPresented: $showingModes) { Text("Loop Mode") }
    }
}
