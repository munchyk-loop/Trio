import CloudKit
import CoreData
import CryptoKit
import Foundation

/// A versioned, portable snapshot of configuration. This deliberately does not
/// contain Keychain values, pump/CGM pairing, current delivery state, glucose,
/// boluses or live treatment information. Timestamped TDD summaries are included
/// only to preserve the existing Dynamic ISF history gate.
///
/// Presets are explicitly serialized as portable DTOs, never as live Core Data objects.
struct TrioSettingsBackup: Codable {
    static let currentSchema = 4
    static let maximumSize = 8 * 1024 * 1024

    enum Origin: String, Codable, CaseIterable, Hashable {
        case automatic
        case manual
    }

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let appVersion: String
    let origin: Origin
    var name: String?
    let configuration: Configuration
    let fingerprint: String
    var dynamicISFHistory: [TDDRecord]? = nil
    var historyChecksum: String? = nil
    // Intentionally excluded from the portable JSON format.
    var cloudConnections: TrioCloudConnections? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case appVersion
        case origin
        case name
        case configuration
        case fingerprint
        case dynamicISFHistory
        case historyChecksum
    }

    func cloudFingerprint() throws -> String {
        guard let cloudConnections else { return fingerprint }
        return try fingerprint + ":" + cloudConnections.fingerprint()
    }

    /// Historical summaries, never pump commands or active insulin state.
    struct TDDRecord: Codable, Equatable {
        let id: UUID
        let date: Date
        let total: Decimal
        let bolus: Decimal
        let tempBasal: Decimal
        let scheduledBasal: Decimal
        let weightedAverage: Decimal
    }

    static func historyDigest(_ history: [TDDRecord]) throws -> String {
        digest(try encoded(history))
    }

    static func readTDDHistory(
        context: NSManagedObjectContext = CoreDataStack.shared.newTaskContext(),
        now: Date = Date()
    ) async throws -> [TDDRecord] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "TDDStored")
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@ AND total > 0",
                now.addingTimeInterval(-10 * 86400) as NSDate,
                now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 10000
            return try context.fetch(request).map { row in
                func decimal(_ key: String) -> Decimal {
                    (row.value(forKey: key) as? NSDecimalNumber)?.decimalValue ?? 0
                }
                return TDDRecord(
                    id: row.value(forKey: "id") as? UUID ?? UUID(),
                    date: row.value(forKey: "date") as! Date,
                    total: decimal("total"),
                    bolus: decimal("bolus"),
                    tempBasal: decimal("tempBasal"),
                    scheduledBasal: decimal("scheduledBasal"),
                    weightedAverage: decimal("weightedAverage")
                )
            }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        }
    }

    func eligibleTDDHistory(now: Date = Date()) -> [TDDRecord] {
        guard now >= createdAt, now.timeIntervalSince(createdAt) < 7 * 86400 else { return [] }
        return (dynamicISFHistory ?? []).filter { $0.date > now.addingTimeInterval(-10 * 86400) && $0.date <= now }
    }

    private func validateHistory() throws {
        guard let history = dynamicISFHistory else {
            guard historyChecksum == nil else { throw BackupError.integrityCheckFailed }
            return
        }
        guard schemaVersion == Self.currentSchema, history.count <= 10000,
              historyChecksum == (try Self.historyDigest(history)),
              Set(history.map(\.id)).count == history.count else { throw BackupError.integrityCheckFailed }
        for row in history {
            let values = [row.total, row.bolus, row.tempBasal, row.scheduledBasal, row.weightedAverage]
            guard row.date <= createdAt, row.date >= createdAt.addingTimeInterval(-10 * 86400),
                  row.date.timeIntervalSinceReferenceDate.isFinite,
                  values.allSatisfy({ !$0.isNaN && $0 >= 0 }), row.total > 0
            else {
                throw BackupError.invalidTherapyConfiguration
            }
        }
    }

    struct Configuration: Codable {
        var settings: TrioSettings
        var preferences: Preferences
        var pumpSettings: PumpSettings
        var basalProfile: [BasalProfileEntry]
        var carbRatios: CarbRatios
        var insulinSensitivities: InsulinSensitivities
        var glucoseTargets: BGTargets
        var presets: Presets
        // Absent only in schema 2, which predates portable alert/display settings.
        var appConfiguration: AppConfiguration? = nil

        private enum CodingKeys: String, CodingKey {
            case settings
            case preferences
            case pumpSettings
            case basalProfile
            case carbRatios
            case insulinSensitivities
            case glucoseTargets
            case presets
            case appConfiguration
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            settings = try values.decode(BackupStrict<TrioSettings>.self, forKey: .settings).value
            preferences = try values.decode(BackupStrict<Preferences>.self, forKey: .preferences).value
            pumpSettings = try values.decode(PumpSettings.self, forKey: .pumpSettings)
            basalProfile = try values.decode([BasalProfileEntry].self, forKey: .basalProfile)
            carbRatios = try values.decode(CarbRatios.self, forKey: .carbRatios)
            insulinSensitivities = try values.decode(InsulinSensitivities.self, forKey: .insulinSensitivities)
            glucoseTargets = try values.decode(BGTargets.self, forKey: .glucoseTargets)
            presets = try values.decode(Presets.self, forKey: .presets)
            appConfiguration = try values.decodeIfPresent(BackupStrict<AppConfiguration>.self, forKey: .appConfiguration)?.value
        }

        init(
            settings: TrioSettings,
            preferences: Preferences,
            pumpSettings: PumpSettings,
            basalProfile: [BasalProfileEntry],
            carbRatios: CarbRatios,
            insulinSensitivities: InsulinSensitivities,
            glucoseTargets: BGTargets,
            presets: Presets,
            appConfiguration: AppConfiguration? = nil
        ) {
            self.settings = settings
            self.preferences = preferences
            self.pumpSettings = pumpSettings
            self.basalProfile = basalProfile
            self.carbRatios = carbRatios
            self.insulinSensitivities = insulinSensitivities
            self.glucoseTargets = glucoseTargets
            self.presets = presets
            self.appConfiguration = appConfiguration
        }
    }

    struct AppConfiguration: Codable {
        let appearance: ColorSchemeOption
        let liveActivityOrder: [String]?
        var glucoseAlerts: [GlucoseAlert]
        let glucoseAlertConfiguration: GlucoseAlertConfiguration
        var deviceAlertConfigurations: [DeviceAlertSeverityConfig]

        static let keys = [
            "colorSchemePreference",
            "liveActivityOrder",
            "trio.glucoseAlerts.v1",
            "trio.glucoseAlertConfiguration.v1",
            "trio.deviceAlertSeverityConfigs.v1"
        ]

        static func capture(defaults: UserDefaults = .standard) -> Self {
            // Stores own the effective saved configuration. Never include snoozes.
            var alerts = GlucoseAlertsStore.shared.alerts
            for index in alerts.indices { alerts[index].snoozedUntil = nil }
            return Self(
                appearance: ColorSchemeOption(rawValue: defaults.string(forKey: keys[0]) ?? "") ?? .systemDefault,
                liveActivityOrder: defaults.stringArray(forKey: keys[1]),
                glucoseAlerts: alerts,
                glucoseAlertConfiguration: GlucoseAlertsStore.shared.configuration,
                deviceAlertConfigurations: DeviceAlertsStore.shared.configs
            )
        }

        func apply(defaults: UserDefaults = .standard) throws {
            // Encode before mutating anything; the restore journal includes all keys.
            let alerts = try JSONEncoder().encode(glucoseAlerts)
            let config = try JSONEncoder().encode(glucoseAlertConfiguration)
            let devices = try JSONEncoder().encode(deviceAlertConfigurations)
            defaults.set(appearance.rawValue, forKey: Self.keys[0])
            defaults.set(liveActivityOrder, forKey: Self.keys[1])
            defaults.set(alerts, forKey: Self.keys[2])
            defaults.set(config, forKey: Self.keys[3])
            defaults.set(devices, forKey: Self.keys[4])
            GlucoseAlertsStore.shared.alerts = glucoseAlerts
            GlucoseAlertsStore.shared.configuration = glucoseAlertConfiguration
            DeviceAlertsStore.shared.configs = deviceAlertConfigurations
            Foundation.NotificationCenter.default.post(name: .liveActivityOrderDidChange, object: nil)
        }
    }

    /// Only the saved templates belong here; active instances and treatment
    /// history have intentionally been excluded.
    struct Presets: Codable {
        let overrides: [OverridePreset]
        let tempTargets: [TempTargetPreset]
        let meals: [MealPreset]
    }

    struct OverridePreset: Codable {
        let name: String?
        let order: Int16
        let percentage: Double
        let duration: Decimal?
        let indefinite: Bool
        var target: Decimal?
        let isf: Bool
        let cr: Bool
        let isfAndCr: Bool
        let advancedSettings: Bool
        let smbIsScheduledOff: Bool
        let smbIsOff: Bool
        let smbMinutes: Decimal?
        let uamMinutes: Decimal?
        let start: Decimal?
        let end: Decimal?
    }

    struct TempTargetPreset: Codable {
        let name: String?
        let order: Int16
        let duration: Decimal?
        let target: Decimal?
        let halfBasalTarget: Decimal?
    }

    struct MealPreset: Codable {
        let dish: String?
        let carbs: Decimal?
        let fat: Decimal?
        let protein: Decimal?
    }

    static func readPresets(context: NSManagedObjectContext = CoreDataStack.shared.newTaskContext()) async throws -> Presets {
        try await context.perform {
            let overridesRequest = OverrideStored.fetchRequest()
            overridesRequest.predicate = NSPredicate(format: "isPreset == YES")
            let tempTargetsRequest = TempTargetStored.fetchRequest()
            tempTargetsRequest.predicate = NSPredicate(format: "isPreset == YES")
            let overrides = try context.fetch(overridesRequest).map { preset in
                OverridePreset(
                    name: preset.name, order: preset.orderPosition,
                    percentage: preset.percentage, duration: preset.duration?.decimalValue,
                    indefinite: preset.indefinite, target: preset.target?.decimalValue,
                    isf: preset.isf, cr: preset.cr, isfAndCr: preset.isfAndCr,
                    advancedSettings: preset.advancedSettings,
                    smbIsScheduledOff: preset.smbIsScheduledOff,
                    smbIsOff: preset.smbIsOff,
                    smbMinutes: preset.smbMinutes?.decimalValue,
                    uamMinutes: preset.uamMinutes?.decimalValue,
                    start: preset.start?.decimalValue, end: preset.end?.decimalValue
                )
            }
            let targets = try context.fetch(tempTargetsRequest).map { preset in
                TempTargetPreset(
                    name: preset.name, order: preset.orderPosition,
                    duration: preset.duration?.decimalValue,
                    target: preset.target?.decimalValue,
                    halfBasalTarget: preset.halfBasalTarget?.decimalValue
                )
            }
            let meals = try context.fetch(MealPresetStored.fetchRequest()).map { preset in
                MealPreset(
                    dish: preset.dish, carbs: preset.carbs?.decimalValue,
                    fat: preset.fat?.decimalValue, protein: preset.protein?.decimalValue
                )
            }
            return Presets(
                overrides: try stableSort(overrides),
                tempTargets: try stableSort(targets),
                meals: try stableSort(meals)
            )
        }
    }

    @MainActor static func capture(
        storage: FileStorage,
        origin: Origin,
        name: String? = nil
    ) async throws -> TrioSettingsBackup {
        let capturedAt = Date()
        let presets = try await readPresets()
        let history = try await readTDDHistory(now: capturedAt)
        let appConfiguration = AppConfiguration.capture()
        var capturedConfiguration: Configuration?
        // Read the saved source files together, never generated profiles/autotune.
        storage.transaction { storage in
            guard let settings = storage.retrieve(OpenAPS.Trio.settings, as: TrioSettings.self),
                  let preferences = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self),
                  let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self),
                  let carbs = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
                  let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self),
                  let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self),
                  let pump = storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
            else { return }
            capturedConfiguration = Configuration(
                settings: settings, preferences: preferences, pumpSettings: pump,
                basalProfile: basal, carbRatios: carbs, insulinSensitivities: isf,
                glucoseTargets: targets, presets: presets,
                appConfiguration: appConfiguration
            )
        }
        guard let saved = capturedConfiguration else { throw BackupError.incompleteConfiguration }
        let configuration = try normalized(saved)
        try validate(configuration)
        let trimmedName = normalizedName(name)
        return TrioSettingsBackup(
            schemaVersion: currentSchema,
            id: UUID(),
            createdAt: capturedAt,
            appVersion: "\(Bundle.main.appDevVersion ?? "Unknown") (\(Bundle.main.buildVersionNumber ?? "Unknown"))",
            origin: origin,
            name: trimmedName,
            configuration: configuration,
            fingerprint: try Self.normalizedFingerprint(configuration),
            dynamicISFHistory: history, historyChecksum: try Self.historyDigest(history)
        )
    }

    static func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func stableSort<T: Encodable>(_ values: [T]) throws -> [T] {
        try values.map { (try encoded($0), $0) }
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
    }

    private static func canonicalStart(_ offset: Int) -> String {
        String(format: "%02d:%02d:00", offset / 60, offset % 60)
    }

    private static func validSchedule(_ starts: [String], _ minutes: [Int]) -> Bool {
        guard minutes.first == 0, Set(minutes).count == minutes.count,
              minutes == minutes.sorted(), starts.count == minutes.count else { return false }
        return zip(starts, minutes).allSatisfy { start, offset in
            guard offset >= 0, offset < 1440 else { return false }
            // Trio's TherapySettingsUtil explicitly accepts both persisted formats.
            return start == canonicalStart(offset) || start == String(canonicalStart(offset).prefix(5))
        }
    }

    static func normalized(_ value: Configuration) throws -> Configuration {
        guard validSchedule(value.basalProfile.map(\.start), value.basalProfile.map(\.minutes)),
              validSchedule(value.carbRatios.schedule.map(\.start), value.carbRatios.schedule.map(\.offset)),
              validSchedule(
                  value.insulinSensitivities.sensitivities.map(\.start),
                  value.insulinSensitivities.sensitivities.map(\.offset)
              ),
              validSchedule(value.glucoseTargets.targets.map(\.start), value.glucoseTargets.targets.map(\.offset))
        else {
            throw BackupError.invalidTherapyConfiguration
        }
        var result = value
        result.settings.cgm = .none
        result.settings.cgmPluginIdentifier = ""
        result.settings.isUploadEnabled = false
        result.settings.isDownloadEnabled = false
        result.settings.useLocalGlucoseSource = false
        result.preferences.timestamp = nil
        result.preferences.bolusIncrement = 0.1
        if var app = result.appConfiguration {
            for index in app.glucoseAlerts.indices { app.glucoseAlerts[index].snoozedUntil = nil }
            result.appConfiguration = app
        }
        result.basalProfile = value.basalProfile
            .map { .init(start: canonicalStart($0.minutes), minutes: $0.minutes, rate: $0.rate) }
        result.carbRatios = .init(units: value.carbRatios.units, schedule: value.carbRatios.schedule.map {
            .init(start: canonicalStart($0.offset), offset: $0.offset, ratio: $0.ratio)
        })
        result.insulinSensitivities = .init(
            units: value.insulinSensitivities.units,
            userPreferredUnits: value.insulinSensitivities.userPreferredUnits,
            sensitivities: value.insulinSensitivities.sensitivities.map {
                .init(sensitivity: $0.sensitivity, offset: $0.offset, start: canonicalStart($0.offset))
            }
        )
        result.glucoseTargets = .init(
            units: value.glucoseTargets.units,
            userPreferredUnits: value.glucoseTargets.userPreferredUnits,
            targets: value.glucoseTargets.targets.map {
                .init(low: $0.low, high: $0.high, start: canonicalStart($0.offset), offset: $0.offset)
            }
        )
        result.presets = Presets(
            overrides: try stableSort(value.presets.overrides.map { preset in
                var result = preset
                // OverrideStorage treats nil and zero as "no target override".
                if result.target == 0 { result.target = nil }
                return result
            }),
            tempTargets: try stableSort(value.presets.tempTargets),
            meals: try stableSort(value.presets.meals)
        )
        return result
    }

    static func fingerprint(for configuration: Configuration) throws -> String {
        try normalizedFingerprint(normalized(configuration))
    }

    private static func normalizedFingerprint(_ configuration: Configuration) throws -> String {
        var value = configuration
        if var app = value.appConfiguration {
            // Alert IDs identify UI rows; default stores regenerate them on a
            // fresh launch. They are not an effective therapy/configuration change.
            let identity = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            for index in app.glucoseAlerts.indices { app.glucoseAlerts[index].id = identity }
            for index in app.deviceAlertConfigurations.indices { app.deviceAlertConfigurations[index].id = identity }
            value.appConfiguration = app
        }
        return try digest(encoded(value))
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws -> TrioSettingsBackup {
        guard (2 ... Self.currentSchema).contains(schemaVersion) else { throw BackupError.unsupportedSchema }
        try Self.validate(configuration)
        try validateHistory()
        // Verify the original schema-2 checksum BEFORE migration/normalization.
        let expected: String
        if schemaVersion == 2 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            expected = Self.digest(try encoder.encode(configuration))
        } else {
            expected = try Self.fingerprint(for: configuration)
        }
        guard fingerprint == expected else { throw BackupError.integrityCheckFailed }
        if schemaVersion == 2 {
            let normalized = try Self.normalized(configuration)
            return TrioSettingsBackup(
                schemaVersion: Self.currentSchema,
                id: id,
                createdAt: createdAt,
                appVersion: appVersion,
                origin: origin,
                name: name,
                configuration: normalized,
                fingerprint: try Self.normalizedFingerprint(normalized)
            )
        }
        return self
    }

    /// A retry may retain a server-side rename, but must not silently lose accounts or history.
    func matchesUploadedSnapshot(_ other: Self) throws -> Bool {
        try id == other.id && createdAt == other.createdAt && origin == other.origin &&
            appVersion == other.appVersion && cloudFingerprint() == other.cloudFingerprint() &&
            historyChecksum == other.historyChecksum
    }

    static func contentsEqual(_ first: Data, _ second: Data) throws -> Bool {
        try JSONDecoder().decode(BackupJSONValue.self, from: first) == JSONDecoder().decode(BackupJSONValue.self, from: second)
    }

    static func readBackupData(from url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Bound the read itself, including files whose size metadata is unavailable.
        let bytes = try file.read(upToCount: maximumSize + 1) ?? Data()
        guard bytes.count <= maximumSize else { throw BackupError.backupTooLarge }
        return bytes
    }

    static func decode(_ bytes: Data, expectedFingerprint: String? = nil) throws -> TrioSettingsBackup {
        guard bytes.count <= maximumSize else { throw BackupError.backupTooLarge }
        let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard let schema = raw?["schemaVersion"] as? Int,
              (2 ... currentSchema).contains(schema) else { throw BackupError.unsupportedSchema }
        let snapshot = try JSONDecoder().decode(Self.self, from: bytes)
        // Compare the stored checksum before schema migration changes it.
        if let expectedFingerprint, snapshot.fingerprint != expectedFingerprint { throw BackupError.integrityCheckFailed }
        return try snapshot.validated()
    }

    static func validate(_ value: Configuration) throws {
        func valid(_ value: Decimal) -> Bool { !value.isNaN }
        func positive(_ value: Decimal) -> Bool { valid(value) && value > 0 }
        func nonnegative(_ value: Decimal) -> Bool { valid(value) && value >= 0 }
        func optional(_ value: Decimal?, _ check: (Decimal) -> Bool) -> Bool { value.map(check) ?? true }
        let prefs = value.preferences
        let limits = DecimalPickerSettings()
        guard value.pumpSettings.insulinActionCurve >= limits.dia.min,
              value.pumpSettings.insulinActionCurve <= limits.dia.max,
              value.pumpSettings.maxBolus <= limits.maxBolus.max,
              value.pumpSettings.maxBasal <= limits.maxBasal.max,
              prefs.maxIOB <= limits.maxIOB.max,
              prefs.autosensMax <= limits.autosensMax.max,
              prefs.maxSMBBasalMinutes <= limits.maxSMBBasalMinutes.max,
              prefs.maxUAMSMBBasalMinutes <= limits.maxUAMSMBBasalMinutes.max,
              positive(prefs.min5mCarbimpact),
              prefs.remainingCarbsFraction >= 0, prefs.remainingCarbsFraction <= 1,
              nonnegative(prefs.remainingCarbsCap), nonnegative(prefs.carbsReqThreshold),
              prefs.maxDeltaBGthreshold > 0, prefs.maxDeltaBGthreshold <= 1,
              positive(prefs.noisyCGMTargetMultiplier), positive(prefs.updateInterval),
              positive(value.pumpSettings.insulinActionCurve),
              positive(value.pumpSettings.maxBolus), positive(value.pumpSettings.maxBasal),
              validSchedule(value.basalProfile.map(\.start), value.basalProfile.map(\.minutes)),
              validSchedule(value.carbRatios.schedule.map(\.start), value.carbRatios.schedule.map(\.offset)),
              validSchedule(
                  value.insulinSensitivities.sensitivities.map(\.start),
                  value.insulinSensitivities.sensitivities.map(\.offset)
              ),
              validSchedule(value.glucoseTargets.targets.map(\.start), value.glucoseTargets.targets.map(\.offset)),
              value.carbRatios.units == .grams,
              value.insulinSensitivities.units == .mgdL, value.glucoseTargets.units == .mgdL,
              value.basalProfile.allSatisfy({ nonnegative($0.rate) && $0.rate <= value.pumpSettings.maxBasal }),
              value.carbRatios.schedule.allSatisfy({ positive($0.ratio) }),
              value.insulinSensitivities.sensitivities.allSatisfy({ positive($0.sensitivity) }),
              value.glucoseTargets.targets.allSatisfy({ positive($0.low) && $0.high >= $0.low }),
              positive(value.settings.insulinConcentration),
              positive(value.settings.low), value.settings.high >= value.settings.low,
              nonnegative(prefs.maxIOB), positive(prefs.autosensMin), prefs.autosensMax >= prefs.autosensMin,
              prefs.smbDeliveryRatio >= 0, prefs.smbDeliveryRatio <= 1,
              prefs.weightPercentage >= 0, prefs.weightPercentage <= 1,
              positive(prefs.maxDailySafetyMultiplier), positive(prefs.currentBasalSafetyMultiplier),
              nonnegative(prefs.maxSMBBasalMinutes), nonnegative(prefs.maxUAMSMBBasalMinutes),
              positive(prefs.smbInterval), positive(prefs.insulinPeakTime),
              prefs.insulinPeakTime < value.pumpSettings.insulinActionCurve * 60,
              positive(prefs.adjustmentFactor), positive(prefs.adjustmentFactorSigmoid),
              positive(prefs.halfBasalExerciseTarget), positive(prefs.threshold_setting),
              nonnegative(prefs.maxCOB), positive(prefs.maxMealAbsorptionTime),
              value.presets.overrides.allSatisfy({
                  $0.percentage.isFinite && $0.percentage >= 0 && $0.percentage <= 500 &&
                      optional($0.duration, nonnegative) && optional($0.target, nonnegative) &&
                      optional($0.smbMinutes, nonnegative) && optional($0.uamMinutes, nonnegative) &&
                      optional($0.start, { nonnegative($0) && $0 < 24 }) &&
                      optional($0.end, { nonnegative($0) && $0 < 24 })
              }),
              value.presets.tempTargets.allSatisfy({
                  optional($0.duration, nonnegative) && optional($0.target, positive) &&
                      optional($0.halfBasalTarget, positive)
              }),
              value.presets.meals.allSatisfy({
                  optional($0.carbs, nonnegative) && optional($0.fat, nonnegative) && optional($0.protein, nonnegative)
              }) else { throw BackupError.invalidTherapyConfiguration }
        if let app = value.appConfiguration {
            let times = [app.glucoseAlertConfiguration.dayStart, app.glucoseAlertConfiguration.nightStart]
            guard times.allSatisfy({ (0 ..< 24).contains($0.hour) && (0 ..< 60).contains($0.minute) }),
                  app.glucoseAlerts.allSatisfy({ nonnegative($0.thresholdMgDL) && $0.snoozedUntil == nil }),
                  Set(app.glucoseAlerts.map(\.id)).count == app.glucoseAlerts.count,
                  Set(app.deviceAlertConfigurations.map(\.id)).count == app.deviceAlertConfigurations.count,
                  app.liveActivityOrder?.count ?? 0 <= 4,
                  app.liveActivityOrder?.allSatisfy({ $0.isEmpty || LiveActivityItem(rawValue: $0) != nil }) ?? true
            else { throw BackupError.invalidTherapyConfiguration }
        }
    }
}

