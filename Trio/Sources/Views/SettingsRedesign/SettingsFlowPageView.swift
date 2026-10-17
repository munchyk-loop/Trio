import HealthKit
import LocalAuthentication
import LoopKit
import PhotosUI
import SwiftUI
import Swinject

struct SettingsFlowPageView: View {
    let page: SettingsFlowPage
    @ObservedObject var model: SettingsFlowModel
    @State private var showLogs = false
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var loadingProfilePhoto = false
    @State private var personalInformationUnlocked = false
    @State private var authenticationError: String?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("colorSchemePreference") private var appearance: ColorSchemeOption = .systemDefault
    // Keep the picker catalogue out of this value-type view. Navigation and Form
    // closures copy the view, so storing every picker here exhausts the device stack.
    private var specs: DecimalPickerSettings { PickerSettingsProvider.shared.settings }

    var body: some View {
        Group {
            if page == .caregivers {
                SettingsScreenDestination(screen: .remoteControlConfig, resolver: model.resolver)
            } else if page == .cgm || page == .pump {
                SettingsConnectedDeviceView(page: page, model: model)
            } else {
                Form { content.listRowBackground(Color.chart) }.pickerStyle(.menu)
            }
        }
        .settingsBackground()
        .navigationTitle(LocalizedStringKey(page.title))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) { ShareSheet(activityItems: logItems) }
        .alert("Settings", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
        .task(id: selectedProfilePhoto) {
            guard let selection = selectedProfilePhoto else { return }
            loadingProfilePhoto = true
            defer { loadingProfilePhoto = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self),
                      let photo = SettingsProfilePhoto.prepare(data)
                else {
                    if !Task.isCancelled { model.error = String(localized: "The selected photo could not be loaded.") }
                    return
                }
                guard !Task.isCancelled, selection == selectedProfilePhoto else { return }
                model.profileField(\.photoData).wrappedValue = photo
            } catch {
                if !Task.isCancelled { model.error = String(localized: "The selected photo could not be loaded.") }
            }
        }
        .task {
            if page == .personalInformation { await unlockPersonalInformation() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { personalInformationUnlocked = false }
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .profile: profile
        case .personalInformation: personalInformation
        case .languageUnits: languageUnits
        case .devices: devices
        case .cgm: cgm
        case .pump: pump
        case .therapy: therapy
        case .algorithm: algorithm
        case .safetyLimits: safetyLimits
        case .dynamicISF: dynamicISF
        case .insulinDosing: insulinDosing
        case .advanced: advanced
        case .additionalSafety: additionalSafety
        case .notifications: notifications
        case .customize: customize
        case .graph: graph
        case .statisticsBar: statisticsBar
        case .services: services
        case .caregivers: caregivers
        case .support: support
        case .about: about
        case .community: community
        }
    }

    private func link(_ page: SettingsFlowPage) -> some View {
        NavigationLink(LocalizedStringKey(page.title)) { SettingsFlowPageView(page: page, model: model) }
    }

    private func screen(_ title: String, _ screen: Screen) -> some View {
        NavigationLink(LocalizedStringKey(title)) { SettingsScreenDestination(screen: screen, resolver: model.resolver) }
    }

    private func number(
        _ title: String, _ key: WritableKeyPath<Preferences, Decimal>, _ spec: PickerSetting,
        suffix: String? = nil, presentation: SettingsValuePresentation = .navigation, description: String = ""
    ) -> some View {
        SettingsNumberRow(
            title: title,
            value: model.preference(key),
            spec: spec,
            units: model.units,
            suffix: suffix,
            presentation: presentation,
            description: description
        )
    }

    private func settingNumber(
        _ title: String, _ key: WritableKeyPath<TrioSettings, Decimal>, _ spec: PickerSetting
    ) -> some View {
        SettingsNumberRow(title: title, value: model.setting(key), spec: spec, units: model.units)
    }

    private func help(_ title: String, _ text: String, detail: String? = nil) -> some View {
        SettingsHelpFooter(title: title, text: text, detail: detail)
    }

