import CoreLocation
import MapKit
import SwiftUI

struct SettingsAlertProfilesView: View {
    @ObservedObject var model: SettingsFlowModel
    @ObservedObject private var store: SettingsAlertProfilesStore
    @State private var editing: SettingsAlertProfile?

    init(model: SettingsFlowModel, store: SettingsAlertProfilesStore = .shared) {
        self.model = model
        self.store = store
    }

    var body: some View {
        List {
            Section {
                SettingsHelpFooter(
                    title: "Glucose Alerts",
                    text: "Glucose alerts should only be enabled in one app at a time. To receive glucose alerts from Trio, disable alerts in your CGM app."
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.chart).tint(Color.tabBar)
            Section("Active Profiles") {
                ForEach(store.profiles.filter(\.isEnabled)) { profile in profileCard(profile) }
            }
            if store.profiles.contains(where: { !$0.isEnabled }) {
                Section("Disabled Profiles") {
                    ForEach(store.profiles.filter { !$0.isEnabled }) { profile in profileCard(profile) }
                }
            }
        }
        .listSectionSpacing(24)
        .settingsBackground().tint(.white)
        .navigationTitle("Glucose Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var alerts = store.profiles.first(where: \.isFallback)?.supportedAlerts ?? GlucoseAlertsStore.defaultAlerts()
                        .filter { $0.type != .carbsRequired }
                    for index in alerts.indices { alerts[index].id = UUID()
                        alerts[index].snoozedUntil = nil }
                    editing = SettingsAlertProfile(
                        name: String(localized: "New Profile"),
                        schedule: .init(kind: .time),
                        alerts: alerts
                    )
                } label: { Image(systemName: "plus") }.tint(.white)
                    .accessibilityLabel("Add Alert Profile")
            }
        }
        .sheet(item: $editing) { profile in
            SettingsAlertProfileEditor(initial: profile, units: model.units, store: store)
                .presentationDetents([.large]).presentationDragIndicator(.hidden)
        }
        .task { store.start() }
    }

    private func profileCard(_ profile: SettingsAlertProfile) -> some View {
        SettingsAlertProfileCard(profile: profile, units: model.units, enabled: Binding(
            get: { store.profiles.first { $0.id == profile.id }?.isEnabled ?? false },
            set: { store.setEnabled(profile.id, $0) }
        )) { editing = profile }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 16, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

struct SettingsAlertProfileCard: View {
    let profile: SettingsAlertProfile
    let units: GlucoseUnits
    @Binding var enabled: Bool
    let onEdit: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var cardColors: [Color] {
        if colorScheme == .light {
            return profile.isEnabled
                ? [Color(red: 0.78, green: 0.80, blue: 0.94), Color(red: 0.62, green: 0.68, blue: 0.86)]
                : [Color(red: 0.94, green: 0.95, blue: 0.97), Color(red: 0.85, green: 0.87, blue: 0.90)]
        }
        return profile.isEnabled
            ? [Color(red: 0.20, green: 0.25, blue: 0.42), Color(red: 0.08, green: 0.14, blue: 0.22)]
            : [Color(red: 0.11, green: 0.14, blue: 0.17), Color(red: 0.025, green: 0.055, blue: 0.075)]
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onEdit) {
                VStack(spacing: 16) {
                    HStack {
                        Label(profile.name, systemImage: profile.displaySymbol).font(.headline)
                        Spacer()
                        if !profile.isFallback { Color.clear.frame(width: 52, height: 32) }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .modifier(SettingsAlertRowGroup())
                    alertGroup([.urgentLow, .low, .high])
                    alertGroup([.forecastedLow, .fallingFast])
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.scheduleSummary)
                            if !profile.scheduleDetail
                                .isEmpty { Text(profile.scheduleDetail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: profile.schedule.kind == .location ? "location.fill" : "clock.fill")
                            .foregroundStyle(profile.isEnabled ? Color.tabBar : Color.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .modifier(SettingsAlertRowGroup())
                }
                .padding(16)
                .foregroundStyle(profile.isEnabled ? Color.primary : Color.secondary)
                .background(
                    LinearGradient(
                        colors: cardColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 28)
                )
                .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                .contentShape(RoundedRectangle(cornerRadius: 28))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(profile.name) alert profile")
            if !profile.isFallback {
                Toggle(profile.name, isOn: $enabled)
                    .labelsHidden()
                    .tint(Color.tabBar)
                    .fixedSize()
                    .padding(.top, 22)
                    .padding(.trailing, 32)
            }
        }
    }

    @ViewBuilder private func alertGroup(_ types: [GlucoseAlertType]) -> some View {
        let alerts = types.compactMap { type in profile.supportedAlerts.first { $0.type == type && $0.shouldEvaluate } }
        if !alerts.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alarm in
                    if index > 0 { Divider() }
                    SettingsAlertSummaryRow(alert: alarm, units: units)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 16)
            .modifier(SettingsAlertRowGroup())
        }
    }
}