enum BackupError: LocalizedError, Equatable {
    case backupTooLarge
    case incompleteConfiguration
    case invalidTherapyConfiguration
    case unsupportedSchema
    case integrityCheckFailed
    case iCloudUnavailable
    case invalidCloudRecord
    case notOnboarding
    case activeAdjustments
    case operationInProgress
    case restoreFailed
    case pumpNotReady
    case incompatiblePumpSettings
    case backupNameRequired
    case invalidRetentionLimit

    var errorDescription: String? {
        switch self {
        case .backupNameRequired: return "Enter a name for your backup."
        case .invalidRetentionLimit: return "Choose a backup limit of 3, 5, 10, or 15."
        case .backupTooLarge: return "This backup is too large. The limit is 8 MB."
        case .incompleteConfiguration: return "Complete your therapy settings before creating a backup."
        case .invalidTherapyConfiguration: return "This backup has invalid therapy settings and cannot be restored."
        case .unsupportedSchema: return "Update Trio to open this backup."
        case .integrityCheckFailed: return "This backup is damaged and cannot be restored."
        case .iCloudUnavailable: return "Sign in to iCloud in iPhone Settings and enable iCloud for Trio."
        case .invalidCloudRecord: return "The iCloud backup could not be read."
        case .notOnboarding: return "This restore operation is not available during the current setup state."
        case .activeAdjustments: return "Disable all running overrides and temporary targets before restoring settings."
        case .operationInProgress: return "Trio is busy. Wait for the current operation to finish, then try again."
        case .restoreFailed: return "Restore failed. Trio is in Open Loop. Check your settings and pump delivery."
        case .pumpNotReady: return "Restore stopped because pump delivery could not be safely suspended. Check your pump before trying again."
        case .incompatiblePumpSettings: return "This backup’s insulin concentration, basal rates, or delivery limits do not match your pump. Settings were not restored."
        }
    }
}

