import Combine
import Foundation
import LoopKit
import SwiftUI
import Swinject

struct SettingsUserProfile: Codable, Equatable {
    var name = ""
    var dateOfBirth: Date?
    var heightCM: Double?
    var weightKG: Double?
    var sex = ""

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "—" : String(letters).uppercased()
    }
}

final class SettingsFlowModel: ObservableObject, SettingsObserver, PreferencesObserver {
    let resolver: Resolver
    let manager: SettingsManager
    @Published private(set) var settings: TrioSettings
    @Published private(set) var preferences: Preferences
    @Published var error: String?
    @Published var savingPumpLimits = false
    @Published var hasValidTDD = false
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        self.resolver = resolver
        manager = resolver.resolve(SettingsManager.self)!
        settings = manager.settings
        preferences = manager.preferences
        let broadcaster = resolver.resolve(Broadcaster.self)!
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PreferencesObserver.self, observer: self)
        Task {
            let sufficient = (try? await resolver.resolve(TDDStorage.self)!.hasSufficientTDD()) ?? false
            await MainActor.run { self.hasValidTDD = sufficient }
        }
    }

    func settingsDidChange(_ settings: TrioSettings) { self.settings = settings }
    func preferencesDidChange(_ preferences: Preferences) { self.preferences = preferences }

    func setting<T>(_ key: WritableKeyPath<TrioSettings, T>) -> Binding<T> {
        Binding(get: { self.manager.settings[keyPath: key] }, set: { value in
            var updated = self.manager.settings
            updated[keyPath: key] = value
            self.manager.settings = updated
            self.settings = updated
        })
    }

    func preference<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.manager.preferences[keyPath: key] }, set: { value in
            var updated = self.manager.preferences
            updated[keyPath: key] = value
            self.manager.preferences = updated
            self.preferences = updated
        })
    }

    var userProfile: SettingsUserProfile { settings.userProfile ?? SettingsUserProfile() }
    var profile: Binding<SettingsUserProfile> {
        Binding(get: { self.manager.settings.userProfile ?? SettingsUserProfile() }, set: { profile in
            var updated = self.manager.settings
            updated.userProfile = profile
            self.manager.settings = updated
            self.settings = updated
        })
    }

    var suddenRiseSafeguard: Binding<Bool> {
        Binding(get: { self.manager.preferences.pauseAutoBolusOnSuddenRise ?? true }, set: {
            self.preference(\.pauseAutoBolusOnSuddenRise).wrappedValue = $0
        })
    }

    func profileField<T>(_ key: WritableKeyPath<SettingsUserProfile, T>) -> Binding<T> {
        Binding(get: { (self.manager.settings.userProfile ?? SettingsUserProfile())[keyPath: key] }, set: { value in
            var profile = self.manager.settings.userProfile ?? SettingsUserProfile()
            profile[keyPath: key] = value
            self.profile.wrappedValue = profile
        })
    }

    var units: GlucoseUnits { settings.units }
    func absorptionDeliveryRatio(fast: Bool) -> Binding<Decimal> {
        Binding(get: {
            let settings = self.manager.settings
            if fast {
                return settings.sweetMeals ? settings.fastAbsorptionDeliveryRatio ?? settings.overrideFactor : 0
            }
            return settings.fattyMeals ? settings.slowAbsorptionDeliveryRatio ?? settings.overrideFactor * settings
                .fattyMealFactor : 0
        }, set: { value in
            var settings = self.manager.settings
            if fast {
                settings.sweetMeals = value > 0
                if value > 0 { settings.fastAbsorptionDeliveryRatio = value }
            } else {
                settings.fattyMeals = value > 0
                if value > 0 { settings.slowAbsorptionDeliveryRatio = value }
            }
            self.manager.settings = settings
            self.settings = settings
        })
    }

    var adjustmentMethod: Binding<String> {
        Binding(get: {
            self.preferences.useNewFormula ? (self.preferences.sigmoid ? "sigmoid" : "logarithmic") : "basic"
        }, set: { method in
            guard method == "basic" || self.hasValidTDD else { return }
            var updated = self.manager.preferences
            updated.useNewFormula = method != "basic"
            updated.sigmoid = method == "sigmoid"
            self.manager.preferences = updated
            self.preferences = updated
        })
    }

    var recentTDDWeight: Binding<Double> {
        Binding(get: { Double(self.preferences.weightPercentage) }, set: {
            self.preference(\.weightPercentage).wrappedValue = Decimal($0)
        })
    }

    func relativeISFLimit(increase: Bool) -> Binding<Decimal> {
        let key: WritableKeyPath<Preferences, Decimal> = increase ? \.autosensMax : \.autosensMin
        return Binding(get: {
            let ratio = self.manager.preferences[keyPath: key]
            return increase ? (ratio - 1) * 100 : (1 - ratio) * 100
        }, set: { percent in
            self.preference(key).wrappedValue = increase ? 1 + percent / 100 : 1 - percent / 100
        })
    }

    var pumpLimits: PumpSettings { manager.pumpSettings }

    func pumpLimit(basal: Bool) -> Binding<Decimal> {
        Binding(get: { basal ? self.pumpLimits.maxBasal : self.pumpLimits.maxBolus }, set: { value in
            guard !self.savingPumpLimits else { return }
            let current = self.pumpLimits
            let updated = PumpSettings(
                insulinActionCurve: current.insulinActionCurve,
                maxBolus: basal ? current.maxBolus : value,
                maxBasal: basal ? value : current.maxBasal
            )
            let provider = UnitsLimitsSettings.Provider(resolver: self.resolver)
            self.savingPumpLimits = true
            provider.save(settings: updated)
                .receive(on: DispatchQueue.main)
                .sink { completion in
                    self.savingPumpLimits = false
                    if case let .failure(error) = completion { self.error = error.localizedDescription }
                    self.objectWillChange.send()
                } receiveValue: { _ in }
                .store(in: &self.subscriptions)
        })
    }

    var insulinActionDuration: Binding<Decimal> {
        Binding(get: { self.pumpLimits.insulinActionCurve }, set: { value in
            let limits = PumpSettings(
                insulinActionCurve: value,
                maxBolus: self.pumpLimits.maxBolus,
                maxBasal: self.pumpLimits.maxBasal
            )
            self.resolver.resolve(FileStorage.self)!.save(limits, as: OpenAPS.Settings.settings)
            self.resolver.resolve(Broadcaster.self)!.notify(PumpSettingsObserver.self, on: .main) {
                $0.pumpSettingsDidChange(limits)
            }
            self.objectWillChange.send()
        })
    }
}

