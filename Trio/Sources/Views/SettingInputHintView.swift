import SwiftUI

struct SettingInputHintView<HintView: View>: View {
    @Binding var hintDetent: PresentationDetent
    @Binding var shouldDisplayHint: Bool
    var hintLabel: String
    var hintText: HintView
    var sheetTitle: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DefinitionRow(term: hintLabel, definition: hintText, fontSize: .body)
                        .padding(.vertical, 8)
                }
                .listRowBackground(Color.chart)
            }
            .settingsBackground()
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { shouldDisplayHint = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
