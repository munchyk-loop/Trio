import SwiftUI

struct TempTargetHelpView: View {
    var state: Adjustments.StateModel
    var helpSheetDetent: Binding<PresentationDetent>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A Temporary Target replaces your scheduled glucose target for the selected duration.")
                    Text(
                        "Temporary Targets do not independently change insulin sensitivity or Auto Bolus eligibility. Use an Override to change those behaviors."
                    )
                }
            }
            .navigationTitle("Temporary Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
