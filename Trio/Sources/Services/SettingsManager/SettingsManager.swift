import Foundation
import LoopKit
import Swinject

protocol SettingsManager: AnyObject {
    var settings: TrioSettings { get set }
    var preferences: Preferences { get set }
    var pumpSettings: PumpSettings { get }
    func updateInsulinCurve(_ insulinType: InsulinType?)
}

protocol SettingsObserver {
    func settingsDidChange(_: TrioSettings)
}

protocol PreferencesObserver {
    func preferencesDidChange(_: Preferences)
}

final class BaseSettingsManager: SettingsManager, Injectable {
    @Injected() var broadcaster: Broadcaster!
    @Injected() var storage: FileStorage!

    @SyncAccess var settings: TrioSettings {
        didSet {
            var normalized = settings
            Self.applySettingsFlowDefaults(to: &normalized)
            _settings.wrappedValue = normalized
            if oldValue != settings {
                saveSettings()
                DispatchQueue.main.async {
                    self.broadcaster.notify(SettingsObserver.self, on: .main) {
                        $0.settingsDidChange(self.settings)
                    }
                }
            }
        }
    }

    @SyncAccess var preferences: Preferences {
        didSet {
            var normalized = preferences
            Self.applySettingsFlowDefaults(to: &normalized)
            _preferences.wrappedValue = normalized
            if oldValue != preferences {
                savePreferences()
                DispatchQueue.main.async {
                    self.broadcaster.notify(PreferencesObserver.self, on: .main) {
                        $0.preferencesDidChange(self.preferences)
                    }
                }
            }
        }
    }

    private func saveSettings() {
        storage.save(settings, as: OpenAPS.Trio.settings)
    }

    private func savePreferences() {
        storage.save(preferences, as: OpenAPS.Settings.preferences)
    }

    init(resolver: Resolver) {
        let storage = resolver.resolve(FileStorage.self)!
        settings = storage.retrieve(OpenAPS.Trio.settings, as: TrioSettings.self)
            ?? TrioSettings(from: OpenAPS.defaults(for: OpenAPS.Trio.settings))
            ?? TrioSettings()

        preferences =
            storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
                ?? Preferences(from: OpenAPS.defaults(for: OpenAPS.Settings.preferences))
                ?? Preferences()

        var normalizedSettings = settings
        var normalizedPreferences = preferences
        Self.applySettingsFlowDefaults(to: &normalizedSettings)
        Self.applySettingsFlowDefaults(to: &normalizedPreferences)
        _settings.wrappedValue = normalizedSettings
        _preferences.wrappedValue = normalizedPreferences
        injectServices(resolver)
        saveSettings()
        savePreferences()
    }

    // These controls were deliberately removed from the settings flow. Apply the
    // backend defaults at load and write boundaries, including backup restores.
    static func applySettingsFlowDefaults(to settings: inout TrioSettings) {
        settings.displayPresets = true
        settings.useCalendar = false
        settings.showCobIobChart = true
        settings.showCarbsRequiredBadge = true
        settings.carbsRequiredThreshold = 10
        settings.requireAdjustmentsConfirmation = false
    }

    static func applySettingsFlowDefaults(to preferences: inout Preferences) {
        preferences.skipNeutralTemps = false
        preferences.rewindResetsAutosens = true
        preferences.suspendZerosIOB = true
    }

    var pumpSettings: PumpSettings {
        storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
            ?? PumpSettings(from: OpenAPS.defaults(for: OpenAPS.Settings.settings))
            ?? PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2)
    }

    func updateInsulinCurve(_ insulinType: InsulinType?) {
        var prefs = preferences

        switch insulinType {
        case .apidra,
             .humalog,
             .novolog:
            prefs.curve = .rapidActing

        case .fiasp,
             .lyumjev:
            prefs.curve = .ultraRapid
        default:
            prefs.curve = .rapidActing
        }

        preferences = prefs
        savePreferences()
    }
}
