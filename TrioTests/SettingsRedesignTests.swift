import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Trio

@Suite("Settings Redesign", .serialized) struct SettingsRedesignTests {
    @Test("Native settings forms mount in a navigation stack")
    @MainActor func nativeFormsRender() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        let model = SettingsFlowModel(resolver: TrioApp.resolver)
        var screens: [(String, AnyView)] = [
            ("settings", AnyView(Settings.RootView(resolver: TrioApp.resolver)))
        ]
        screens += SettingsFlowPage.allCases.filter { $0 != .personalInformation }.map { page in
            (page.rawValue, AnyView(SettingsFlowPageView(page: page, model: model)))
        }
        screens += [
            ("watch-destination", AnyView(SettingsScreenDestination(screen: .watch, resolver: TrioApp.resolver))),
            (
                "search-results",
                AnyView(List { SettingsFlowSearchResults(query: "noisy cgm", model: model) }.settingsBackground())
            ),
            (
                "help-card",
                AnyView(SettingsHelpSheet(
                    title: "Smooth CGM Readings",
                    text: "Smooth your CGM readings to reduce erratic jumps and better reflect natural glucose trends."
                ))
            )
        ]
        screens += [
            (
                "number-detail",
                AnyView(SettingsNumberRow(
                    title: "Insulin on Board (IOB)",
                    value: .constant(5),
                    spec: PickerSettingsProvider.shared.settings.maxIOB
                ).detailView)
            ),
            (
                "number-wheel",
                AnyView(SettingsNumberRow(
                    title: "Duration of Insulin Action",
                    value: .constant(10),
                    spec: PickerSettingsProvider.shared.settings.dia
                ).wheelContent)
            )
        ]
        let avatarFormat = UIGraphicsImageRendererFormat()
        avatarFormat.scale = 1
        let avatarImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160), format: avatarFormat).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 120, y: 0, width: 80, height: 160))
        }
        screens += [("profile-avatars", AnyView(HStack(spacing: 24) {
            SettingsProfileAvatar(profile: SettingsUserProfile(name: "Olivia Rose Wilson"), size: 76)
            SettingsProfileAvatar(
                profile: SettingsUserProfile(name: "Olivia Rose Wilson", photoData: avatarImage.pngData()),
                size: 76
            )
        }))]
        let suite = "settings-render-alerts-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alerts = GlucoseAlertsStore(defaults: defaults)
        let profiles = SettingsAlertProfilesStore(defaults: defaults, alertsStore: alerts)
        let night = SettingsAlertProfile(
            name: "Night",
            symbol: "moon.fill",
            schedule: .init(kind: .time, startMinute: 22 * 60, endMinute: 7 * 60 + 30, weekdays: [1, 2, 3, 4, 5]),
            alerts: SettingsAlertProfilesStore.defaultProfiles()[0].alerts
        )
        profiles.save(night)
        var day = night
        day.id = UUID()
        day.name = "Day"
        day.symbol = "sun.max.fill"
        day.isEnabled = false
        profiles.save(day)
        screens += [
            (
                "alerts-disabled-card",
                AnyView(ScrollView { SettingsAlertProfileCard(profile: day, units: .mgdL, enabled: .constant(false)) {}.padding()
                }.settingsBackground())
            ),
            ("loop-mode-closed", AnyView(SettingsLoopModeSheet(selection: .constant(.closed), canSelect: true))),
            ("loop-mode-partial", AnyView(SettingsLoopModeSheet(selection: .constant(.lowGlucoseSuspend), canSelect: true))),
            ("loop-mode-open", AnyView(SettingsLoopModeSheet(selection: .constant(.open), canSelect: true))),
            ("alerts-tones", AnyView(SettingsAlertToneList(filename: .constant("trill.caf")))),
            ("system-alerts", AnyView(SettingsSystemAlertsView())),
            (
                "alerts-default-editor",
                AnyView(SettingsAlertProfileEditor(initial: profiles.profiles.last!, units: .mgdL, store: profiles))
            ),
            ("alerts-profiles", AnyView(SettingsAlertProfilesView(model: model, store: profiles))),
            ("alerts-editor", AnyView(SettingsAlertProfileEditor(initial: night, units: .mgdL, store: profiles))),
            ("alerts-schedule", AnyView(SettingsAlertScheduleEditor(initial: night.schedule, store: profiles) { _ in })),
            ("alerts-low", AnyView(SettingsProfileAlertEditor(alert: .constant(GlucoseAlert(type: .low)), units: .mgdL))),
            ("alerts-delivery", AnyView(SettingsAlertDeliveryView(selection: .constant(.critical)))),
            (
                "alerts-sound",
                AnyView(SettingsAlertSoundView(
                    mode: .constant(.matchPhone),
                    filename: .constant("trill.caf"),
                    delivery: .critical
                ))
            ),
            ("search-empty", AnyView(List { SettingsFlowSearchResults(query: "", model: model) }.settingsBackground())),
            (
                "search-no-results",
                AnyView(List { SettingsFlowSearchResults(query: "definitely absent setting", model: model) }.settingsBackground())
            ),
            (
                "range-wheels",
                AnyView(SettingsGlucoseRangeRow(lower: .constant(70), upper: .constant(170), units: .mgdL).pickerContent)
            ),
            ("backup-home", AnyView(TrioCloudBackupView())),
            ("backup-configuration", AnyView(TrioCloudBackupConfigurationView()))
        ]
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SettingsReview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, screen) in screens {
            window.overrideUserInterfaceStyle = .dark
            let controller = UIHostingController(rootView: NavigationStack { screen }
                .environment(AppState())
                .environment(SettingsSearchHighlight()))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
            if name == "settings" || name == "help-card" || name == "alerts-profiles" || name == "backup-home" {
                window.overrideUserInterfaceStyle = .light
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutIfNeeded()
                let light = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try #require(light.pngData()).write(to: directory.appendingPathComponent(name + "-light.png"))
            }
        }
    }

    @Test("Settings navigation values stay small enough for the iPhone stack") func navigationStackBudget() {
        // Forms and navigation closures copy these values while constructing destinations.
        // Storing the entire picker catalogue here caused a device stack overflow.
        #expect(MemoryLayout<SettingsFlowPageView>.stride < 1024)
        #expect(MemoryLayout<SettingsScreenDestination>.stride < 256)
    }

    @Test("Excluded controls cannot return through search") func excludedSearch() {
        for query in [
            "show IOB COB",
            "rewind resets",
            "skip neutral",
            "suspension resets",
            "additional display",
            "calendar",
            "display meal presets"
        ] {
            #expect(SettingsFlowSearchEntry.matching(query).isEmpty)
        }
    }

    @Test("Removed settings use backend defaults without changing therapy values") func backendDefaults() {
        var settings = TrioSettings()
        settings.displayPresets = false
        settings.useCalendar = true
        settings.showCobIobChart = false
        settings.showCarbsRequiredBadge = false
        settings.carbsRequiredThreshold = 99
        settings.requireAdjustmentsConfirmation = true
        settings.overrideFactor = 0.65
        BaseSettingsManager.applySettingsFlowDefaults(to: &settings)
        #expect(settings.displayPresets)
        #expect(!settings.useCalendar)
        #expect(settings.showCobIobChart)
        #expect(settings.showCarbsRequiredBadge)
        #expect(settings.carbsRequiredThreshold == 10)
        #expect(!settings.requireAdjustmentsConfirmation)
        #expect(settings.overrideFactor == 0.65)

        var preferences = Preferences()
        preferences.skipNeutralTemps = true
        preferences.rewindResetsAutosens = false
        preferences.suspendZerosIOB = false
        preferences.maxIOB = 7
        BaseSettingsManager.applySettingsFlowDefaults(to: &preferences)
        #expect(!preferences.skipNeutralTemps)
        #expect(preferences.rewindResetsAutosens)
        #expect(preferences.suspendZerosIOB)
        #expect(preferences.maxIOB == 7)
    }

    @Test("Writing removed settings normalizes them without reentering observers")
    @MainActor func managerDefaultWrite() {
        let manager = TrioApp.resolver.resolve(SettingsManager.self)!
        let originalSettings = manager.settings
        let originalPreferences = manager.preferences
        defer {
            manager.settings = originalSettings
            manager.preferences = originalPreferences
        }
        var settings = originalSettings
        settings.displayPresets = false
        settings.useCalendar = true
        manager.settings = settings
        #expect(manager.settings.displayPresets)
        #expect(!manager.settings.useCalendar)
        var preferences = originalPreferences
        preferences.skipNeutralTemps = true
        manager.preferences = preferences
        #expect(!manager.preferences.skipNeutralTemps)
    }

    @Test("Profile initials use the first and last words of the name") func profileInitials() {
        for (name, initials) in [
            ("Mendel David Kaplan", "MK"),
            ("  Olivia\nRose  Wilson  ", "OW"),
            ("Mendel", "M"),
            ("éva van der Meer", "ÉM"),
            (" \n ", "—")
        ] {
            #expect(SettingsUserProfile(name: name).initials == initials)
        }
    }

    @Test("Existing profiles decode without a photo and photos survive serialization") func profilePhotoPersistence() throws {
        let old = try JSONDecoder()
            .decode(SettingsUserProfile.self, from: Data(#"{"name":"Olivia Rose Wilson","sex":"female"}"#.utf8))
        #expect(old.photoData == nil)
        #expect(old.initials == "OW")
        var updated = old
        updated.photoData = Data([1, 2, 3])
        #expect(try JSONDecoder().decode(SettingsUserProfile.self, from: JSONEncoder().encode(updated)) == updated)
    }

    @Test("Profile photos are downsampled and invalid images are rejected")
    @MainActor func profilePhotoPreparation() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
        let sourceData = try #require(source.pngData())
        let data = try #require(SettingsProfilePhoto.prepare(sourceData))
        let result = try #require(UIImage(data: data)?.cgImage)
        #expect(max(result.width, result.height) == 512)
        #expect(data.count < 256 * 1024)
        #expect(SettingsProfilePhoto.prepare(Data("invalid image".utf8)) == nil)
    }

    @Test("Every supplied settings icon is present in the asset catalog")
    @MainActor func settingsIcons() {
        #expect(SettingsRowLabel.iconNames.count == 11)
        for name in SettingsRowLabel.iconNames.values { #expect(UIImage(named: name) != nil) }
    }

    @Test("Saving an alert profile opts into Trio alerts and excludes the removed alert type")
    @MainActor func savedProfileEnablesTrioAlerts() throws {
        let suite = "settings-save-alerts-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alerts = GlucoseAlertsStore(defaults: defaults)
        let profiles = SettingsAlertProfilesStore(defaults: defaults, alertsStore: alerts)
        #expect(!alerts.configuration.forceTrioAlertsWhenCGMProvidesOwn)
        #expect(profiles.profiles[0].supportedAlerts.count == 5)
        profiles.save(SettingsAlertProfile(name: "Work", alerts: GlucoseAlertsStore.defaultAlerts()))
        #expect(alerts.configuration.forceTrioAlertsWhenCGMProvidesOwn)
        #expect(profiles.profiles.first { $0.name == "Work" }?.alerts.contains { $0.type == .carbsRequired } == false)
        #expect(!alerts.alerts.contains { $0.type == .carbsRequired })
    }

    @Test("Native search cancellation resets presentation and can be repeated without selecting a result")
    @MainActor func nativeSearchCancellation() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let searchState = SettingsNativeSearchTestState()
        let controller = UIHostingController(rootView: SettingsNativeSearchTestHost(state: searchState))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true
            previous?.makeKey() }

        func searchControllers(_ viewController: UIViewController) -> [UISearchController] {
            let own = viewController.navigationItem.searchController.map { [$0] } ?? []
            return own + viewController.children.flatMap(searchControllers)
        }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let native = try #require(searchControllers(controller).first)
        for _ in 0 ..< 3 {
            searchState.presented = true
            for _ in 0 ..< 30 where !native.isActive {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(native.isActive)
            searchState.query = "glucose"
            try await Task.sleep(for: .milliseconds(350))
            // Invoke the native Cancel action, without selecting a result.
            native.searchBar.delegate?.searchBarCancelButtonClicked?(native.searchBar)
            for _ in 0 ..< 30 where searchState.presented {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(350))
            #expect(!searchState.presented)
            #expect(searchState.query.isEmpty)
            #expect(!native.isActive)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        date(2026, 10, day, hour, minute)
    }

    @Test("Overnight schedules belong to the day they start") func overnightWeekday() {
        let schedule = SettingsAlertSchedule(kind: .time, startMinute: 22 * 60, endMinute: 7 * 60, weekdays: [6])
        #expect(schedule.matches(at: date(16, 23), calendar: calendar))
        #expect(schedule.matches(at: date(17, 6), calendar: calendar))
        #expect(!schedule.matches(at: date(17, 7), calendar: calendar))
        #expect(!schedule.matches(at: date(17, 23), calendar: calendar))
        #expect(!schedule.matches(at: date(16, 6), calendar: calendar))
    }

    @Test("An overnight window follows wall-clock time through the DST transition") func daylightSavingTransition() {
        let schedule = SettingsAlertSchedule(kind: .time, startMinute: 22 * 60, endMinute: 7 * 60, weekdays: [7])
        let early = Date(timeIntervalSince1970: 1_793_511_000)
        #expect(calendar.component(.month, from: early) == 11)
        #expect(schedule.matches(at: date(2026, 11, 1, 6), calendar: calendar))
        #expect(!schedule.matches(at: date(2026, 11, 1, 7), calendar: calendar))
    }

    @Test("Location takes priority, ties use list order, and missing location falls back") func profilePrecedence() {
        let fallback = SettingsAlertProfile(name: "Default", isFallback: true)
        let first = SettingsAlertProfile(name: "First", schedule: .init(kind: .time))
        let second = SettingsAlertProfile(name: "Second", schedule: .init(kind: .time))
        var location = SettingsAlertProfile(name: "Work", schedule: .init(kind: .location))
        let now = date(16, 12)
        #expect(
            SettingsAlertProfile
                .selected(from: [first, second, location, fallback], at: now, insideLocations: [], calendar: calendar)?
                .id == first
                .id
        )
        #expect(
            SettingsAlertProfile
                .selected(from: [first, location, fallback], at: now, insideLocations: [location.id], calendar: calendar)?
                .id == location.id
        )
        location.isEnabled = false
        #expect(
            SettingsAlertProfile
                .selected(from: [location, fallback], at: now, insideLocations: [location.id], calendar: calendar)?.id == fallback
                .id
        )
    }

    @Test("Existing alert settings never populate the new profiles")
    @MainActor func startsFresh() throws {
        let suite = "SettingsRedesignTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = GlucoseAlert(type: .low)
        old.thresholdMgDL = 65
        old.activeOption = .night
        defaults.set(try JSONEncoder().encode([old]), forKey: "trio.glucoseAlerts.v1")
        defaults.set(
            try JSONEncoder().encode(GlucoseAlertConfiguration(forceTrioAlertsWhenCGMProvidesOwn: true)),
            forKey: "trio.glucoseAlertConfiguration.v1"
        )
        var oldDevice = DeviceAlertSeverityConfig(severity: .critical, activeOption: .night)
        oldDevice.soundFilename = "old-tone.caf"
        defaults.set(try JSONEncoder().encode([oldDevice]), forKey: "trio.deviceAlertSeverityConfigs.v1")
        defaults.set(try JSONEncoder().encode(["critical": Date().addingTimeInterval(600)]), forKey: "trio.deviceAlertTierSnoozes.v1")
        let devices = DeviceAlertsStore(defaults: defaults)
        #expect(devices.configs.count == DeviceAlertSeverity.allCases.count)
        #expect(devices.configs.allSatisfy { $0.activeOption == .always })
        #expect(devices.tierSnoozes.isEmpty)
        #expect(!devices.configs.contains { $0.soundFilename == "old-tone.caf" })
        let alerts = GlucoseAlertsStore(defaults: defaults)
        let store = SettingsAlertProfilesStore(defaults: defaults, alertsStore: alerts)
        #expect(store.profiles.count == 1)
        #expect(store.profiles[0].isFallback)
        #expect(store.profiles[0].schedule.kind == .always)
        #expect(store.profiles[0].alerts.first { $0.type == .low }?.thresholdMgDL == GlucoseAlertType.low.defaultThresholdMgDL)
        #expect(!alerts.configuration.forceTrioAlertsWhenCGMProvidesOwn)
        var saved = store.profiles[0]
        saved.alerts[0].thresholdMgDL = 58
        store.save(saved)
        let reopened = SettingsAlertProfilesStore(defaults: defaults, alertsStore: alerts)
        #expect(reopened.profiles[0].alerts[0].thresholdMgDL == 58)
    }

    @Test("New optional settings do not alter the representation of legacy settings") func legacySettingsRepresentation() throws {
        let settings = TrioSettings()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        #expect(object["userProfile"] == nil)
        #expect(object["slowAbsorptionDeliveryRatio"] == nil)
        #expect(object["fastAbsorptionDeliveryRatio"] == nil)
        let preferences = Preferences()
        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: encoded)
        #expect(decoded.pauseAutoBolusOnSuddenRise == nil)
    }

    @Test("Target-only temporary targets preserve unrelated safeguards and leave overrides alone") func targetOnlySemantics() {
        var profile = Profile()
        profile.temptargetSet = true
        profile.highTemptargetRaisesSensitivity = true
        profile.lowTemptargetLowersSensitivity = true
        profile.enableSMBWithTemptarget = true
        profile.allowSMBWithHighTemptarget = false
        profile.maxIob = 4
        profile.applyTargetOnlyTemporaryTarget()
        #expect(!profile.highTemptargetRaisesSensitivity)
        #expect(!profile.lowTemptargetLowersSensitivity)
        #expect(!profile.enableSMBWithTemptarget)
        #expect(profile.allowSMBWithHighTemptarget)
        #expect(profile.maxIob == 4)
        var noTarget = Profile()
        noTarget.highTemptargetRaisesSensitivity = true
        noTarget.applyTargetOnlyTemporaryTarget()
        #expect(noTarget.highTemptargetRaisesSensitivity)
    }

    @Test("Falling-fast rates reject stale, duplicate, and invalid samples") func fallingFastRate() {
        #expect(GlucoseAlertCoordinator.fallRate(latest: 100, previous: 115, elapsed: 300) == 3)
        #expect(GlucoseAlertCoordinator.fallRate(latest: 115, previous: 100, elapsed: 300) == -3)
        #expect(GlucoseAlertCoordinator.fallRate(latest: 100, previous: 115, elapsed: 0) == nil)
        #expect(GlucoseAlertCoordinator.fallRate(latest: 100, previous: 115, elapsed: 900) == nil)
        #expect(GlucoseAlertCoordinator.fallRate(latest: 0, previous: 115, elapsed: 300) == nil)
        #expect(!GlucoseAlert(type: .fallingFast).isEnabled)
    }

    @Test("Settings search understands old and new terminology") func renamedSearch() {
        #expect(SettingsFlowSearchEntry.matching("super bolus").first?.page == .insulinDosing)
        #expect(SettingsFlowSearchEntry.matching("noisy cgm").first?.page == .cgm)
        #expect(SettingsFlowSearchEntry.matching("remote control").first?.page == .caregivers)
    }

    @Test("Independent absorption ratios replace the base ratio without double scaling") func absorptionRatios() {
        var settings = TrioSettings()
        settings.overrideFactor = 0.8
        settings.fattyMealFactor = 0.7
        let originalSlow = settings.manualBolusFactors(slow: true, fast: false)
        #expect(originalSlow.fraction * originalSlow.slowFactor == Decimal(56) / 100)
        #expect(settings.manualBolusFactors(slow: false, fast: true).fraction == 0.8)
        settings.slowAbsorptionDeliveryRatio = 0.6
        settings.fastAbsorptionDeliveryRatio = 1.1
        let slow = settings.manualBolusFactors(slow: true, fast: false)
        #expect(slow.fraction * slow.slowFactor == 0.6)
        #expect(settings.manualBolusFactors(slow: false, fast: true).fraction == 1.1)
        settings.overrideFactor = 0.9
        #expect(settings.manualBolusFactors(slow: true, fast: false).fraction == 0.6)
        #expect(settings.manualBolusFactors(slow: false, fast: true).fraction == 1.1)
        #expect(settings.manualBolusFactors(slow: false, fast: false).fraction == 0.9)
    }
}

@MainActor private final class SettingsNativeSearchTestState: ObservableObject {
    @Published var query = ""
    @Published var presented = false
}

private struct SettingsNativeSearchTestHost: View {
    @ObservedObject var state: SettingsNativeSearchTestState

    var body: some View {
        NavigationStack {
            List { Text(state.presented ? "Search results" : "Settings rows") }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
                .modifier(SettingsNativeSearch(text: $state.query, isPresented: $state.presented))
        }
    }
}
