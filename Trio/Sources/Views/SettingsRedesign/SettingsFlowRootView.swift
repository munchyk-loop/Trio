import SwiftUI
import Swinject

struct SettingsFlowRootView: View {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel
    @StateObject private var model: SettingsFlowModel
    @Binding private var search: SettingsSearchSession
    @State private var showingModes = false
    @State private var searchQuery = ""
    @State private var searchDestination: SettingsFlowSearchEntry?
    @State private var knownVersionIssues = false
    @State private var availableVersion: String?
    @ObservedObject private var releaseNotes = ReleaseNotesService.shared

    init(resolver: Resolver, state: Settings.StateModel, search: Binding<SettingsSearchSession>) {
        self.resolver = resolver
        self.state = state
        _search = search
        _model = StateObject(wrappedValue: SettingsFlowModel(resolver: resolver))
    }

    var body: some View {
        settingsContent
            .navigationDestination(item: $searchDestination) { entry in
                SettingsFlowPageView(page: entry.page, model: model)
            }
            .tint(.primary)
            .sheet(isPresented: $showingModes) {
                SettingsLoopModeSheet(selection: model.setting(\.dosingMode), canSelect: state.hasCgmAndPump())
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

    // Native system search. The system alone owns whether search is active:
    // there is deliberately no isPresented binding, because pushing a stale
    // "presented" value back during a re-render re-opened search mid-close.
    // Content reads \.isSearching; result taps use \.dismissSearch.
    private var settingsContent: some View {
        List {
            SettingsSearchAwareContent(query: searchQuery, model: model, onSelect: { searchDestination = $0 }) {
                settingsSections.listRowBackground(Color.chart)
            }
        }
        .tint(Color.tabBar)
        .listStyle(.insetGrouped)
        .settingsBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(id: "settings.loop-mode", placement: .topBarLeading) { loopModeButton }
        }
        .modifier(SettingsNativeSearch(text: $searchQuery))
    }

    private var loopModeButton: some View {
        Button { showingModes = true } label: {
            SettingsLoopModeSymbol(mode: model.settings.dosingMode, size: 22)
        }
        .tint(model.settings.dosingMode.settingsColor)
        .accessibilityLabel("Loop Mode, \(model.settings.dosingMode.displayName)")
        .accessibilityIdentifier("settings.loop-mode")
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
                .accessibilityIdentifier("settings.profile")
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
                row(.caregivers)
            }
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
    static let all: [Self] = {
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
    }()

    // App-language changes relaunch the app, so localize once rather than on
    // every keyboard event. Keep the entry IDs stable as results change.
    private static let searchIndex: [(entry: Self, text: String)] = all.map { entry in
        let localizedLabel = String(localized: String.LocalizationValue(entry.label))
        let localizedPage = String(localized: String.LocalizationValue(entry.page.title))
        return (entry, [entry.label, entry.aliases, localizedLabel, localizedPage].joined(separator: " "))
    }

    static func matching(_ text: String) -> [Self] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return searchIndex.compactMap { item in
            words.allSatisfy { item.text.localizedStandardContains($0) } ? item.entry : nil
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

/// Shows search results while the system search is active, settings otherwise.
/// Must live inside the `.searchable` view so it sees `isSearching`.
private struct SettingsSearchAwareContent<Sections: View>: View {
    let query: String
    @ObservedObject var model: SettingsFlowModel
    let onSelect: (SettingsFlowSearchEntry) -> Void
    @ViewBuilder let sections: () -> Sections

    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        if isSearching {
            SettingsFlowSearchResults(query: query, model: model) { entry in
                dismissSearch()
                onSelect(entry)
            }
        } else {
            sections()
        }
    }
}

/// iOS 26+: the system search button in the top trailing slot, with the native
/// Liquid Glass morph into the field. Earlier iOS: the standard search drawer.
private struct SettingsNativeSearch: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .searchable(text: $text, placement: .toolbar, prompt: Text("Search Settings"))
                .searchToolbarBehavior(.minimize)
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                }
        } else {
            content
                .searchable(
                    text: $text,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("Search Settings")
                )
        }
    }
}
