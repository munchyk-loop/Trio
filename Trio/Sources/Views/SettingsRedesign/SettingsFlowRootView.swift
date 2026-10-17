import SwiftUI
import Swinject

struct SettingsFlowRootView: View {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel
    @StateObject private var model: SettingsFlowModel
    @State private var showingSearch = false
    @State private var showingModes = false
    @State private var knownVersionIssues = false
    @State private var availableVersion: String?
    @ObservedObject private var releaseNotes = ReleaseNotesService.shared

    init(resolver: Resolver, state: Settings.StateModel) {
        self.resolver = resolver
        self.state = state
        _model = StateObject(wrappedValue: SettingsFlowModel(resolver: resolver))
    }

    var body: some View {
        List {
            if knownVersionIssues {
                Section {
                    Label("This version has known issues. Update Trio.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            } else if let availableVersion {
                Section {
                    Label("Trio \(availableVersion) is available.", systemImage: "arrow.up.circle")
                }
            }
            Section {
                NavigationLink {
                    SettingsFlowPageView(page: .profile, model: model)
                } label: {
                    HStack(spacing: 16) {
                        Text(model.userProfile.initials)
                            .font(.title2.weight(.semibold))
                            .frame(width: 54, height: 54)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.userProfile.name.isEmpty ? String(localized: "Your Profile") : model.userProfile.name)
                                .font(.headline)
                            Text("Profile, Language & Units, and more")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            Section {
                row(.devices)
                row(.therapy)
                row(.algorithm)
                row(.notifications)
                row(.customize)
            }
            Section { row(.services)
                row(.caregivers) }
            Section { row(.support) }
            Section("App Info") {
                NavigationLink {
                    SettingsFlowPageView(page: .about, model: model)
                } label: {
                    HStack {
                        SettingsPlaceholderLabel(title: "About")
                        Spacer()
                        Text(Bundle.main.appDevVersion ?? "Unknown").foregroundStyle(.secondary)
                    }
                }
                if !releaseNotes.releases.isEmpty {
                    NavigationLink {
                        ReleaseNotesListView(releases: releaseNotes.releases)
                    } label: { SettingsPlaceholderLabel(title: "Release Notes") }
                }
                if let date = BuildDetails.shared.calculateExpirationDate() {
                    HStack {
                        SettingsPlaceholderLabel(title: "Expiration")
                        Spacer()
                        Text(date, style: .date).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingModes = true } label: {
                    Label(model.settings.dosingMode.displayName, systemImage: model.settings.dosingMode.icon)
                }
                .accessibilityLabel("Dosing Mode")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search Settings")
            }
        }
        .sheet(isPresented: $showingSearch) {
            SettingsFlowSearchView(model: model)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showingModes) {
            NavigationStack {
                Form {
                    Section {
                        Picker("Dosing Mode", selection: model.setting(\.dosingMode)) {
                            ForEach(DosingMode.userSelectable) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .disabled(!state.hasCgmAndPump())
                    } footer: {
                        Text(
                            "Trio analyzes your glucose every 5 minutes to calculate helpful insulin adjustments. Choose which adjustments Trio can make automatically. All modes require an active CGM and insulin pump."
                        )
                    }
                    Section {
                        ForEach(DosingMode.userSelectable) { mode in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(mode.displayName, systemImage: mode.icon).font(.headline)
                                Text(mode.description).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("Dosing Mode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showingModes = false } label: { Image(systemName: "checkmark") }
                            .accessibilityLabel("Done")
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .task {
            await releaseNotes.load()
            let (_, latest, newer, blacklisted) = await AppVersionChecker.shared.refreshVersionInfo()
            knownVersionIssues = blacklisted
            availableVersion = newer ? latest : nil
            if BuildDetails.shared.trioBranch != "main" {
                let (version, newer) = await AppVersionChecker.shared.checkForNewDevVersion()
                if newer { availableVersion = version }
            }
        }
    }

    private func row(_ page: SettingsFlowPage) -> some View {
        NavigationLink {
            SettingsFlowPageView(page: page, model: model)
        } label: { SettingsPlaceholderLabel(title: page.title) }
    }
}

struct SettingsFlowSearchEntry: Identifiable {
    let page: SettingsFlowPage
    let label: String
    var aliases = ""
    var legacyScreen: Screen? = nil
    var context: String? = nil
    var id: String { page.rawValue + "." + label }

    private static let navigationEntries: [SettingsFlowSearchEntry] = [
        .init(page: .profile, label: "Backup & Restore", aliases: "iCloud Export Settings Import CloudKit"),
        .init(page: .personalInformation, label: "Personal Information", aliases: "name body height weight sex birth"),
        .init(page: .languageUnits, label: "Language & Units", aliases: "mg/dL mmol/L eA1c GMI TIR"),
        .init(page: .cgm, label: "Smooth CGM Readings", aliases: "smoothing"),
        .init(page: .cgm, label: "Erratic CGM → Raise Target", aliases: "Noisy CGM Target Increase Multiplier"),
        .init(page: .cgm, label: "Sudden Rise → Pause AB", aliases: "Max Allowed Glucose Rise for SMB Rise Threshold"),
        .init(page: .pump, label: "Auto Un-Suspend Pump", aliases: "Unsuspend If No Temp"),
        .init(
            page: .pumpAdvanced,
            label: "Pump Configuration",
            aliases: "Rewind Resets Autosens Skip Neutral Temps Suspension Resets IOB"
        ),
        .init(page: .therapy, label: "Therapy", aliases: "Basal Rates Carb Ratios Insulin Sensitivities ISF Targets"),
        .init(
            page: .safetyLimits,
            label: "Safety Limits",
            aliases: "Max IOB Max COB Max Carbs Basal Bolus Threshold Autosens Min Max ISF Strength Increase Decrease Max SMB UAM Basal Minutes"
        ),
        .init(
            page: .dynamicISF,
            label: "Dynamic ISF",
            aliases: "Autosens Logarithmic Sigmoid Adjustment Factor Weighted Average TDD Adjust Basal Target Behavior"
        ),
        .init(
            page: .insulinDosing,
            label: "Insulin Dosing",
            aliases: "SMB Auto Bolus Delivery Ratio Recommended Bolus Percentage Reduced Super Bolus Fast Slow Absorption Add Scheduled Basal Upfront"
        ),
        .init(
            page: .advanced,
            label: "Advanced",
            aliases: "DIA Duration Insulin Action Peak Time SMB Interval Carb Prediction Remaining Carbs Fraction Cap Min 5m Carb Impact Absorption"
        ),
        .init(page: .additionalSafety, label: "Additional Configuration", aliases: "UAM Very Low Glucose Warning Overrides"),
        .init(
            page: .notifications,
            label: "Notifications",
            aliases: "System Glucose Alerts Alarms Profiles Time Location Schedule Live Activity Calendar"
        ),
        .init(page: .graph, label: "Graph", aliases: "Grid Lines Range Color Style Forecast Bolus Label Threshold"),
        .init(page: .statisticsBar, label: "Statistics Bar", aliases: "Home Stats Panel"),
        .init(page: .customize, label: "Customize", aliases: "Appearance Icon Quick Pick Presets Carbs"),
        .init(page: .services, label: "Services", aliases: "Apple Health Nightscout Tidepool Shortcuts"),
        .init(page: .caregivers, label: "Caregivers", aliases: "Remote Control"),
        .init(page: .support, label: "Support", aliases: "Analytics Diagnostics Logs Bug Help Community"),
        .init(page: .about, label: "About", aliases: "Version Build Branch Components")
    ]

    static var all: [Self] {
        let renamed = [
            "Enable SMB Always": "Always Allow Auto Boluses",
            "Enable SMB With COB": "When There Are COB",
            "Enable SMB After Carbs": "For 6 hrs After Carb Entry",
            "SMB Delivery Ratio": "Auto Bolus Delivery Ratio",
            "Max SMB Basal Minutes": "Auto Bolus",
            "Max UAM SMB Basal Minutes": "Auto Bolus - UAM",
            "Max Allowed Glucose Rise for SMB": "Rise Threshold",
            "Recommended Bolus Percentage": "Manual Bolus Delivery Ratio",
            "Enable Reduced Bolus Factor": "Slow Absorption",
            "Reduced Bolus Factor": "Slow Absorption",
            "Enable Super Bolus": "Fast Absorption",
            "Super Bolus Factor": "Add Scheduled Basal Upfront",
            "Min 5m Carbimpact": "Min Rate of Carb Absorption",
            "Remaining Carbs Fraction": "Carb Prediction Percentage",
            "Remaining Carbs Cap": "Carb Prediction Limit",
            "Noisy CGM Target Multiplier": "Erratic CGM → Raise Target"
        ]
        var entries = navigationEntries
        for item in SettingItems.allItems {
            let page: SettingsFlowPage?
            switch item.view {
            case .dynamicISF, .autosensSettings: page = .dynamicISF
            case .smbSettings, .bolusCalculatorConfig: page = .insulinDosing
            case .targetBehavior: page = .dynamicISF
            case .algorithmAdvancedSettings: page = .advanced
            case .unitsAndLimits: page = .safetyLimits
            case .remoteControlConfig: page = .caregivers
            case .glucoseAlerts, .deviceAlarms, .alarmWindows, .notificationSettings: page = .notifications
            default: page = nil
            }
            for label in item.searchContents ?? [item.title] {
                let destination: SettingsFlowPage?
                switch label {
                case "Glucose Units", "eA1c/GMI Display Unit", "Time in Range Type", "Time in Tight Range (TITR)",
                     "Time in Normoglycemia (TING)": destination = .languageUnits
                case "Smooth Glucose Value": destination = .cgm
                case "Max Carbs": destination = .safetyLimits
                case "Max Meal Absorption Time": destination = .advanced
                case "Noisy CGM Target Multiplier", "Max Allowed Glucose Rise for SMB": destination = .cgm
                case "Skip Neutral Temps", "Unsuspend If No Temp": destination = .pumpAdvanced
                case "Autosens Max", "Autosens Min", "Max Daily Safety Multiplier", "Current Basal Safety Multiplier",
                     "Max SMB Basal Minutes", "Max UAM SMB Basal Minutes": destination = .safetyLimits
                case "SMB Delivery Ratio": destination = .insulinDosing
                case "SMB Interval": destination = .advanced
                case "Rewind Resets Autosens": destination = .pumpAdvanced
                case "Enable UAM", "Very Low Glucose Warning": destination = .additionalSafety
                case "High Temptarget Raises Sensitivity", "Low Temptarget Lowers Sensitivity",
                     "Half Basal Exercise Target", "Allow SMB With High Temporary Target", "Enable SMB With Temporary Target":
                    continue
                default: destination = page
                }
                let entry = Self(
                    page: destination ?? .about, label: renamed[label] ?? label, aliases: label,
                    legacyScreen: destination == nil ? item.view : nil,
                    context: destination == nil ? item.title : nil
                )
                if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
            }
        }
        return entries
    }

    static func matching(_ text: String) -> [Self] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { entry in
            words.allSatisfy { (entry.label + " " + entry.aliases).localizedCaseInsensitiveContains($0) }
        }
    }
}

struct SettingsFlowSearchView: View {
    @ObservedObject var model: SettingsFlowModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SettingsFlowSearchEntry.matching(query)) { entry in
                NavigationLink {
                    if let screen = entry.legacyScreen {
                        screen.view(resolver: model.resolver)
                    } else {
                        SettingsFlowPageView(page: entry.page, model: model)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(entry.label))
                        Text(LocalizedStringKey(entry.context ?? entry.page.title)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search Settings")
            .navigationTitle("Search Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
        }
    }
}