private struct SettingsAlertRowGroup: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
    }
}

extension SettingsAlertProfile {
    var scheduleSummary: String {
        switch schedule.kind {
        case .always: return isFallback ? String(localized: "Default") : String(localized: "Always")
        case .location: return schedule.locationName
        case .time:
            return "\(clock(schedule.startMinute)) – \(clock(schedule.endMinute))" +
                (schedule.endMinute <= schedule.startMinute ? String(localized: " (+1 Day)") : "")
        }
    }

    var editorScheduleSummary: String {
        guard schedule.kind == .time else { return scheduleSummary }
        let minutes = (schedule.endMinute - schedule.startMinute + 1440) % 1440
        let duration = minutes == 0 ? 1440 : minutes
        let time = duration % 60 == 0 ? "\(duration / 60) hr" : "\(duration / 60) hr \(duration % 60) min"
        let repeatTitle = schedule.weekdays.count == 7 ? String(localized: "Daily") : String(localized: "Weekly")
        return "\(repeatTitle) · \(clock(schedule.startMinute)) · \(time)"
    }

    var scheduleDetail: String {
        switch schedule.kind {
        case .always: return isFallback ? String(localized: "When no scheduled profile is active") : ""
        case .location: return String(localized: "While at this Location")
        case .time:
            if schedule.weekdays.count == 7 { return String(localized: "Every Day") }
            if schedule.weekdays == Set(2 ... 6) { return String(localized: "Weekdays") }
            return schedule.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        }
    }

    private func clock(_ minute: Int) -> String {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minute * 60))
            .formatted(date: .omitted, time: .shortened)
    }
}

struct SettingsAlertSummaryRow: View {
    let alert: GlucoseAlert
    let units: GlucoseUnits
    var showOff = false

