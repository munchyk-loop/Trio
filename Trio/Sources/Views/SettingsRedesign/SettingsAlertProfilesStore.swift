import Combine
import CoreLocation
import Foundation
import UIKit

@MainActor final class SettingsAlertProfilesStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SettingsAlertProfilesStore()
    nonisolated static let storageKey = "trio.alertProfiles.v2"
    @Published private(set) var profiles: [SettingsAlertProfile] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published var locationError: String?
    private var insideLocations = Set<UUID>()
    private let defaults: UserDefaults
    private let alertsStore: GlucoseAlertsStore
    private let locationManager = CLLocationManager()
    private var subscriptions = Set<AnyCancellable>()
    private var applying = false
    private var started = false

    init(defaults: UserDefaults = .standard, alertsStore: GlucoseAlertsStore = .shared) {
        self.defaults = defaults
        self.alertsStore = alertsStore
        super.init()
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([SettingsAlertProfile].self, from: data),
           saved.contains(where: \.isFallback)
        {
            profiles = saved
        } else {
            profiles = Self.defaultProfiles()
            persist()
        }
        locationManager.delegate = self
        locationAuthorization = locationManager.authorizationStatus
        alertsStore.$alerts.dropFirst().sink { [weak self] alerts in
            guard let self, !applying, !TrioCloudSettingsRestore.isRestoring,
                  let index = profiles.firstIndex(where: { $0.id == self.activeID }) else { return }
            profiles[index].alerts = alerts
            persist()
        }.store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: Notification.Name("trio.alertProfilesRestored"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadSavedConfiguration() }
            .store(in: &subscriptions)
    }

    static func defaultProfiles() -> [SettingsAlertProfile] {
        [SettingsAlertProfile(
            name: String(localized: "Default"), isFallback: true,
            alerts: GlucoseAlertsStore.defaultAlerts().filter { $0.type != .carbsRequired }
        )]
    }

    func start() {
        guard !started else { refresh()
            return }
        started = true
        refresh()
        synchronizeRegions()
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.synchronizeRegions()
                self?.refresh() }.store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
    }

    func reloadSavedConfiguration() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([SettingsAlertProfile].self, from: data),
           saved.contains(where: \.isFallback)
        {
            profiles = saved
        } else {
            profiles = Self.defaultProfiles()
        }
        activeID = nil
        insideLocations.removeAll()
        synchronizeRegions()
        refresh(force: true)
    }

    func save(_ profile: SettingsAlertProfile) {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var profile = profile
        profile.alerts = profile.supportedAlerts
        alertsStore.configuration.forceTrioAlertsWhenCGMProvidesOwn = true
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            if profiles[index].schedule != profile.schedule || profiles[index].isEnabled != profile.isEnabled {
                insideLocations.remove(profile.id)
            }
            profiles[index] = profile
        } else { profiles.insert(profile, at: max(0, profiles.count - 1)) }
        persist()
        synchronizeRegions()
        refresh(force: true)
    }

    func remove(_ profile: SettingsAlertProfile) {
        guard !profile.isFallback else { return }
        profiles.removeAll { $0.id == profile.id }
        insideLocations.remove(profile.id)
        persist()
        synchronizeRegions()
        refresh(force: true)
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        if enabled { alertsStore.configuration.forceTrioAlertsWhenCGMProvidesOwn = true }
        guard var profile = profiles.first(where: { $0.id == id }), !profile.isFallback else { return }
        profile.isEnabled = enabled
        save(profile)
    }

    func refresh(force: Bool = false) {
        guard !TrioCloudSettingsRestore.isRestoring else { return }
        guard let selected = SettingsAlertProfile.selected(
            from: profiles, at: Date(), insideLocations: insideLocations
        ), force || activeID != selected.id else { return }
        activeID = selected.id
        applying = true
        alertsStore.alerts = selected.supportedAlerts
        applying = false
    }

    func requestLocationAccess() {
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: locationManager.requestAlwaysAuthorization()
        case .denied,
             .restricted:
            locationError = String(localized: "Enable location access in iOS Settings to activate location-based alert profiles.")
        case .authorizedAlways: synchronizeRegions()
        @unknown default: break
        }
    }

    private func synchronizeRegions() {
        let scheduled = profiles.filter { $0.isEnabled && $0.schedule.kind == .location }
        let desired = Set(scheduled.map(\.id.uuidString))
        for region in locationManager.monitoredRegions where region.identifier.hasPrefix("trio.alertProfile.") {
            if !desired.contains(String(region.identifier.dropFirst("trio.alertProfile.".count))) {
                locationManager.stopMonitoring(for: region)
            }
        }
        guard locationManager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        else {
            insideLocations.removeAll()
            return
        }
        let otherRegions = locationManager.monitoredRegions.filter { !$0.identifier.hasPrefix("trio.alertProfile.") }.count
        let capacity = max(0, 20 - otherRegions)
        if scheduled.count > capacity { locationError = String(localized: "iOS supports up to 20 monitored locations per app.") }
        for profile in scheduled.prefix(capacity) {
            let s = profile.schedule
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                radius: min(max(s.radius, 100), locationManager.maximumRegionMonitoringDistance),
                identifier: "trio.alertProfile." + profile.id.uuidString
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
            locationManager.requestState(for: region)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.storageKey) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            locationAuthorization = status
            synchronizeRegions()
            refresh(force: true)
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didEnterRegion region: CLRegion) {
        update(region: region, inside: true)
    }

    nonisolated func locationManager(_: CLLocationManager, didExitRegion region: CLRegion) {
        update(region: region, inside: false)
    }

    nonisolated func locationManager(_: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        update(region: region, inside: state == .inside)
    }

    nonisolated func locationManager(_: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let identifier = region?.identifier
        Task { @MainActor in
            if let identifier, let id = UUID(uuidString: String(identifier.dropFirst("trio.alertProfile.".count))) {
                insideLocations.remove(id)
            } else {
                insideLocations.removeAll()
            }
            locationError = error.localizedDescription
            refresh()
        }
    }

    private nonisolated func update(region: CLRegion, inside: Bool) {
        guard region.identifier.hasPrefix("trio.alertProfile."),
              let id = UUID(uuidString: String(region.identifier.dropFirst("trio.alertProfile.".count))) else { return }
        Task { @MainActor in
            if inside { insideLocations.insert(id) } else { insideLocations.remove(id) }
            refresh()
        }
    }
}
