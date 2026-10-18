import SwiftUI

@main struct SearchProbeApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { StandaloneSettingsSearch() }
                .onAppear { print("[SettingsSearch] implementation=top-toolbar-glass-1") }
        }
    }
}

struct StandaloneSettingsSearch: View {
    @State private var search = SettingsSearchSession()
    var body: some View { ProbeSettings(search: $search) }
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
// The presentation value owns results; keyboard focus never opens search.
struct SettingsSearchSession: Equatable {
    private(set) var query = ""
    private(set) var isPresented = false

    mutating func present() {
        guard !isPresented else { return }
        query = ""
        isPresented = true
    }

    mutating func updateQuery(_ value: String) {
        // Ignore a departing text field's write after Close or navigation.
        guard isPresented else { return }
        query = value
    }

    mutating func dismiss(reason: String = "App action") {
        #if DEBUG
            print("[SettingsSearch] dismiss: \(reason) queryLength=\(query.count)")
        #endif
        self = Self()
    }
}

struct SettingsSearchNavigationStack<Content: View>: View {
    @Binding var path: NavigationPath
    @State private var search = SettingsSearchSession()
    @ViewBuilder var content: (Binding<SettingsSearchSession>) -> Content

    var body: some View {
        NavigationStack(path: $path) { content($search) }
            .onDisappear { search.dismiss(reason: "Settings navigation scope disappeared") }
    }
}

/// A screen-local toolbar, rather than an adaptive searchable provider.
/// Its field can only appear in the top bar. All close paths clear the same state.
struct SettingsSearchToolbar: ViewModifier {
    @Binding var session: SettingsSearchSession
    @State private var availableWidth: CGFloat = 280

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(180, proxy.size.width - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing - 32)
            } action: { availableWidth = $0 }
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(id: "settings.search", placement: .topBarTrailing) {
                        SettingsToolbarSearch(session: $session, availableWidth: availableWidth)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(id: "settings.search", placement: .topBarTrailing) {
                        SettingsToolbarSearch(session: $session, availableWidth: availableWidth)
                    }
                }
            }
    }
}

/// Standard SwiftUI input and buttons, with the system's Liquid Glass morph.
/// Loop Mode deliberately belongs to a different toolbar item and glass scope.
struct SettingsToolbarSearch: View {
    @Binding var session: SettingsSearchSession
    let availableWidth: CGFloat
    @FocusState private var focused: Bool
    @Namespace private var searchGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: Binding<String> {
        Binding(get: { session.query }, set: { session.updateQuery($0) })
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) { controls }
            } else {
                controls
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onChange(of: session.isPresented) { _, presented in
            if !presented { focused = false }
        }
        .onDisappear {
            focused = false
            session.dismiss(reason: "Search toolbar disappeared")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if session.isPresented {
                field
                    .frame(width: max(128, availableWidth - 52))
                    .modifier(SettingsSearchGlass(id: "field", namespace: searchGlass))

                actionButton("Close Search", image: "xmark", id: "settings.search.close") {
                    focused = false
                    transition { session.dismiss(reason: "Close button") }
                }
                .modifier(SettingsSearchGlass(id: "close", namespace: searchGlass, interactive: true))
            } else {
                actionButton("Search Settings", image: "magnifyingglass", id: "settings.search.open") {
                    transition { session.present() }
                }
                .modifier(SettingsSearchGlass(id: "field", namespace: searchGlass, interactive: true))
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Settings", text: query)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { focused = false }
                .accessibilityIdentifier("settings.search.field")
            if !session.query.isEmpty {
                Button {
                    session.updateQuery("")
                    focused = true
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                    .accessibilityIdentifier("settings.search.clear")
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .disabled(!session.isPresented)
        .onAppear {
            // Focus on insertion, without a timer or animation-completion callback.
            focused = session.isPresented
        }
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        image: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(id)
    }

    private func transition(_ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation { update() }
        }
    }
}

private struct SettingsSearchGlass: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    var interactive = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(interactive), in: Capsule())
                .glassEffectID(id, in: namespace)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
