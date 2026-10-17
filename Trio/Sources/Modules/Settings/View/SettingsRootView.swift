import SwiftUI
import Swinject

extension Settings {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        var body: some View {
            SettingsFlowRootView(resolver: resolver, state: state)
                .onAppear(perform: configureView)
                .screenNavigation(self)
        }
    }
}