    var body: some View {
        HStack {
            Text(alert.type.settingsTitle)
            Spacer(minLength: 8)
            if showOff && !alert.shouldEvaluate { Text("Off").foregroundStyle(.secondary) }
            else {
                Image(systemName: alert.settingsSoundMode.symbol).accessibilityLabel(alert.settingsSoundMode.title)
                    .foregroundStyle(.secondary)
                Text(alert.settingsDelivery.title).foregroundStyle(.secondary)
                if alert.type == .urgentLow || alert.type == .low || alert.type == .high {
                    Text("·").foregroundStyle(.secondary)
                    Text(alert.thresholdMgDL.formatted(withUnits: units).replacingOccurrences(of: " \(units.rawValue)", with: ""))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.body)
    }
}

extension GlucoseAlertType {
    var settingsTitle: String {
        switch self {
        case .urgentLow: return String(localized: "Urgent Low")
        case .low: return String(localized: "Low")
        case .high: return String(localized: "High")
        case .forecastedLow: return String(localized: "Urgent Low Soon")
        case .fallingFast: return String(localized: "Falling Fast")
        case .carbsRequired: return String(localized: "Carbs Required")
        }
    }
}

extension GlucoseAlert {
    var settingsDelivery: SettingsAlertDelivery { delivery ?? (overridesSilenceAndDND ? .alarm : .timeSensitive) }
    var settingsSoundMode: SettingsAlertSoundMode {
        soundMode ?? (playsSound ? (overridesSilenceAndDND ? .soundAlways : .matchPhone) : .vibrateAlways) }
}

struct SettingsAlertProfileEditor: View {
    let units: GlucoseUnits
    @ObservedObject var store: SettingsAlertProfilesStore
    @State private var working: SettingsAlertProfile
    @State private var showingSchedule = false
    @Environment(\.dismiss) private var dismiss

    init(initial: SettingsAlertProfile, units: GlucoseUnits, store: SettingsAlertProfilesStore) {
        self.units = units
        self.store = store
        _working = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("Name") {
                        NavigationLink {
                            Form {
                                Section { TextField("Name", text: $working.name) }.listRowBackground(Color.chart)
                                    .tint(Color.tabBar)
                                Section {
                                    Picker(
                                        "Symbol",
                                        selection: Binding(get: { working.displaySymbol }, set: { working.symbol = $0 })
                                    ) {
                                        ForEach(
                                            [
                                                "bell.fill",
                                                "sun.max.fill",
                                                "moon.fill",
                                                "briefcase.fill",
                                                "house.fill",
                                                "figure.run"
                                            ],
                                            id: \.self
                                        ) { Image(systemName: $0).tag($0) }
                                    }.pickerStyle(.menu)
                                }.listRowBackground(Color.chart).tint(Color.tabBar)
                            }.settingsBackground().tint(.white).navigationTitle("Name")
                        } label: { Label(working.name, systemImage: working.displaySymbol) }
                    }.listRowBackground(Color.chart).tint(Color.tabBar)
                    Section("Schedule") {
                        if working.isFallback {
                            LabeledContent("Default", value: "Always")
                        } else {
                            Button { showingSchedule = true } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(working.editorScheduleSummary)
                                        Text(working.scheduleDetail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: working.schedule.kind == .location ? "location.fill" : "clock.fill")
                                        .foregroundStyle(Color.tabBar)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }.foregroundStyle(Color.primary)
                        }
                    }
                    Section("Glucose Alerts") { editorAlertRows([.urgentLow, .low, .high]) }.listRowBackground(Color.chart)
                        .tint(Color.tabBar)
                    Section { editorAlertRows([.forecastedLow, .fallingFast]) }.listRowBackground(Color.chart)
                        .tint(Color.tabBar)
                    Section {
                        Button("Delete Profile", role: .destructive) {
                            if store.profiles.contains(where: { $0.id == working.id }) { store.remove(working) }
                            dismiss()
                        }
                        .disabled(working.isFallback)
                    } footer: {
                        if working.isFallback {
                            Text("The Default profile applies when no scheduled profile is active and cannot be deleted.")
                        }
                    }
                }.listRowBackground(Color.chart).tint(Color.tabBar)
            }
            .settingsBackground().tint(.white)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.white).accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { store.save(working)
                        dismiss() } label: { Image(systemName: "checkmark") }.tint(Color.tabBar)
                        .accessibilityLabel("Save Profile")
                        .disabled(working.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingSchedule) {
                SettingsAlertScheduleEditor(initial: working.schedule, store: store) { working.schedule = $0 }
                    .presentationDetents([.large]).presentationDragIndicator(.hidden)
            }
        }
    }

    @ViewBuilder private func editorAlertRows(_ types: [GlucoseAlertType]) -> some View {
        ForEach(types, id: \.self) { type in
            if let index = working.alerts.firstIndex(where: { $0.type == type }) {
                NavigationLink {
                    SettingsProfileAlertEditor(alert: $working.alerts[index], units: units)
                } label: {
                    SettingsAlertSummaryRow(alert: working.alerts[index], units: units, showOff: true)
                }.foregroundStyle(Color.primary)
            }
        }
    }
}

struct SettingsAlertScheduleEditor: View {
    @ObservedObject var store: SettingsAlertProfilesStore
    let onSave: (SettingsAlertSchedule) -> Void
    @State private var working: SettingsAlertSchedule
    @State private var query = ""
    @State private var places: [MKMapItem] = []
    @State private var searchError: String?
    @Environment(\.dismiss) private var dismiss

