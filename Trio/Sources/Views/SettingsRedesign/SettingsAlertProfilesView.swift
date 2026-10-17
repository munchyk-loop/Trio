import CoreLocation
import MapKit
import SwiftUI

struct SettingsAlertProfilesView: View {
    @ObservedObject var model: SettingsFlowModel
    @ObservedObject private var store = SettingsAlertProfilesStore.shared
    @ObservedObject private var alertsStore = GlucoseAlertsStore.shared
    @State private var editing: SettingsAlertProfile?

    var body: some View {
        List {
            Section {
                Toggle("Use Trio Glucose Alerts", isOn: $alertsStore.configuration.forceTrioAlertsWhenCGMProvidesOwn)
            } footer: {
                SettingsHelpFooter(
                    title: "Glucose Alerts",
                    text: "Glucose alerts should only be enabled in one app at a time. To receive glucose alerts from Trio, disable alerts in your CGM app."
                )
            }
            Section("Active Profiles") {
                ForEach(store.profiles.filter(\.isEnabled)) { profile in profileRow(profile) }
            }
            if store.profiles.contains(where: { !$0.isEnabled }) {
                Section("Disabled Profiles") {
                    ForEach(store.profiles.filter { !$0.isEnabled }) { profile in profileRow(profile) }
                }
            }
        }
        .navigationTitle("Glucose Alerts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var alerts = store.profiles.first(where: \.isFallback)?.alerts ?? alertsStore.alerts
                    for index in alerts.indices { alerts[index].id = UUID()
                        alerts[index].snoozedUntil = nil }
                    editing = SettingsAlertProfile(name: String(localized: "New Profile"), alerts: alerts)
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Alert Profile")
            }
        }
        .sheet(item: $editing) { profile in
            SettingsAlertProfileEditor(initial: profile, units: model.units, store: store)
                .presentationDetents([.large]).presentationDragIndicator(.hidden)
        }
        .task { store.start() }
    }

    private func profileRow(_ profile: SettingsAlertProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { editing = profile } label: {
                    HStack {
                        Text(profile.name).font(.headline)
                        if store.activeID == profile
                            .id { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Currently Active") }
                    }
                }.buttonStyle(.borderless)
                Spacer()
                if !profile.isFallback {
                    Toggle(profile.name, isOn: Binding(
                        get: { store.profiles.first { $0.id == profile.id }?.isEnabled ?? false },
                        set: { store.setEnabled(profile.id, $0) }
                    )).labelsHidden()
                }
            }
            ForEach(profile.alerts.filter { $0.shouldEvaluate }) { alarm in
                HStack {
                    Text(alarm.type == .forecastedLow ? String(localized: "Urgent Low Soon") : alarm.type.displayName)
                    Spacer()
                    Text(
                        alarm.delivery?
                            .title ??
                            (alarm.overridesSilenceAndDND ? String(localized: "Alarm") : String(localized: "Time Sensitive"))
                    )
                    .foregroundStyle(.secondary)
                    if alarm.type != .forecastedLow {
                        Text(
                            alarm.type == .carbsRequired ? "\(alarm.thresholdMgDL) g" :
                                alarm.thresholdMgDL.formatted(withUnits: model.units) +
                                (alarm.type == .fallingFast ? "/min" : "")
                        )
                        .foregroundStyle(.secondary)
                    }
                }.font(.subheadline)
            }
            Button { editing = profile } label: {
                Label(scheduleDescription(profile), systemImage: profile.schedule.kind == .location ? "location.fill" : "clock")
                    .font(.caption)
            }.buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private func scheduleDescription(_ profile: SettingsAlertProfile) -> String {
        switch profile.schedule.kind {
        case .always: return profile
            .isFallback ? String(localized: "When no scheduled profile is active") : String(localized: "Always")
        case .location: return profile.schedule.locationName
        case .time:
            return "\(clock(profile.schedule.startMinute)) – \(clock(profile.schedule.endMinute))"
        }
    }

    private func clock(_ minute: Int) -> String {
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minute * 60))
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct SettingsAlertProfileEditor: View {
    let units: GlucoseUnits
    @ObservedObject var store: SettingsAlertProfilesStore
    @State private var working: SettingsAlertProfile
    @State private var showingSchedule = false
    @State private var editingAlert: GlucoseAlert?
    @Environment(\.dismiss) private var dismiss

    init(initial: SettingsAlertProfile, units: GlucoseUnits, store: SettingsAlertProfilesStore) {
        self.units = units
        self.store = store
        _working = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $working.name) }
                if !working.isFallback {
                    Section("Schedule") {
                        Button { showingSchedule = true } label: {
                            LabeledContent(
                                "Schedule",
                                value: working.schedule.kind == .location ? working.schedule.locationName :
                                    working.schedule.kind == .time ? String(localized: "Time") : String(localized: "Always")
                            )
                        }
                    }
                }
                Section("Glucose Alerts") {
                    ForEach(working.alerts) { alarm in
                        Button { editingAlert = alarm } label: {
                            LabeledContent(alarm.type.displayName) {
                                Text(
                                    alarm
                                        .shouldEvaluate ? (alarm.delivery?.title ?? String(localized: "Configured")) :
                                        String(localized: "Off")
                                )
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                if !working.isFallback, store.profiles.contains(where: { $0.id == working.id }) {
                    Section {
                        Button("Delete Profile", role: .destructive) { store.remove(working)
                            dismiss() }
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { store.save(working)
                        dismiss() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Save Profile")
                        .disabled(working.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingSchedule) {
                SettingsAlertScheduleEditor(initial: working.schedule, store: store) { working.schedule = $0 }
                    .presentationDetents([.large]).presentationDragIndicator(.hidden)
            }
            .sheet(item: $editingAlert) { alert in
                SettingsProfileAlertEditor(initial: alert, units: units) { updated in
                    if let index = working.alerts.firstIndex(where: { $0.id == updated.id }) { working.alerts[index] = updated }
                }.presentationDetents([.large]).presentationDragIndicator(.hidden)
            }
        }
    }
}

private struct SettingsAlertScheduleEditor: View {
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
        _working = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Configuration", selection: $working.kind) {
                        Text("Always").tag(SettingsAlertSchedule.Kind.always)
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
                    Section("Repeat") {
                        ForEach(1 ... 7, id: \.self) { day in
                            Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(
                                get: { working.weekdays.contains(day) },
                                set: { if $0 { working.weekdays.insert(day) } else { working.weekdays.remove(day) } }
                            ))
                        }
                    }
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
                                ).foregroundStyle(Color.accentColor.opacity(0.2))
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
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onSave(working)
                        dismiss() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Save Schedule")
                        .disabled(
                            (working.kind == .time && working.weekdays.isEmpty) ||
                                (working.kind == .location && working.locationName.isEmpty)
                        )
                }
            }
        }
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