enum SettingsFlowPage: String, CaseIterable, Identifiable {
    case profile
    case personalInformation
    case languageUnits
    case devices
    case cgm
    case pump
    case therapy
    case algorithm
    case safetyLimits
    case dynamicISF
    case insulinDosing
    case advanced
    case additionalSafety
    case pumpAdvanced
    case notifications
    case customize
    case graph
    case statisticsBar
    case services
    case caregivers
    case support
    case about
    case community
    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .personalInformation: return "Personal Information"
        case .languageUnits: return "Language & Units"
        case .devices: return "Devices"
        case .cgm: return "CGM"
        case .pump: return "Insulin Pump"
        case .therapy: return "Therapy"
        case .algorithm: return "Algorithm"
        case .safetyLimits: return "Safety Limits"
        case .dynamicISF: return "Dynamic ISF"
        case .insulinDosing: return "Insulin Dosing"
        case .advanced: return "Advanced"
        case .additionalSafety: return "Additional Configuration"
        case .pumpAdvanced: return "Pump Configuration"
        case .notifications: return "Notifications"
        case .customize: return "Customize"
        case .graph: return "Graph"
        case .statisticsBar: return "Statistics Bar"
        case .services: return "Services"
        case .caregivers: return "Caregivers"
        case .support: return "Support"
        case .about: return "About"
        case .community: return "Trio Community"
        }
    }
}
