import LoopKitUI
import SwiftUI
import UIKit

extension PumpConfig {
    struct PumpSettingsView: UIViewControllerRepresentable {
        let pumpManager: PumpManagerUI
        let bluetoothManager: BluetoothStateManager
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: PumpManagerOnboardingDelegate?

        final class Coordinator {
            var holdsLease = false
            func releaseLease() {
                guard holdsLease else { return }
                holdsLease = false
                TrioBackupOperationGate.shared.endOperation()
            }
            deinit { releaseLease() }
        }
        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIViewController(context: UIViewControllerRepresentableContext<PumpSettingsView>) -> UIViewController {
            guard TrioBackupOperationGate.shared.beginOperation() else {
                return UIHostingController(rootView: PumpRestoreRecoveryView())
            }
            context.coordinator.holdsLease = true
            var vc = pumpManager.settingsViewController(
                bluetoothProvider: bluetoothManager,
                pumpManagerOnboardingDelegate: setupDelegate
            )
            vc.completionDelegate = completionDelegate
            return vc
        }

        static func dismantleUIViewController(_: UIViewController, coordinator: Coordinator) {
            coordinator.releaseLease()
        }

        func updateUIViewController(_: UIViewController, context _: UIViewControllerRepresentableContext<PumpSettingsView>) {}
    }
}


struct PumpRestoreRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 20) {
            Text("Pump Settings Recovery").font(.title2).bold()
            Text("An interrupted settings restore must finish reconciling the pump’s settings before pump controls or dosing can be used. Trio remains in Open Loop. Recovery verifies suspension and never resumes delivery.")
            if let error { Text(error).foregroundStyle(.secondary) }
            Button("Retry Recovery") {
                guard !busy else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { try await TrioCloudBackupCoordinator.shared.reconcilePendingPumpRestore(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.disabled(busy)
            Button("Close") { dismiss() }.disabled(busy)
        }.padding()
    }
}