private struct SettingsProfileAlertEditor: View {
    let units: GlucoseUnits
    let onSave: (GlucoseAlert) -> Void
    @State private var working: GlucoseAlert
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewer = SoundPreviewPlayer()

    init(initial: GlucoseAlert, units: GlucoseUnits, onSave: @escaping (GlucoseAlert) -> Void) {
        self.units = units
        self.onSave = onSave
        _working = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Configuration") {
                    if working.type != .urgentLow { Toggle("Enabled", isOn: $working.isEnabled) }
                    if working.type == .fallingFast {
                        SettingsNumberRow(
                            title: "Fall Rate",
                            value: $working.thresholdMgDL,
                            spec: thresholdSpec,
                            units: units,
                            suffix: units == .mmolL ? "mmol/L/min" : "mg/dL/min",
                            displayTransform: { units == .mmolL ? $0.asMmolL : $0 }
                        )
                    } else if working.type != .forecastedLow {
                        SettingsNumberRow(
                            title: working.type == .carbsRequired ? "Carbs" : "Glucose",
                            value: $working.thresholdMgDL, spec: thresholdSpec, units: units
                        )
                    }
                    Picker("Delivery", selection: Binding(
                        get: { working.delivery ?? (working.overridesSilenceAndDND ? .alarm : .timeSensitive) },
                        set: {
                            working.delivery = $0
                            working.overridesSilenceAndDND = $0 != .timeSensitive
                            if $0 == .timeSensitive, working.soundMode == .soundAlways {
                                working.soundMode = .matchPhone
                            }
                            if $0 == .alarm { Task { await CriticalAlertAlarmScheduler.requestAuthorization() } }
                        }
                    )) {
                        ForEach(SettingsAlertDelivery.allCases) { Text($0.title).tag($0) }
                    }
                    NavigationLink {
                        Form {
                            Picker("Sound or Vibrate", selection: Binding(
                                get: {
                                    working
                                        .soundMode ??
                                        (
                                            working
                                                .playsSound ? (working.overridesSilenceAndDND ? .soundAlways : .matchPhone) :
                                                .vibrateAlways
                                        )
                                },
                                set: { working.soundMode = $0
                                    working.playsSound = $0 != .vibrateAlways }
                            )) {
                                ForEach(SettingsAlertSoundMode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                                        .disabled(
                                            mode == .soundAlways &&
                                                (
                                                    working
                                                        .delivery ?? (working.overridesSilenceAndDND ? .alarm : .timeSensitive)
                                                ) ==
                                                .timeSensitive
                                        )
                                }
                            }.pickerStyle(.inline).labelsHidden()
                            Section {
                                Text(
                                    "Sound Always requires Critical or Alarm delivery. Notification and haptic behavior also follows the permissions granted in iOS Settings."
                                )
                            }
                        }.navigationTitle("Sound or Vibrate")
                    } label: {
                        LabeledContent(
                            "Sound",
                            value: working.soundMode?
                                .title ??
                                (working.playsSound ? String(localized: "Configured") : String(localized: "Vibrate Always"))
                        )
                    }
                    if working.playsSound {
                        Picker("Sound", selection: $working.soundFilename) {
                            ForEach(AlarmSoundCatalog.allFilenames, id: \.self) {
                                Text(AlarmSoundCatalog.displayName(for: $0)).tag($0) }
                        }
                        Button("Preview Sound", systemImage: "play.circle") { previewer.toggle(filename: working.soundFilename) }
                    }
                }
                Section {
                    Picker("Alert Snooze", selection: Binding(
                        get: { working.snoozeMinutes ?? 15 }, set: { working.snoozeMinutes = $0 }
                    )) {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                } footer: {
                    SettingsHelpFooter(
                        title: "Alert Snooze",
                        text: "How long to wait after this alert is acknowledged before sending another alert for this same condition."
                    )
                }
            }
            .navigationTitle(working.type.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onSave(working)
                        dismiss() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Save Alert")
                }
            }
            .onDisappear { previewer.stop() }
        }
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