    private var profile: some View {
        Group {
            Section {
                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                        SettingsProfileAvatar(profile: model.userProfile, size: 76)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change Profile Photo")
                    Text(model.userProfile.name.isEmpty ? String(localized: "Your Profile") : model.userProfile.name)
                        .font(.title2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            Section("Profile Photo") {
                PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                    Label(model.userProfile.photoData == nil ? "Choose Photo" : "Change Photo", systemImage: "photo")
                }
                .disabled(loadingProfilePhoto)
                if loadingProfilePhoto { ProgressView("Loading Photo") }
                if model.userProfile.photoData != nil {
                    Button("Use Initials", systemImage: "person.crop.circle") {
                        selectedProfilePhoto = nil
                        model.profileField(\.photoData).wrappedValue = nil
                    }
                }
            }
            Section {
                link(.personalInformation)
                link(.languageUnits)
            }
            Section { screen("Statistics", .statistics) }
            Section { NavigationLink("Backup & Restore") { TrioCloudBackupView() } }
        }
    }

    @ViewBuilder private var personalInformation: some View {
        if personalInformationUnlocked {
            Section {
                TextField("Name", text: model.profileField(\.name))
                    .textContentType(.name)
            }
            Section {
                Toggle("Date of Birth", isOn: Binding(
                    get: { model.userProfile.dateOfBirth != nil },
                    set: { model.profileField(\.dateOfBirth).wrappedValue = $0 ? Date() : nil }
                ))
                if model.userProfile.dateOfBirth != nil {
                    DatePicker("Date of Birth", selection: Binding(
                        get: { model.userProfile.dateOfBirth ?? Date() },
                        set: { model.profileField(\.dateOfBirth).wrappedValue = $0 }
                    ), in: ...Date(), displayedComponents: .date)
                }
                TextField("Height (cm)", value: model.profileField(\.heightCM), format: .number)
                    .keyboardType(.decimalPad)
                TextField("Weight (kg)", value: model.profileField(\.weightKG), format: .number)
                    .keyboardType(.decimalPad)
                Picker("Sex", selection: model.profileField(\.sex)) {
                    Text("Not Specified").tag("")
                    Text("Female").tag("female")
                    Text("Male").tag("male")
                    Text("Other").tag("other")
                }
            } header: { Text("Body Profile") } footer: {
                help(
                    "Body Profile",
                    "Your body profile stores personal context. Changes here do not change your therapy settings."
                )
            }
            .privacySensitive()
        } else {
            Section {
                Button("Unlock Personal Information") { Task { await unlockPersonalInformation() } }
                if let authenticationError { Text(authenticationError).foregroundStyle(.secondary) }
            } footer: { Text("Use your device passcode or biometrics to view personal information.") }
        }
    }

    private func unlockPersonalInformation() async {
        let context = LAContext()
        do {
            personalInformationUnlocked = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: String(localized: "View your Trio personal information.")
            )
            authenticationError = nil
        } catch { authenticationError = error.localizedDescription }
    }

