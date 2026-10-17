import ImageIO
import SwiftUI
import Swinject
import UIKit

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

struct SettingsLoopModeSymbol: View {
    let mode: DosingMode
    var size: CGFloat = 28

    var body: some View {
        Group {
            if mode == .open {
                Image("SettingsOpenLoop").renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: mode == .closed ? "circle" : "circle.dashed")
                    .font(.system(size: size, weight: .black))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension DosingMode {
    var settingsColor: Color {
        switch self {
        case .closed: return .green
        case .basalTesting,
             .lowGlucoseSuspend: return .yellow
        case .open: return .red
        }
    }

    var settingsExplanation: String {
        switch self {
        case .closed:
            return String(
                localized: "Full Automation: Trio will reduce or pause basal delivery to help prevent low glucose and increase insulin delivery to correct high glucose."
            )
        case .basalTesting,
             .lowGlucoseSuspend:
            return String(
                localized: "Safety-Only Automation: Trio will reduce or pause basal delivery to help prevent low glucose. Trio won’t increase insulin delivery to correct high glucose.* Your pump will only deliver your set basal rates and manual boluses.\n\n*When appropriate, Trio may make up for insulin withheld during reduced or paused basal delivery. It will never make up for more than the amount withheld."
            )
        case .open:
            return String(
                localized: "No Automation: Trio won’t adjust any insulin delivery, even to help prevent low glucose. Your pump will only deliver your set basal rates and manual boluses."
            )
        }
    }
}

struct SettingsLoopModeSheet: View {
    @Binding var selection: DosingMode
    let canSelect: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ForEach(DosingMode.userSelectable) { mode in
                            Button { selection = mode } label: {
                                VStack(spacing: 12) {
                                    SettingsLoopModeSymbol(mode: mode, size: 38)
                                    Text(mode.displayName.replacingOccurrences(of: " ", with: "\n"))
                                        .font(.headline).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 116)
                                .foregroundStyle(selection == mode ? mode.settingsColor : Color.secondary)
                                .background(
                                    selection == mode ? mode.settingsColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 22)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 22)
                                        .strokeBorder(
                                            selection == mode ? mode.settingsColor : Color.secondary.opacity(0.4),
                                            lineWidth: selection == mode ? 2 : 0.5
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSelect)
                            .accessibilityLabel(mode.displayName)
                            .accessibilityAddTraits(selection == mode ? .isSelected : [])
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.chart)
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Loop Modes").font(.headline)
                        Text(
                            "Trio analyzes your glucose every 5 minutes to determine how insulin delivery should adjust in each moment. Choose which adjustments Trio can make automatically. All Loop Modes require an active CGM and insulin pump."
                        )
                        .foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    ForEach(DosingMode.userSelectable) { mode in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                SettingsLoopModeSymbol(mode: mode, size: 20)
                                Text(mode.displayName).font(.headline)
                            }.foregroundStyle(.secondary)
                            Text(mode.settingsExplanation).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                }.listRowBackground(Color.chart)
            }
            .settingsBackground()
            .navigationTitle("Loop Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .tint(Color.tabBar).accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
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
                    .foregroundStyle(Color.tabBar)
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
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.white)
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
                    Text(formatted(value)).foregroundStyle(Color.tabBar)
                }
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingWheel, attachmentAnchor: .rect(.bounds)) {
                wheelContent
                    .presentationCompactAdaptation(.popover)
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
        .settingsBackground().tint(.white)
        .navigationTitle(LocalizedStringKey(title))
        .navigationBarTitleDisplayMode(.inline)
    }

    var wheelContent: some View {
        picker
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(width: 280, height: 216)
            .padding(.horizontal, 8)
            .accessibilityLabel(LocalizedStringKey(title))
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

struct SettingsGlucoseRangeRow: View {
    @Binding var lower: Decimal
    @Binding var upper: Decimal
    let units: GlucoseUnits
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            LabeledContent("Range") {
                Text("\(number(lower)) – \(number(upper)) \(units.rawValue)").foregroundStyle(Color.tabBar)
            }
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showingPicker, attachmentAnchor: .rect(.bounds)) {
            pickerContent.presentationCompactAdaptation(.popover)
        }
    }

    var pickerContent: some View {
        HStack(spacing: 0) {
            Picker("Lower Limit", selection: $lower) {
                ForEach(values(lower: true), id: \.self) { Text(number($0)).tag($0) }
            }
            .accessibilityLabel("Lower Limit")
            .frame(width: 130)
            .clipped()
            Text("–").font(.title3).accessibilityHidden(true)
            Picker("Upper Limit", selection: $upper) {
                ForEach(values(lower: false), id: \.self) { Text(number($0)).tag($0) }
            }
            .accessibilityLabel("Upper Limit")
            .frame(width: 130)
            .clipped()
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(height: 216)
        .padding(.horizontal, 8)
    }

    private func values(lower isLower: Bool) -> [Decimal] {
        let spec = isLower ? PickerSettingsProvider.shared.settings.low : PickerSettingsProvider.shared.settings.high
        let current = isLower ? lower : upper
        var values = PickerSettingsProvider.shared.generatePickerValues(from: spec, units: units)
        if !values.contains(current) { values.append(current) }
        return values.filter { $0 == current || (isLower ? $0 < upper : $0 > lower) }.sorted()
    }

    private func number(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = units == .mmolL ? 1 : 0
        return formatter.string(from: (units == .mmolL ? value.asMmolL : value) as NSDecimalNumber) ?? ""
    }
}

struct SettingsRowLabel: View {
    let title: String

    static let iconNames: [String: String] = [
        "Devices": "SettingsDevices", "Therapy": "SettingsTherapy",
        "Algorithm": "SettingsAlgorithm", "Notifications": "SettingsNotifications",
        "Customize": "SettingsCustomize", "Services": "SettingsServices",
        "Caregivers": "SettingsCaregivers", "Support": "SettingsSupport",
        "About": "SettingsAbout", "Release Notes": "SettingsReleaseNotes",
        "Expiration": "SettingsExpiration"
    ]

    var body: some View {
        HStack(spacing: 12) {
            if let icon = Self.iconNames[title] {
                Image(icon)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 29, height: 29)
                    .accessibilityHidden(true)
            }
            Text(LocalizedStringKey(title))
        }
    }
}

struct SettingsProfileAvatar: View {
    let profile: SettingsUserProfile
    var size: CGFloat = 54

    var body: some View {
        Group {
            if let data = profile.photoData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(profile.initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .background(Color.tabBar.opacity(0.15), in: Circle())
        .clipShape(Circle())
    }
}

enum SettingsProfilePhoto {
    static func prepare(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }
        // Store a small, orientation-correct image without the original photo metadata.
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8)
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
