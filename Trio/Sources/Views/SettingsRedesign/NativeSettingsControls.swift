import SwiftUI
import Swinject

/// Use the same background and card color as the rest of Trio.
struct SettingsBackground: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
    }
}

extension View {
    func settingsBackground() -> some View { modifier(SettingsBackground()) }
}

enum SettingsValuePresentation {
    case navigation
    case menu
    case wheel
}

struct SettingsHelpFooter: View {
    let title: String
    let text: String
    var detail: String? = nil
    @State private var showingHelp = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(LocalizedStringKey(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button { showingHelp = true } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("More information about \(title)"))
        }
        .sheet(isPresented: $showingHelp) {
            SettingsHelpSheet(title: title, text: detail ?? text)
        }
    }
}

struct SettingsHelpSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(LocalizedStringKey(text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .listRowBackground(Color.chart)
            }
            .settingsBackground()
            .navigationTitle(LocalizedStringKey(title))
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

struct SettingsNumberRow: View {
    let title: String
    @Binding var value: Decimal
    var spec: PickerSetting
    var units: GlucoseUnits = .mgdL
    var suffix: String? = nil
    var includeOff = false
    var displayTransform: (Decimal) -> Decimal = { $0 }
    var presentation: SettingsValuePresentation = .navigation
    var description: String = ""
    @State private var showingWheel = false

    private var values: [Decimal] {
        var values = PickerSettingsProvider.shared.generatePickerValues(from: spec, units: units)
        if includeOff, !values.contains(0) { values.insert(0, at: 0) }
        if !values.contains(value) { values.append(value)
            values.sort() }
        return values
    }

    private func formatted(_ value: Decimal) -> String {
        if includeOff, value == 0 { return String(localized: "Off") }
        let displayed = displayTransform(value)
        let number: Decimal
        let unit: String
        if let suffix {
            number = displayed
            unit = suffix
        } else {
            switch spec.type {
            case .factor: number = displayed * 100
                unit = "%"
            case .glucose: number = units == .mmolL ? displayed.asMmolL : displayed
                unit = units.rawValue
            case .insulinUnit: number = displayed
                unit = "U"
            case .insulinUnitPerHour: number = displayed
                unit = "U/hr"
            case .gram: number = displayed
                unit = "g"
            case .minute: number = displayed
                unit = "min"
            case .hour: number = displayed
                unit = "hr"
            }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = spec.type == .glucose && units == .mmolL ? 1 : 3
        return "\(formatter.string(from: number as NSDecimalNumber) ?? number.description) \(unit)"
    }

    @ViewBuilder var body: some View {
        switch presentation {
        case .navigation:
            NavigationLink {
                detailView
            } label: {
                LabeledContent(LocalizedStringKey(title)) { Text(formatted(value)) }
            }
        case .menu:
            picker.pickerStyle(.menu)
        case .wheel:
            Button { showingWheel = true } label: {
                LabeledContent(LocalizedStringKey(title)) {
                    Text(formatted(value)).foregroundStyle(Color.accentColor)
                }
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showingWheel) {
                NavigationStack {
                    wheelContent
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
    }

    var detailView: some View {
        Form {
            Section {
                SettingsNumberRow(
                    title: title, value: $value, spec: spec, units: units, suffix: suffix,
                    includeOff: includeOff, displayTransform: displayTransform, presentation: .wheel
                )
            } footer: {
                Text(LocalizedStringKey(settingDescription))
            }
            .listRowBackground(Color.chart)
        }
        .settingsBackground()
        .navigationTitle(LocalizedStringKey(title))
        .navigationBarTitleDisplayMode(.inline)
    }

    var wheelContent: some View {
        Form {
            Section { picker.pickerStyle(.wheel).labelsHidden() }
                .listRowBackground(Color.chart)
        }
        .settingsBackground()
        .navigationTitle(LocalizedStringKey(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { showingWheel = false } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("Done")
            }
        }
    }

    private var settingDescription: String {
        if !description.isEmpty { return description }
        switch title {
        case "Safety Threshold": return "Below this glucose threshold, Trio suspends automated insulin delivery to help prevent low glucose."
        case "Basal Rate": return "Set the maximum basal delivery rate permitted by your pump."
        case "Bolus": return "Set the maximum amount of insulin permitted in one bolus."
        case "Insulin on Board (IOB)": return "Limit the active insulin Trio can add through automated dosing."
        case "Auto Bolus": return "Limit an Auto Bolus to this many minutes of your scheduled basal insulin."
        case "Auto Bolus - UAM": return "Limit Auto Boluses for unannounced meals to this many minutes of scheduled basal insulin."
        case "ISF Strength Increase": return "Set how much Trio may increase your ISF strength relative to your therapy setting."
        case "ISF Strength Decrease": return "Set how much Trio may decrease your ISF strength relative to your therapy setting."
        case "Carb Entry": return "Set the maximum carbohydrate amount allowed in a single entry."
        case "Carbs on Board (COB)": return "Set the maximum amount of active carbohydrates included in Trio's calculations."
        case "Maximum Scheduled Basal Multiplier": return "Limit temporary basal delivery relative to the highest rate in your basal schedule."
        case "Current Scheduled Basal Multiplier": return "Limit temporary basal delivery relative to the current rate in your basal schedule."
        default: return "Choose the value for this setting."
        }
    }

    private var picker: some View {
        Picker(LocalizedStringKey(title), selection: $value) {
            ForEach(values, id: \.self) { value in
                Text(formatted(value)).tag(value)
            }
        }
    }
}

struct SettingsPlaceholderLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
        }
    }
}

/// Resolve a destination only after navigation presents it, outside the parent form's stack frame.
struct SettingsScreenDestination: View {
    let screen: Screen
    let resolver: Resolver

    var body: some View {
        resolver.resolve(Router.self)!.view(for: screen)
    }
}

/// Reuse the device lifecycle and driver sheets while placing app-owned controls
/// in the same page as the connected-device card.
struct SettingsConnectedDeviceView: View {
    let page: SettingsFlowPage
    @ObservedObject var model: SettingsFlowModel

    var body: some View {
        if page == .cgm {
            CGMSettings.RootView(
                resolver: model.resolver, displayClose: false,
                bluetoothManager: model.resolver.resolve(BluetoothStateManager.self)!,
                settingsFlowModel: model
            )
        } else {
            PumpConfig.RootView(
                resolver: model.resolver, displayClose: false,
                bluetoothManager: model.resolver.resolve(BluetoothStateManager.self)!,
                settingsFlowModel: model
            )
        }
    }
}
