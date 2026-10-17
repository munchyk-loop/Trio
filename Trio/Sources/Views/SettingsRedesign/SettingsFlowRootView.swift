import SwiftUI
import Swinject

struct SettingsFlowRootView: View {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel
    @StateObject private var model: SettingsFlowModel
    @State private var searchQuery = ""
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @State private var showingModes = false
    @State private var searchDestination: SettingsFlowSearchEntry?
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
            if !searchPresented {
                settingsSections.listRowBackground(Color.chart)
            } else {
                SettingsFlowSearchResults(query: searchQuery, model: model) { entry in
                    searchDestination = entry
                    searchPresented = false
                    searchQuery = ""
                }
            }
        }
        .listStyle(.insetGrouped)
        .settingsBackground()
        .navigationTitle(searchPresented ? "" : "Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $searchDestination) { entry in
            SettingsFlowPageView(page: entry.page, model: model)
        }
        .onChange(of: searchPresented) { _, presented in
            if !presented { searchQuery = "" }
        }
        .task(id: searchPresented) { searchFocused = searchPresented }
        .onDisappear {
            searchPresented = false
            searchQuery = ""
        }
        .toolbar {
            if searchPresented {
                ToolbarItem(placement: .principal) {
                    SettingsToolbarSearchField(text: $searchQuery, focused: $searchFocused)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        searchPresented = false
                        searchQuery = ""
                    } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close Search")
                        .accessibilityIdentifier("settings.search.close")
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingModes = true } label: {
                        Label(model.settings.dosingMode.displayName, systemImage: model.settings.dosingMode.icon)
                    }
                    .accessibilityLabel("Dosing Mode")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation { searchPresented = true } } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search Settings")
                        .accessibilityIdentifier("settings.search.open")
                }
            }
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
                .settingsBackground()
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

    private var settingsSections: some View {
        Group {
            Section {
                NavigationLink {
                    SettingsFlowPageView(page: .profile, model: model)
                } label: {
                    HStack(spacing: 16) {
                        SettingsProfileAvatar(profile: model.userProfile)
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
                        SettingsRowLabel(title: "About")
                        Spacer()
                        Text(Bundle.main.appDevVersion ?? "Unknown").foregroundStyle(.secondary)
                    }
                }
                if !releaseNotes.releases.isEmpty {
                    NavigationLink {
                        ReleaseNotesListView(releases: releaseNotes.releases)
                    } label: { SettingsRowLabel(title: "Release Notes") }
                }
                if let date = BuildDetails.shared.calculateExpirationDate() {
                    HStack {
                        SettingsRowLabel(title: "Expiration")
                        Spacer()
                        Text(date, style: .date).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ page: SettingsFlowPage) -> some View {
        NavigationLink {
            SettingsFlowPageView(page: page, model: model)
        } label: { SettingsRowLabel(title: page.title) }
    }
}

struct SettingsFlowSearchEntry: Identifiable, Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let page: SettingsFlowPage
    let label: String
    var aliases = ""
    var id: String { page.rawValue + "." + label }

    private static let navigationEntries: [SettingsFlowSearchEntry] = [
        .init(page: .profile, label: "Backup & Restore", aliases: "iCloud Export Settings Import CloudKit"),
        .init(page: .personalInformation, label: "Personal Information", aliases: "name body height weight sex birth"),
        .init(page: .languageUnits, label: "Language & Units", aliases: "mg/dL mmol/L eA1c GMI TIR"),
        .init(page: .cgm, label: "Smooth CGM Readings", aliases: "smoothing"),
        .init(page: .cgm, label: "Erratic CGM → Raise Target", aliases: "Noisy CGM Target Increase Multiplier"),
        .init(page: .cgm, label: "Sudden Rise → Pause AB", aliases: "Max Allowed Glucose Rise for SMB Rise Threshold"),
        .init(page: .pump, label: "Auto Un-Suspend Pump", aliases: "Unsuspend If No Temp"),
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
            aliases: "System Glucose Alerts Alarms Profiles Time Location Schedule Live Activity"
        ),
        .init(page: .graph, label: "Graph", aliases: "Grid Lines Range Color Style Forecast Bolus Label Threshold"),
        .init(page: .statisticsBar, label: "Statistics Bar", aliases: "Home Stats Panel"),
        .init(page: .customize, label: "Customize", aliases: "Appearance Icon Quick Pick Carbs"),
        .init(page: .services, label: "Services", aliases: "Apple Health Nightscout Tidepool Shortcuts"),
        .init(page: .caregivers, label: "Caregivers", aliases: "Remote Control"),
        .init(page: .support, label: "Support", aliases: "Analytics Diagnostics Logs Bug Help Community"),
        .init(page: .about, label: "About", aliases: "Version Build Branch Components")
    ]

    // Search only the supported flow. Indexing every legacy setting reintroduced
    // controls deliberately removed from the redesign through search results.
    static var all: [Self] {
        var entries = navigationEntries
        let labels: [(SettingsFlowPage, [String])] = [
            (.languageUnits, ["App Language", "Glucose", "eA1c/GMI", "TIR Lower Threshold"]),
            (
                .safetyLimits,
                [
                    "Safety Threshold",
                    "Basal Rate",
                    "Bolus",
                    "Insulin on Board (IOB)",
                    "Temporary Basal Rate",
                    "Auto Bolus",
                    "Auto Bolus - UAM",
                    "ISF Strength Increase",
                    "ISF Strength Decrease",
                    "Carb Entry",
                    "Carbs on Board (COB)"
                ]
            ),
            (
                .dynamicISF,
                [
                    "Adjustment Method",
                    "Adjustment Factor",
                    "Recent / Historical TDD",
                    "Basal Adjustment Method",
                    "Raise Target When Sensitive",
                    "Lower Target When Resistant"
                ]
            ),
            (
                .insulinDosing,
                [
                    "Always Allow Auto Boluses",
                    "When There Are COB",
                    "For 6 hrs After Carb Entry",
                    "When Glucose is Above",
                    "Glucose Threshold",
                    "Auto Bolus Delivery Ratio",
                    "Manual Bolus Delivery Ratio",
                    "Slow Absorption",
                    "Fast Absorption",
                    "Add Scheduled Basal Upfront"
                ]
            ),
            (
                .advanced,
                [
                    "Insulin Peak Time",
                    "Duration of Insulin Action",
                    "Auto Bolus Interval",
                    "Max Duration of Carb Absorption",
                    "Min Rate of Carb Absorption",
                    "Carb Prediction Percentage",
                    "Carb Prediction Limit"
                ]
            ),
            (.additionalSafety, ["UAM Predictions", "Very Low Glucose Warning", "Overrides"]),
            (.notifications, ["Permissions", "System Alerts", "Glucose Alerts", "Live Activity"]),
            (.customize, ["Icon", "Appearance", "Quick-Pick Treatments", "Carbs"]),
            (
                .graph,
                [
                    "Grid Lines",
                    "Lower Limit",
                    "Upper Limit",
                    "Range Graph Lines",
                    "Color Style",
                    "Forecast Style",
                    "Bolus Label Threshold"
                ]
            ),
            (.statisticsBar, ["Display Options"]),
            (.services, ["Apple Health", "Nightscout", "Tidepool", "Shortcuts"]),
            (.support, ["Analytics Sharing", "App Logs", "Report a Bug", "Trio Help Guide"])
        ]
        for (page, labels) in labels {
            for label in labels where !entries.contains(where: { $0.page == page && $0.label == label }) {
                entries.append(Self(page: page, label: label))
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

/// Search results are rows in the main Settings list, with the same navigation stack.
struct SettingsFlowSearchResults: View {
    let query: String
    @ObservedObject var model: SettingsFlowModel
    var onSelect: ((SettingsFlowSearchEntry) -> Void)? = nil

    var body: some View {
        let entries = SettingsFlowSearchEntry.matching(query)
        Section {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Search Settings",
                    systemImage: "magnifyingglass",
                    description: Text("Find a setting by name or description.")
                )
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(entries) { entry in
                    if let onSelect {
                        Button { onSelect(entry) } label: { label(entry) }
                            .foregroundStyle(.primary)
                    } else {
                        NavigationLink { SettingsFlowPageView(page: entry.page, model: model) } label: { label(entry) }
                    }
                }
                .listRowBackground(Color.chart)
            }
        }
        .listRowBackground(Color.chart)
    }

    private func label(_ entry: SettingsFlowSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(entry.label))
            Text(LocalizedStringKey(entry.page.title)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The field exists only while search is open, so closing it removes its focus
/// and toolbar presentation together rather than reflecting system state back.
struct SettingsToolbarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Settings", text: $text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focused)
                .accessibilityIdentifier("settings.search.field")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 170, idealWidth: 250, maxWidth: .infinity)
        .modifier(SettingsSearchFieldBackground())
    }
}

private struct SettingsSearchFieldBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