    private var languageUnits: some View {
        Group {
            Section("Language") {
                Button {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    LabeledContent("App Language") {
                        Text(
                            Locale.current
                                .localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "en") ?? "English"
                        )
                    }
                }
                .foregroundStyle(.primary)
            }
            Section("Units") {
                Picker("Glucose", selection: model.setting(\.units)) {
                    Text("mg/dL").tag(GlucoseUnits.mgdL)
                    Text("mmol/L").tag(GlucoseUnits.mmolL)
                }
            }
            Section("Statistics Format") {
                Picker("eA1c/GMI", selection: model.setting(\.eA1cDisplayUnit)) {
                    ForEach(EstimatedA1cDisplayUnit.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("TIR Lower Threshold", selection: model.setting(\.timeInRangeType)) {
                    ForEach(TimeInRangeType.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    private var devices: some View {
        Group {
            Section { link(.cgm)
                link(.pump) }
            Section { screen("Smart Watch", .watch) }
        }
    }

    var cgm: some View {
        Group {
            Section {
                Toggle("Smooth CGM Readings", isOn: model.setting(\.smoothGlucose))
            } header: { Text("CGM Reliability") } footer: {
                help(
                    "Smooth CGM Readings",
                    "Smooth your CGM readings to reduce erratic jumps and better reflect natural glucose trends."
                )
            }
            Section {
                Toggle("Erratic CGM → Raise Target", isOn: Binding(
                    get: { model.preferences.noisyCGMTargetMultiplier > 1 },
                    set: { model.preference(\.noisyCGMTargetMultiplier).wrappedValue = $0 ? 1.3 : 1 }
                ))
                if model.preferences.noisyCGMTargetMultiplier > 1 {
                    SettingsNumberRow(
                        title: "Raise Target", value: model.preference(\.noisyCGMTargetMultiplier),
                        spec: specs.noisyCGMTargetMultiplier,
                        suffix: "%", displayTransform: { ($0 - 1) * 100 }, presentation: .wheel
                    )
                }
            } footer: {
                help(
                    "Erratic CGM → Raise Target",
                    "Automatically raise your glucose target when erratic CGM readings are detected to help prevent insulin over-delivery caused by unreliable high glucose data."
                )
            }
            Section {
                Toggle("Sudden Rise → Pause AB", isOn: model.suddenRiseSafeguard)
                if model.preferences.pauseAutoBolusOnSuddenRise ?? true {
                    number("Rise Threshold", \.maxDeltaBGthreshold, specs.maxDeltaBGthreshold, presentation: .wheel)
                }
            } footer: {
                help(
                    "Sudden Rise → Pause AB",
                    "Pause Auto Boluses when an unusually rapid glucose rise is detected to help prevent insulin over-delivery caused by unreliable high glucose data.",
                    detail: "Trio checks the latest and recent average glucose changes against this percentage of current glucose. Auto Boluses remain paused while a checked change exceeds the threshold. Temporary basal adjustments remain available."
                )
            }
        }
    }

    var pump: some View {
        Group {
            Section {
                NavigationLink {
                    Form {
                        Section {
                            Picker("Auto Un-Suspend Pump", selection: model.preference(\.unsuspendIfNoTemp)) {
                                Text("Off").tag(false)
                                Text("On").tag(true)
                            }
                            .pickerStyle(.menu)
                        } footer: {
                            help(
                                "Auto Un-Suspend Pump",
                                "Trio will automatically un-suspend your pump after a manual 0 U/hr temporary basal rate expires."
                            )
                        }
                        .listRowBackground(Color.chart)
                    }
                    .settingsBackground()
                    .navigationTitle("Auto Un-Suspend Pump")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent(
                        "Auto Un-Suspend Pump",
                        value: model.preferences.unsuspendIfNoTemp ? String(localized: "On") : String(localized: "Off")
                    )
                }
            } header: { Text("Pump") } footer: {
                help(
                    "Auto Un-Suspend Pump",
                    "Trio will automatically un-suspend your pump after a manual 0 U/hr temporary basal rate expires."
                )
            }
        }
    }

    private var therapy: some View {
        Group {
            Section { link(.safetyLimits) }
            Section("Glucose") { screen("Targets", .targetsEditor) }
            Section("Insulin") {
                screen("Basal Rates", .basalProfileEditor)
                screen("Carb Ratios", .crEditor)
                screen("Insulin Sensitivities", .isfEditor)
            }
        }
    }

    private var algorithm: some View {
        Group {
            Section("Configuration") { link(.safetyLimits) }
            Section { link(.dynamicISF)
                link(.insulinDosing) }
            Section { link(.advanced) }
        }
    }

    private var safetyLimits: some View {
        Group {
            Section("Glucose") { number("Safety Threshold", \.threshold_setting, specs.threshold_setting) }
            Section("Insulin") {
                SettingsNumberRow(title: "Basal Rate", value: model.pumpLimit(basal: true), spec: specs.maxBasal)
                    .disabled(model.savingPumpLimits)
                SettingsNumberRow(title: "Bolus", value: model.pumpLimit(basal: false), spec: specs.maxBolus)
                    .disabled(model.savingPumpLimits)
                number("Insulin on Board (IOB)", \.maxIOB, specs.maxIOB)
            }
            Section("Automated Insulin") {
                NavigationLink("Temporary Basal Rate") { temporaryBasalLimits }
                number("Auto Bolus", \.maxSMBBasalMinutes, specs.maxSMBBasalMinutes, suffix: "basal min")
                number("Auto Bolus - UAM", \.maxUAMSMBBasalMinutes, specs.maxUAMSMBBasalMinutes, suffix: "basal min")
            }
            Section {
                SettingsNumberRow(
                    title: "ISF Strength Increase",
                    value: model.relativeISFLimit(increase: true),
                    spec: PickerSetting(value: 20, step: 5, min: 0, max: 100, type: .factor),
                    suffix: "%"
                )
                SettingsNumberRow(
                    title: "ISF Strength Decrease",
                    value: model.relativeISFLimit(increase: false),
                    spec: PickerSetting(value: 30, step: 5, min: 0, max: 90, type: .factor),
                    suffix: "%"
                )
            } footer: {
                help(
                    "ISF Strength Limits",
                    "Set how much Trio can automatically increase or decrease your ISF strength, including when using Dynamic ISF."
                )
            }
            Section("Carbs") {
                settingNumber("Carb Entry", \.maxCarbs, specs.maxCarbs)
                number("Carbs on Board (COB)", \.maxCOB, specs.maxCOB)
            }
            Section("Advanced") { link(.additionalSafety) }
        }
    }

    private var temporaryBasalLimits: some View {
        Form {
            Section {
                number(
                    "Maximum Scheduled Basal Multiplier",
                    \.maxDailySafetyMultiplier,
                    specs.maxDailySafetyMultiplier,
                    presentation: .wheel
                )
                number(
                    "Current Scheduled Basal Multiplier",
                    \.currentBasalSafetyMultiplier,
                    specs.currentBasalSafetyMultiplier,
                    presentation: .wheel
                )
            } footer: {
                help(
                    "Temporary Basal Rate",
                    "Trio applies the lowest of the pump basal limit and these two scheduled-basal limits.",
                    detail: "One multiplier applies to the highest scheduled basal rate; the other applies to the currently scheduled basal rate. Both safeguards remain independently enforced."
                )
            }
        }
        .settingsBackground()
        .navigationTitle("Temporary Basal Rate")
    }

    private var dynamicISF: some View {
        Group {
            Section {
                Text(
                    "Dynamic ISF automatically adjusts your ISF to better keep you in range, even as your insulin needs and circumstances change."
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Picker("Adjustment Method", selection: model.adjustmentMethod) {
                    Text("Basic (Autosens)").tag("basic")
                    Text("Logarithmic").tag("logarithmic").disabled(!model.hasValidTDD)
                    Text("Sigmoid").tag("sigmoid").disabled(!model.hasValidTDD)
                }
            } header: { Text("ISF Adjustment") } footer: {
                help(
                    "Adjustment Method",
                    "Choose how DyISF calculates ISF adjustments as your insulin needs change.",
                    detail: "Basic uses Autosens. Logarithmic and Sigmoid use Dynamic ISF and require sufficient insulin history. All three methods share the ISF strength limits. Selecting Basic preserves your saved Dynamic ISF configuration."
                )
            }
            if model.preferences.useNewFormula {
                Section {
                    if model.preferences.sigmoid {
                        number(
                            "Adjustment Factor",
                            \.adjustmentFactorSigmoid,
                            specs.adjustmentFactorSigmoid,
                            presentation: .wheel
                        )
                    } else {
                        number("Adjustment Factor", \.adjustmentFactor, specs.adjustmentFactor, presentation: .wheel)
                    }
                } footer: {
                    help(
                        "Adjustment Factor",
                        "Choose how quickly and strongly DyISF adjusts your ISF in response to changing glucose levels."
                    )
                }
                Section {
                    Slider(value: model.recentTDDWeight, in: 0 ... 1, step: 0.05) {
                        Text("Recent / Historical TDD")
                    }
                    HStack {
                        Text("Recent \(Int((model.recentTDDWeight.wrappedValue * 100).rounded()))%")
                        Spacer()
                        Text("Historical \(Int(((1 - model.recentTDDWeight.wrappedValue) * 100).rounded()))%")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } footer: {
                    help(
                        "Recent / Historical TDD",
                        "Choose how much your recent vs historical insulin use contributes to DyISF calculations."
                    )
                }
                Section {
                    Picker("Basal Adjustment Method", selection: model.preference(\.tddAdjBasal)) {
                        Text("ISF").tag(false)
                        Text("TDD").tag(true)
                    }
                } header: { Text("Insulin Adjustment") } footer: {
                    help(
                        "Basal Adjustment Method",
                        "Choose how DyISF calculates basal rate adjustments as your insulin needs change."
                    )
                }
            }
            if !model.hasValidTDD {
                Section {
                    Text(
                        "Logarithmic and Sigmoid methods become available after sufficient insulin history has been collected. This can take up to 7 days."
                    )
                    .foregroundStyle(.secondary) }
            }
            Section {
                Toggle("Raise Target When Sensitive", isOn: model.preference(\.sensitivityRaisesTarget))
                Toggle("Lower Target When Resistant", isOn: model.preference(\.resistanceLowersTarget))
            } header: { Text("Target Adjustment") } footer: {
                help(
                    "Target Adjustment",
                    "Choose how DyISF adjusts your glucose target in response to changing insulin sensitivity."
                )
            }
        }
    }

    private var insulinDosing: some View {
        Group {
            Section {
                Toggle("Always Allow Auto Boluses", isOn: model.preference(\.enableSMBAlways))
                if !model.preferences.enableSMBAlways {
                    Toggle("When There Are COB", isOn: model.preference(\.enableSMBWithCOB))
                    Toggle("For 6 hrs After Carb Entry", isOn: model.preference(\.enableSMBAfterCarbs))
                    Toggle("When Glucose is Above", isOn: model.preference(\.enableSMB_high_bg))
                    if model.preferences.enableSMB_high_bg {
                        number(
                            "Glucose Threshold",
                            \.enableSMB_high_bg_target,
                            specs.enableSMB_high_bg_target,
                            presentation: .wheel
                        )
                    }
                }
            } header: { Text("Auto Bolus") } footer: {
                help("Auto Bolus", "Choose when Auto Boluses are allowed.")
            }
            Section {
                number("Delivery Ratio", \.smbDeliveryRatio, specs.smbDeliveryRatio, presentation: .wheel)
            } footer: {
                help(
                    "Auto Bolus Delivery Ratio",
                    "Choose what percentage of your calculated insulin needs can be delivered as an Auto Bolus."
                )
            }
            Section {
                SettingsNumberRow(
                    title: "Delivery Ratio",
                    value: model.setting(\.overrideFactor),
                    spec: specs.overrideFactor,
                    presentation: .wheel
                )
                SettingsNumberRow(
                    title: "Slow",
                    value: model.absorptionDeliveryRatio(fast: false),
                    spec: specs.overrideFactor,
                    includeOff: true, presentation: .wheel
                )
                SettingsNumberRow(
                    title: "Fast",
                    value: model.absorptionDeliveryRatio(fast: true),
                    spec: specs.overrideFactor,
                    includeOff: true, presentation: .wheel
                )
            } header: { Text("Manual Bolus") } footer: {
                help(
                    "Manual Bolus",
                    "Choose what percentage of your calculated insulin needs should be recommended as a bolus. Optionally adjust the percentage for slow or fast absorbing carb entries.",
                    detail: "Slow and Fast select independent delivery ratios for the bolus recommendation. Existing reduced-bolus settings retain their original effective percentage until you change them. Each option can be turned off without losing its saved percentage."
                )
            }
            if model.settings.sweetMeals {
                Section {
                    SettingsNumberRow(
                        title: "Add Scheduled Basal Upfront",
                        value: model.setting(\.sweetMealFactor),
                        spec: specs.sweetMealFactor,
                        includeOff: true, presentation: .wheel
                    )
                } footer: {
                    help(
                        "Add Scheduled Basal Upfront",
                        "Choose to add a percentage of your scheduled basal to a bolus for fast absorbing carbs.",
                        detail: "Adds the selected percentage of one hour of scheduled basal to a Fast bolus. Existing predictive safeguards still apply. This does not guarantee a matching reduction in future basal delivery."
                    )
                }
            }
        }
    }

    private var advanced: some View {
        Group {
            Section {
                Picker("Insulin Peak Time", selection: model.preference(\.useCustomPeakTime)) {
                    Text("Default").tag(false)
                    Text("Custom").tag(true)
                }
                if model.preferences.useCustomPeakTime {
                    number("Peak Time", \.insulinPeakTime, specs.insulinPeakTime, presentation: .wheel)
                }
            } header: { Text("Insulin") } footer: {
                help(
                    "Insulin Peak Time",
                    "The amount of time after insulin delivery when your insulin is most effective at lowering glucose."
                )
            }
            Section {
                SettingsNumberRow(
                    title: "Duration of Insulin Action",
                    value: model.insulinActionDuration,
                    spec: specs.dia,
                    presentation: .wheel
                )
            } footer: {
                help(
                    "Duration of Insulin Action",
                    "The amount of time after insulin delivery for which Trio can consider the insulin to be active."
                )
            }
            Section {
                number(
                    "Auto Bolus Interval",
                    \.smbInterval,
                    specs.smbInterval,
                    description: "Choose the minimum time between Auto Boluses."
                ) } footer: {
                help("Auto Bolus Interval", "Choose the minimum time between Auto Boluses.")
            }
            Section {
                number(
                    "Max Duration of Carb Absorption",
                    \.maxMealAbsorptionTime,
                    specs.maxMealAbsorptionTime,
                    presentation: .wheel
                ) } header: {
                Text("Carbs")
            } footer: {
                help(
                    "Max Duration of Carb Absorption",
                    "The max amount of time for which Trio can consider a carb entry to be active."
                )
            }
            Section { SettingsNumberRow(
                title: "Min Rate of Carb Absorption",
                value: model.preference(\.min5mCarbimpact),
                spec: specs.min5mCarbimpact,
                units: model.units,
                suffix: "\(model.units.rawValue)/5 min",
                displayTransform: { model.units == .mmolL ? $0.asMmolL : $0 },
                presentation: .wheel
            )
            } footer: {
                help(
                    "Min Rate of Carb Absorption",
                    "The parameter used to calculate the minimum assumed rate of carb absorption when carb effects aren't clearly reflected in your glucose readings."
                )
            }
            Section {
                number(
                    "Carb Prediction Percentage",
                    \.remainingCarbsFraction,
                    specs.remainingCarbsFraction,
                    presentation: .wheel
                ) } footer: {
                help(
                    "Carb Prediction Percentage",
                    "The maximum percentage of your original carb entry Trio can account for when predicting additional carb absorption."
                )
            }
            Section { number("Carb Prediction Limit", \.remainingCarbsCap, specs.remainingCarbsCap, presentation: .wheel)
            } footer: {
                help(
                    "Carb Prediction Limit",
                    "The maximum amount of additional carb absorption Trio can include in its glucose predictions."
                )
            }
        }
    }

    private var additionalSafety: some View {
        Group {
            Section {
                Toggle("UAM Predictions", isOn: model.preference(\.enableUAM))
            } footer: {
                help(
                    "UAM Predictions",
                    "Include predictions based on unexpected glucose changes. Your saved UAM setting is preserved."
                )
            }
            Section {
                Toggle("Very Low Glucose Warning", isOn: model.setting(\.confirmBolus))
            } footer: {
                help(
                    "Very Low Glucose Warning",
                    "Receive a warning prior to a manual bolus when your current or forecasted glucose is very low."
                )
            }
            Section { screen("Overrides", .overrideConfig) }
        }
    }

    private var notifications: some View {
        Group {
            Section("Configuration") {
                Button("Permissions") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Section {
                NavigationLink("System Alerts") { SettingsSystemAlertsView() }
                NavigationLink("Glucose Alerts") { SettingsAlertProfilesView(model: model) }
            }
            Section {
                screen("Live Activity", .liveActivitySettings)
            }
        }
    }

    private var customize: some View {
        Group {
            Section("App") {
                screen("Icon", .iconConfig)
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(ColorSchemeOption.systemDefault)
                    Text("Light").tag(ColorSchemeOption.light)
                    Text("Dark").tag(ColorSchemeOption.dark)
                }
            }
            Section("Home Screen") {
                link(.graph)
                Picker("Statistics Bar", selection: model.setting(\.homeStatsPanelFace)) {
                    ForEach(HomeStatsPanelFace.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("Bolus Screen") {
                screen("Quick-Pick Treatments", .quickPickTreatmentsConfig)
                screen("Carbs", .mealSettings)
            }
        }
    }

    private var graph: some View {
        Group {
            Section("Display") {
                Picker("Grid Lines", selection: model.gridLines) {
                    Text("None").tag(0)
                    Text("Horizontal").tag(1)
                    Text("Vertical").tag(2)
                    Text("Horizontal & Vertical").tag(3)
                }
            }
            Section {
                SettingsNumberRow(
                    title: "Lower Limit",
                    value: model.setting(\.low),
                    spec: specs.low,
                    units: model.units,
                    presentation: .wheel
                )
                SettingsNumberRow(
                    title: "Upper Limit",
                    value: model.setting(\.high),
                    spec: specs.high,
                    units: model.units,
                    presentation: .wheel
                )
                Toggle("Range Graph Lines", isOn: model.setting(\.rulerMarks))
            } header: { Text("Glucose") } footer: {
                help(
                    "Range",
                    "Set the glucose range used for graph lines, Color Style, and Statistics. This range is not used to calculate insulin delivery."
                )
            }
            Section {
                Picker("Color Style", selection: model.setting(\.glucoseColorScheme)) {
                    ForEach(GlucoseColorScheme.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: { help("Color Style", "Choose how glucose readings are colored on graphs and Live Activities.") }
            Section {
                Picker("Forecast Style", selection: model.setting(\.forecastDisplayType)) {
                    ForEach(ForecastDisplayType.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: { help("Forecast Style", "Choose how glucose forecasts are displayed on graphs.") }
            Section("Insulin") {
                Picker("Bolus Label Threshold", selection: model.setting(\.bolusDisplayThreshold)) {
                    ForEach(BolusDisplayThreshold.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    private var statisticsBar: some View {
        Section {
            Picker("Display Options", selection: model.setting(\.homeStatsPanelFace)) {
                ForEach(HomeStatsPanelFace.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    private var services: some View {
        Section {
            if HKHealthStore.isHealthDataAvailable() { screen("Apple Health", .healthkit) }
            screen("Nightscout", .nighscoutConfig)
            screen("Tidepool", .tidepoolConfig)
            screen("Shortcuts", .shortcutsConfig)
        }
    }

    private var caregivers: some View { Section { screen("Remote Control", .remoteControlConfig) } }

    private var support: some View {
        Group {
            Section {
                link(.community)
                SwiftUI.Link("Trio Help Guide", destination: URL(string: "https://triodocs.org")!)
            }
            Section {
                screen("Analytics Sharing", .appDiagnostics)
                Button("App Logs") { showLogs = true }
                SwiftUI.Link("Report a Bug", destination: URL(string: "https://github.com/nightscout/Trio/issues/new/choose")!)
            }
        }
    }

    private var community: some View {
        Section {
            SwiftUI.Link("Trio Discord", destination: URL(string: "https://discord.triodocs.org")!)
            SwiftUI.Link("Trio Facebook", destination: URL(string: "https://facebook.triodocs.org")!)
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.appDevVersion ?? "Unknown")
            LabeledContent("Build", value: Bundle.main.buildVersionNumber ?? "Unknown")
            LabeledContent("Branch", value: BuildDetails.shared.branchAndSha)
            NavigationLink("Components") { SubmodulesView(buildDetails: BuildDetails.shared) }
        }
    }

    private var logItems: [URL] {
        [SimpleLogReporter.logFile, SimpleLogReporter.logFilePrev]
            .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