struct TrioCloudBackupEntry: Identifiable {
    let id: String
    let createdAt: Date
    let origin: TrioSettingsBackup.Origin
    var name: String?
    let fingerprint: String
    var appVersion: String? = nil
    var schemaVersion: Int? = nil
    var validationMessage: String? = nil
}

/// Configuration snapshots live in the current user's PRIVATE CloudKit database.
/// Manual names are editable; identity, creation date, and configuration are kept.
/// The payload, checksum, and manual name are encrypted.
/// CloudKit encryption is not the same thing as local device backup encryption.
protocol TrioCloudBackupStoring {
    func upload(_ snapshot: TrioSettingsBackup) async throws -> TrioCloudBackupEntry
    func list() async throws -> [TrioCloudBackupEntry]
    func download(id: String) async throws -> TrioSettingsBackup
    func delete(id: String) async throws
    func rename(id: String, name: String) async throws -> TrioCloudBackupEntry
}

final class TrioCloudBackupStore: TrioCloudBackupStoring {
    private static let recordType = "TrioSettingsBackup"
    private let container: CKContainer

    init(container: CKContainer = .default()) {
        self.container = container
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    func checkAvailability() async throws {
        let status = try await container.accountStatus()
        guard status == .available else { throw BackupError.iCloudUnavailable }
    }

    func upload(_ snapshot: TrioSettingsBackup) async throws -> TrioCloudBackupEntry {
        try await checkAvailability()
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: snapshot.id.uuidString))
        do { return try entry(from: await save(snapshot, to: record)) }
        catch let error as CKError where error.code == .serverRecordChanged {
            // Retried durable uploads use the same UUID. A manual name may have
            // changed since the original upload; retain the server's metadata.
            let existing = try await database.record(for: record.recordID)
            let saved = try Self.snapshot(from: existing)
            guard try saved.matchesUploadedSnapshot(snapshot.validated()) else { throw BackupError.integrityCheckFailed }
            return try entry(from: existing)
        }
    }

    func rename(id: String, name: String) async throws -> TrioCloudBackupEntry {
        try await checkAvailability()
        guard let name = TrioSettingsBackup.normalizedName(name) else { throw BackupError.backupNameRequired }
        let record = try await database.record(for: CKRecord.ID(recordName: id))
        var snapshot = try Self.snapshot(from: record)
        guard snapshot.origin == .manual else { throw BackupError.invalidCloudRecord }
        snapshot.name = name
        return try entry(from: await save(snapshot, to: record))
    }

    /// Update metadata and payload together. The record's change tag prevents
    /// overwriting a concurrent rename, and its original creation date is kept.
    private func save(_ snapshot: TrioSettingsBackup, to record: CKRecord) async throws -> CKRecord {
        let snapshot = try snapshot.validated()
        try snapshot.cloudConnections?.validate()
        record["createdAt"] = snapshot.createdAt as NSDate
        record["origin"] = snapshot.origin.rawValue as NSString
        record["appVersion"] = snapshot.appVersion as NSString
        record["schemaVersion"] = snapshot.schemaVersion as NSNumber
        record.encryptedValues["fingerprint"] = snapshot.fingerprint as NSString
        record.encryptedValues["name"] = snapshot.name as NSString?
        let bytes = try JSONEncoder().encode(TrioCloudBackupPayload(snapshot))
        guard bytes.count <= TrioSettingsBackup.maximumSize else { throw BackupError.backupTooLarge }
        var assetURL: URL?
        defer { if let assetURL { try? FileManager.default.removeItem(at: assetURL) } }
        if bytes.count > 750_000 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrioCloud-\(UUID()).json")
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            assetURL = url
            record.encryptedValues["snapshot"] = nil
            record["snapshotAsset"] = CKAsset(fileURL: url)
        } else {
            record["snapshotAsset"] = nil
            record.encryptedValues["snapshot"] = bytes as NSData
        }
        return try await database.save(record)
    }

    func list() async throws -> [TrioCloudBackupEntry] {
        try await checkAvailability()
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        let keys = ["createdAt", "origin", "fingerprint", "name", "appVersion", "schemaVersion"]
        var page = try await database.records(matching: query, desiredKeys: keys)
        var entries: [TrioCloudBackupEntry] = []
        while true {
            for (id, result) in page.matchResults {
                do {
                    entries.append(try entry(from: result.get()))
                } catch {
                    // Keep an unavailable/corrupt record visible instead of hiding history.
                    entries.append(TrioCloudBackupEntry(
                        id: id.recordName,
                        createdAt: .distantPast,
                        origin: .automatic,
                        name: "Unavailable Backup",
                        fingerprint: "",
                        validationMessage: error.localizedDescription
                    ))
                }
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor, desiredKeys: keys)
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func download(id: String) async throws -> TrioSettingsBackup {
        try await checkAvailability()
        let record = try await database.record(for: CKRecord.ID(recordName: id))
        return try Self.snapshot(from: record)
    }

    static func snapshot(from record: CKRecord) throws -> TrioSettingsBackup {
        guard let fingerprint = record.encryptedValues["fingerprint"] as? String else { throw BackupError.invalidCloudRecord }
        let bytes: Data
        if let data = record.encryptedValues["snapshot"] as? Data { bytes = data }
        else if let asset = record["snapshotAsset"] as? CKAsset, let url = asset.fileURL {
            bytes = try TrioSettingsBackup.readBackupData(from: url)
        } else { throw BackupError.invalidCloudRecord }
        guard bytes.count <= TrioSettingsBackup.maximumSize else { throw BackupError.backupTooLarge }
        let snapshot: TrioSettingsBackup
        if let payload = try? JSONDecoder().decode(TrioCloudBackupPayload.self, from: bytes) {
            snapshot = try payload.snapshot()
            guard snapshot.fingerprint == fingerprint else { throw BackupError.integrityCheckFailed }
        } else {
            snapshot = try TrioSettingsBackup.decode(bytes, expectedFingerprint: fingerprint)
        }
        guard snapshot.id.uuidString == record.recordID.recordName else { throw BackupError.invalidCloudRecord }
        return snapshot
    }

    func delete(id: String) async throws {
        try await checkAvailability()
        do { _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: id)) }
        catch let error as CKError where error.code == .unknownItem { /* Already deleted by another device. */ }
    }

    private func entry(from record: CKRecord) throws -> TrioCloudBackupEntry {
        guard let date = record["createdAt"] as? Date,
              let originName = record["origin"] as? String,
              let origin = TrioSettingsBackup.Origin(rawValue: originName),
              let fingerprint = record.encryptedValues["fingerprint"] as? String
        else { throw BackupError.invalidCloudRecord }
        return TrioCloudBackupEntry(
            id: record.recordID.recordName,
            createdAt: date,
            origin: origin,
            name: record.encryptedValues["name"] as? String,
            fingerprint: fingerprint,
            appVersion: record["appVersion"] as? String,
            schemaVersion: (record["schemaVersion"] as? NSNumber)?.intValue
        )
    }
}

/// Backup imports must not use the app's forgiving legacy settings decoders to
/// silently replace missing/unknown/mistyped settings with defaults.
private struct BackupStrict<Value: Codable>: Decodable {
    let value: Value
    init(from decoder: Decoder) throws {
        let original = try BackupJSONValue(from: decoder)
        value = try Value(from: decoder)
        let encoded = try JSONEncoder().encode(value)
        guard original == (try JSONDecoder().decode(BackupJSONValue.self, from: encoded)) else {
            throw BackupError.invalidTherapyConfiguration
        }
    }
}

private indirect enum BackupJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([Self])
    case object([String: Self])
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Decimal.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([Self].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
}