    init(initial: SettingsAlertSchedule, store: SettingsAlertProfilesStore, onSave: @escaping (SettingsAlertSchedule) -> Void) {
        self.store = store
        self.onSave = onSave
        var initial = initial
        if initial.kind == .always { initial.kind = .time }
        _working = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Picker("Configuration", selection: $working.kind) {
                            Text("Time").tag(SettingsAlertSchedule.Kind.time)
                            Text("Location").tag(SettingsAlertSchedule.Kind.location)
                        }.pickerStyle(.segmented)
                    } footer: {
                        SettingsHelpFooter(
                            title: "Schedule",
                            text: "Automatically activate this profile at a scheduled time or location. If schedules overlap, location-based schedules take priority.",
                            detail: "Within the same schedule type, the first matching profile in the list takes priority. The Default profile applies when no scheduled profile is active. An overnight schedule belongs to the day on which it starts. Time schedules follow your device's current time zone."
                        )
                    }
                    if working.kind == .time {
                        Section {
                            DatePicker("Start", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                        }
                        Section {
                            Picker("Repeat", selection: repeatSelection) {
                                Text("Daily").tag("daily")
                                Text("Weekdays").tag("weekdays")
                                Text("Weekends").tag("weekends")
                                Text("Weekly").tag("weekly")
                            }.pickerStyle(.menu)
                            HStack {
                                ForEach(1 ... 7, id: \.self) { day in
                                    Button {
                                        if working.weekdays.contains(day) { working.weekdays.remove(day) }
                                        else { working.weekdays.insert(day) }
                                    } label: { Text(Calendar.current.veryShortWeekdaySymbols[day - 1]).frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .buttonBorderShape(.circle)
                                    .tint(working.weekdays.contains(day) ? Color.tabBar : Color.secondary.opacity(0.3))
                                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                                    .accessibilityAddTraits(working.weekdays.contains(day) ? .isSelected : [])
                                }
                            }
                        } footer: {
                            Text(
                                working.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
                                    .joined(separator: ", ")
                            ) }
                            .listRowBackground(Color.chart).tint(Color.tabBar)
                    }
                    if working.kind == .location {
                        Section {
                            TextField("Search Locations", text: $query).submitLabel(.search)
                                .onSubmit { Task { await searchPlaces() } }
                            ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                                Button(place.name ?? String(localized: "Location")) {
                                    working.locationName = place.name ?? query
                                    working.latitude = place.placemark.coordinate.latitude
                                    working.longitude = place.placemark.coordinate.longitude
                                    places = []
                                }
                            }
                            if let searchError { Text(searchError).foregroundStyle(.secondary) }
                        }
                        if !working.locationName.isEmpty {
                            Section {
                                TextField("Location Name", text: $working.locationName)
                                Map(initialPosition: .region(MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: working.latitude, longitude: working.longitude),
                                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                                ))) {
                                    MapCircle(
                                        center: CLLocationCoordinate2D(latitude: working.latitude, longitude: working.longitude),
                                        radius: working.radius
                                    ).foregroundStyle(Color.tabBar.opacity(0.2))
                                }
                                .frame(height: 220)
                                Stepper("Radius: \(Int(working.radius)) m", value: $working.radius, in: 100 ... 2000, step: 100)
                            }
                        }
                        Section {
                            Button("Enable Location Profiles") { store.requestLocationAccess() }
                            if store.locationAuthorization == .authorizedWhenInUse {
                                Button("Allow Background Location") { store.requestLocationAccess() }
                            }
                            if let error = store.locationError { Text(error).foregroundStyle(.secondary) }
                        } footer: {
                            Text(
                                "Location profiles use region entry and exit events. Allow Always location access for automatic activation while Trio is in the background."
                            )
                        }
                    }
                }.listRowBackground(Color.chart).tint(Color.tabBar)
            }
            .settingsBackground().tint(.white)
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.white).accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onSave(working)
                        dismiss() } label: { Image(systemName: "checkmark") }.tint(Color.tabBar)
                        .accessibilityLabel("Save Schedule")
                        .disabled(
                            (working.kind == .time && working.weekdays.isEmpty) ||
                                (working.kind == .location && working.locationName.isEmpty)
                        )
                }
            }
        }
    }

    private var repeatSelection: Binding<String> {
        Binding(get: {
            if working.weekdays == Set(1 ... 7) { return "daily" }
            if working.weekdays == Set(2 ... 6) { return "weekdays" }
            if working.weekdays == Set([1, 7]) { return "weekends" }
            return "weekly"
        }, set: { value in
            switch value {
            case "daily": working.weekdays = Set(1 ... 7)
            case "weekdays": working.weekdays = Set(2 ... 6)
            case "weekends": working.weekdays = [1, 7]
            default: break
            }
        })
    }

    private func minuteBinding(_ key: WritableKeyPath<SettingsAlertSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(working[keyPath: key] * 60))
        }, set: {
            working[keyPath: key] = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current
                .component(.minute, from: $0)
        })
    }

    private func searchPlaces() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do { places = try await MKLocalSearch(request: request).start().mapItems
            searchError = nil } catch { searchError = error.localizedDescription }
    }
}

