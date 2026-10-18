import SwiftUI
import Swinject

extension Settings {
    struct RootView: BaseView {
        let resolver: Resolver
        var search: Binding<SettingsSearchSession>? = nil
        @State private var localSearch = SettingsSearchSession()
        @StateObject var state = StateModel()

        var body: some View {
            Group {
                if let search {
                    SettingsFlowRootView(resolver: resolver, state: state, search: search)
                } else {
                    // Standalone router presentations still get their own state.
                    SettingsFlowRootView(resolver: resolver, state: state, search: $localSearch)
                }
            }
            .onAppear(perform: configureView)
            .screenNavigation(self)
        }
    }
}
