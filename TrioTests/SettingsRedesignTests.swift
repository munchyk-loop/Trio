import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Trio

@Suite("Settings Redesign") struct SettingsRedesignTests {
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
        let screens: [(String, AnyView)] = [
            ("settings", AnyView(Settings.RootView(resolver: TrioApp.resolver))),
            ("profile", AnyView(SettingsFlowPageView(page: .profile, model: model))),
            ("safety", AnyView(SettingsFlowPageView(page: .safetyLimits, model: model))),
            ("insulin-dosing", AnyView(SettingsFlowPageView(page: .insulinDosing, model: model))),
            ("alert-profiles", AnyView(SettingsAlertProfilesView(model: model)))
        ]
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SettingsReview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, screen) in screens {
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