struct SettingsProfileAlertEditor: View {
    @Binding var working: GlucoseAlert
    let units: GlucoseUnits

    init(alert: Binding<GlucoseAlert>, units: GlucoseUnits) {
        _working = alert
        self.units = units
    }

    var body: some View {
        Form {
            Group {
                Section("Configuration") {
                    if working.type == .forecastedLow {
                        Toggle("Urgent Low Soon", isOn: $working.isEnabled)
                    } else {
                        SettingsNumberRow(
                            title: working.type.settingsTitle,
                            value: thresholdSelection,
                            spec: thresholdSpec,
                            units: units,
                            suffix: working.type == .fallingFast ? (units == .mmolL ? "mmol/L/min" : "mg/dL/min") : nil,
                            includeOff: working.type != .urgentLow,
                            displayTransform: { working.type == .fallingFast && units == .mmolL ? $0.asMmolL : $0 },
                            presentation: .wheel
                        )
                    }
                }.listRowBackground(Color.chart).tint(Color.tabBar)
                Section {
                    SettingsAlertDeliveryRow(selection: Binding(
                        get: { working.delivery ?? (working.overridesSilenceAndDND ? .alarm : .timeSensitive) },
                        set: {
                            working.delivery = $0
                            working.overridesSilenceAndDND = $0 != .timeSensitive
                            if $0 == .timeSensitive, working.soundMode == .soundAlways {
                                working.soundMode = .matchPhone
                            }
                            if $0 == .alarm { Task { await CriticalAlertAlarmScheduler.requestAuthorization() } }
                        }
                    ))
                    NavigationLink {
                        SettingsAlertSoundView(
                            mode: soundSelection,
                            filename: $working.soundFilename,
                            delivery: working.settingsDelivery
                        )
                    } label: { LabeledContent("Sound", value: working.settingsSoundMode.title) }
                }.listRowBackground(Color.chart).tint(Color.tabBar)

                Section {
                    SettingsNumberRow(
                        title: "Alert Snooze",
                        value: Binding(get: { Decimal(working.snoozeMinutes ?? 15) }, set: {
                            working.snoozeMinutes = NSDecimalNumber(decimal: $0).intValue
                        }),
                        spec: PickerSetting(value: 15, step: 5, min: 5, max: 60, type: .minute),
                        presentation: .wheel
                    )
                } footer: {
                    SettingsHelpFooter(
                        title: "Alert Snooze",
                        text: "How long to wait after this alert is acknowledged before sending another alert for this same condition."
                    )
                }
            }.listRowBackground(Color.chart).tint(Color.tabBar)
        }
        .settingsBackground().tint(.white)
        .navigationTitle(working.type == .low ? String(localized: "Low Glucose Alert") : working.type.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var thresholdSelection: Binding<Decimal> {
        Binding(get: { working.shouldEvaluate ? working.thresholdMgDL : 0 }, set: { value in
            guard value > 0 || working.type != .urgentLow else { return }
            working.isEnabled = value > 0
            if value > 0 { working.thresholdMgDL = value }
        })
    }

    private var soundSelection: Binding<SettingsAlertSoundMode> {
        Binding(get: { working.settingsSoundMode }, set: { mode in
            working.soundMode = mode
            working.playsSound = mode != .vibrateAlways
        })
    }

    private var thresholdSpec: PickerSetting {
        switch working.type {
        case .urgentLow: return PickerSetting(value: 54, step: 1, min: 54, max: 80, type: .glucose)
        case .forecastedLow,
             .low: return PickerSetting(value: 72, step: 1, min: 54, max: 100, type: .glucose)
        case .high: return PickerSetting(value: 270, step: 1, min: 100, max: 400, type: .glucose)
        case .carbsRequired: return PickerSetting(value: 10, step: 1, min: 5, max: 50, type: .gram)
        case .fallingFast: return PickerSetting(value: 2, step: 0.5, min: 0.5, max: 10, type: .glucose)
        }
    }
}

struct SettingsAlertSoundView: View {
    @Binding var mode: SettingsAlertSoundMode
    @Binding var filename: String
    let delivery: SettingsAlertDelivery
    @StateObject private var previewer = SoundPreviewPlayer()

    var body: some View {
        Form {
            Section {
                SettingsHelpFooter(
                    title: "Sound or Vibrate",
                    text: "Sound Always is not available for Time Sensitive alerts as they cannot override Silent mode."
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }.listRowBackground(Color.chart).tint(Color.tabBar)
            Section {
                ForEach(SettingsAlertSoundMode.allCases) { choice in
                    Button {
                        mode = choice
                        if choice == .vibrateAlways { previewer.stop() }
                        else { previewer.play(filename: filename) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(choice.title, systemImage: choice.symbol).font(.headline).lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(choice.detail).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.tabBar)
                                .frame(width: 24)
                                .opacity(mode == choice ? 1 : 0)
                                .accessibilityHidden(true)
                        }.padding(.vertical, 8)
                    }
                    .foregroundStyle(Color.primary)
                    .disabled(choice == .soundAlways && delivery == .timeSensitive)
                }
            }.listRowBackground(Color.chart).tint(Color.tabBar)
            if mode != .vibrateAlways {
                Section {
                    NavigationLink {
                        SettingsAlertToneList(filename: $filename)
                    } label: { LabeledContent("Sound", value: AlarmSoundCatalog.displayName(for: filename)) }
                }.listRowBackground(Color.chart).tint(Color.tabBar)
            }
        }
        .settingsBackground().tint(.white)
        .navigationTitle("Sound or Vibrate")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewer.stop() }
    }
}

extension SettingsAlertSoundMode {
    var detail: String {
        switch self {
        case .soundAlways: return String(localized: "This alert will play a sound, even when your phone is set to Silent.")
        case .vibrateAlways: return String(localized: "This alert will vibrate without sound, even when your phone is set to Ring.")
        case .matchPhone: return String(
                localized: "When your phone is set to Ring, this alert will play a sound. When your phone is set to Silent, this alert will vibrate."
            )
        }
    }
}

struct SettingsAlertToneList: View {
    @Binding var filename: String
    @StateObject private var previewer = SoundPreviewPlayer()

    var body: some View {
        Form {
            Section {
                ForEach(AlarmSoundCatalog.allFilenames, id: \.self) { sound in
                    Button {
                        filename = sound
                        previewer.play(filename: sound)
                    } label: {
                        HStack {
                            Text(AlarmSoundCatalog.displayName(for: sound))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.tabBar)
                                .frame(width: 24)
                                .opacity(filename == sound ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .accessibilityAddTraits(filename == sound ? .isSelected : [])
                }
            }.listRowBackground(Color.chart).tint(Color.tabBar)
        }
        .settingsBackground().tint(.white)
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewer.stop() }
    }
}
