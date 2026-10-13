import CloudKit
import CoreData
import CryptoKit
import Foundation
import Testing
@testable import Trio
#if os(iOS)
    import LoopKit
    @testable import OmnipodKit
    import RileyLinkBLEKit
#endif

@Suite("Cloud Settings Backup", .serialized) struct CloudSettingsBackupTests {
    private let resources = TestResources()

    private func validConfiguration(preferences: Preferences = Preferences()) -> TrioSettingsBackup.Configuration {
        TrioSettingsBackup.Configuration(
            settings: TrioSettings(),
            preferences: preferences,
            pumpSettings: PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2),
            basalProfile: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 1)],
            carbRatios: CarbRatios(
                units: .grams,
                schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 10)]
            ),
            insulinSensitivities: InsulinSensitivities(
                units: .mgdL, userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: 40, offset: 0, start: "00:00:00")]
            ),
            glucoseTargets: BGTargets(
                units: .mgdL, userPreferredUnits: .mgdL,
                targets: [BGTargetEntry(low: 100, high: 100, start: "00:00:00", offset: 0)]
            ),
            presets: .init(
                overrides: [],
                tempTargets: [],
                meals: [.init(dish: "Lunch", carbs: 55, fat: 8, protein: 20)]
            )
        )
    }

    private func makeBackup(
        _ configuration: TrioSettingsBackup.Configuration,
        origin: TrioSettingsBackup.Origin = .manual,
        name: String? = "Baseline",
        createdAt: Date = Date(),
        schemaVersion: Int = TrioSettingsBackup.currentSchema,
        fingerprint: String? = nil
    ) throws -> TrioSettingsBackup {
        TrioSettingsBackup(
            schemaVersion: schemaVersion,
            id: UUID(),
            createdAt: createdAt,
            appVersion: "test",
            origin: origin,
            name: name,
            configuration: configuration,
            fingerprint: try fingerprint ?? TrioSettingsBackup.fingerprint(for: configuration)
        )
    }

    @Test("Configuration round trips through JSON with intact presets") func jsonRoundTrip() throws {
        let backup = try makeBackup(validConfiguration())
        let bytes = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(TrioSettingsBackup.self, from: bytes).validated()
        #expect(decoded.fingerprint == backup.fingerprint)
        #expect(decoded.configuration.presets.meals.first?.dish == "Lunch")
        #expect(decoded.name == "Baseline")
    }

    @Test("Any meaningful preference change alters fingerprint") func fingerprintsChange() throws {
        let baseline = try TrioSettingsBackup.fingerprint(for: validConfiguration())
        var preferences = Preferences()
        preferences.maxIOB = 5
        let changed = try TrioSettingsBackup.fingerprint(for: validConfiguration(preferences: preferences))
        #expect(baseline != changed)
    }

    @Test("A tampered snapshot fails integrity checking") func detectsTampering() throws {
        let altered = try makeBackup(validConfiguration(), fingerprint: "000000")
        #expect(throws: BackupError.self) {
            _ = try altered.validated()
        }
    }

    @Test("Cloud account payloads round trip; portable JSON never contains credentials") func accountPayload() throws {
        var backup = try makeBackup(validConfiguration())
        backup.cloudConnections = .init(nightscout: .init(
            url: "https://example.com",
            secret: "test-secret",
            uploadEnabled: true,
            downloadEnabled: false
        ), tidepoolSession: Data("test-session".utf8))
        let data = try JSONEncoder().encode(TrioCloudBackupPayload(backup))
        let decoded = try JSONDecoder().decode(TrioCloudBackupPayload.self, from: data).snapshot()
        #expect(try decoded.cloudFingerprint() == backup.cloudFingerprint())
        let portable = try JSONEncoder().encode(backup)
        #expect(!String(decoding: portable, as: UTF8.self).contains("test-secret"))
        #expect(try TrioSettingsBackup.decode(portable).cloudConnections == nil)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["connectionsChecksum"] = "invalid"
        let tampered = try JSONDecoder().decode(
            TrioCloudBackupPayload.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(throws: BackupError.integrityCheckFailed) { _ = try tampered.snapshot() }
    }

    @Test("Retry identity permits renaming but rejects changed accounts or history") func uploadRetryIdentity() throws {
        let now = Date()
        var backup = try historyBackup([tdd(now.addingTimeInterval(-300))], createdAt: now)
        backup.cloudConnections = .init(nightscout: .init(
            url: "https://example.com",
            secret: "old-secret",
            uploadEnabled: true,
            downloadEnabled: false
        ))
        var renamed = backup
        renamed.name = "Renamed on another phone"
        #expect(try backup.matchesUploadedSnapshot(renamed))
        var other = backup
        other.cloudConnections = nil
        #expect(try !backup.matchesUploadedSnapshot(other))
        other = backup
        other.dynamicISFHistory = []
        other.historyChecksum = try TrioSettingsBackup.historyDigest([])
        #expect(try !backup.matchesUploadedSnapshot(other))
    }

    @Test("Only settings files trigger automatic backups") func changeFilter() {
        #expect(TrioBackupChangeFilter.shouldBackup(file: OpenAPS.Trio.settings))
        #expect(TrioBackupChangeFilter.shouldBackup(file: OpenAPS.Settings.basalProfile))
        #expect(TrioBackupChangeFilter.shouldBackup(file: OpenAPS.Settings.preferences))
        #expect(!TrioBackupChangeFilter.shouldBackup(file: "pumpHistory.json"))
        #expect(!TrioBackupChangeFilter.shouldBackup(file: "glucose.json"))
        #expect(!TrioBackupChangeFilter.shouldBackup(file: "treatments.json"))
    }

    private func directory() throws -> URL { try resources.directory() }

    private func journalExists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(TrioCloudSettingsRestore.journalFileName).path)
    }

    private func isolatedDefaults() -> UserDefaults { resources.defaults() }

    @MainActor private func coordinator(
        cloud: FakeBackupCloud,
        directory: URL,
        defaults: UserDefaults? = nil,
        capture: ((TrioSettingsBackup.Origin, String?) async throws -> TrioSettingsBackup)? = nil
    ) -> TrioCloudBackupCoordinator {
        TrioCloudBackupCoordinator(
            cloud: cloud,
            defaults: defaults ?? isolatedDefaults(),
            queueURL: directory.appendingPathComponent("queue.json"),
            onboardingInProgress: { false },
            capture: capture ?? { origin, name in
                try makeBackup(validConfiguration(), origin: origin, name: name)
            }
        )
    }

    @Test("Fingerprint ignores transient timestamp and device-derived bolus increment") func transientPreferences() throws {
        var preferences = Preferences()
        preferences.timestamp = Date()
        preferences.bolusIncrement = 0.05
        #expect(
            try TrioSettingsBackup.fingerprint(for: validConfiguration()) ==
                TrioSettingsBackup.fingerprint(for: validConfiguration(preferences: preferences))
        )
    }

    @Test("Preset fetch ordering is canonical; contents and deletion change hashes") func stablePresetOrdering() throws {
        let original = validConfiguration()
        let meals: [TrioSettingsBackup.MealPreset] = [
            .init(dish: "Lunch", carbs: 55, fat: 8, protein: 20),
            .init(dish: "Lunch", carbs: 25, fat: 0, protein: 0)
        ]
        func configuration(_ meals: [TrioSettingsBackup.MealPreset]) -> TrioSettingsBackup.Configuration {
            var configuration = original
            configuration.presets = .init(overrides: [], tempTargets: [], meals: meals)
            return configuration
        }
        let hash = try TrioSettingsBackup.fingerprint(for: configuration(meals))
        #expect(try hash == TrioSettingsBackup.fingerprint(for: configuration(meals.reversed())))
        #expect(try hash != TrioSettingsBackup.fingerprint(for: configuration([meals[0]])))
        #expect(try hash != TrioSettingsBackup.fingerprint(for: configuration([
            .init(dish: "Lunch", carbs: 56, fat: 8, protein: 20), meals[1]
        ])))
    }

    @Test("Both supported schedule time formats validate and share an effective fingerprint") func supportedTimeFormats() throws {
        let original = validConfiguration()
        var short = original
        short.basalProfile = [.init(start: "00:00", minutes: 0, rate: 1)]
        short.carbRatios = .init(units: .grams, schedule: [.init(start: "00:00", offset: 0, ratio: 10)])
        short.insulinSensitivities = .init(
            units: .mgdL, userPreferredUnits: .mgdL,
            sensitivities: [.init(sensitivity: 40, offset: 0, start: "00:00")]
        )
        short.glucoseTargets = .init(
            units: .mgdL, userPreferredUnits: .mgdL,
            targets: [.init(low: 100, high: 100, start: "00:00", offset: 0)]
        )
        _ = try makeBackup(short).validated()
        #expect(try TrioSettingsBackup.fingerprint(for: short) == TrioSettingsBackup.fingerprint(for: original))
        #expect(try TrioCloudSettingsRestore.onboardingConfiguration(short).basalProfile.first?.start == "00:00:00")
    }

    @Test("Zero override target preserves Trio's no-target sentinel semantics") func noTargetOverride() throws {
        let source = validConfiguration()
        var preset = TrioSettingsBackup.OverridePreset(
            name: "Basal only",
            order: 1,
            percentage: 90,
            duration: 60,
            indefinite: false,
            target: 0,
            isf: false,
            cr: false,
            isfAndCr: false,
            advancedSettings: false,
            smbIsScheduledOff: false,
            smbIsOff: false,
            smbMinutes: 30,
            uamMinutes: 30,
            start: 0,
            end: 0
        )
        func configuration(_ preset: TrioSettingsBackup.OverridePreset) -> TrioSettingsBackup.Configuration {
            var configuration = source
            configuration.presets = .init(overrides: [preset], tempTargets: [], meals: [])
            return configuration
        }
        let zero = configuration(preset)
        _ = try makeBackup(zero).validated()
        preset.target = nil
        #expect(try TrioSettingsBackup.fingerprint(for: zero) == TrioSettingsBackup.fingerprint(for: configuration(preset)))
        #expect(try TrioCloudSettingsRestore.onboardingConfiguration(zero).presets.overrides.first?.target == nil)
    }

    @Test("Schedules retain Decimal precision") func decimalPrecision() throws {
        let rate = Decimal(string: "0.123456789012345678")!
        let basal = BasalProfileEntry(start: "00:00:00", minutes: 0, rate: rate)
        let decoded = try JSONDecoder().decode(BasalProfileEntry.self, from: JSONEncoder().encode(basal))
        #expect(decoded.rate == rate)
        let ratio = CarbRatioEntry(start: "00:00:00", offset: 0, ratio: rate)
        #expect(try JSONDecoder().decode(CarbRatioEntry.self, from: JSONEncoder().encode(ratio)).ratio == rate)
        let isf = InsulinSensitivityEntry(sensitivity: rate, offset: 0, start: "00:00:00")
        #expect(try JSONDecoder().decode(InsulinSensitivityEntry.self, from: JSONEncoder().encode(isf)).sensitivity == rate)
    }

    @Test(
        "Missing, unknown and mistyped saved settings fail instead of defaulting",
        arguments: ["missing", "unknown", "mistyped"]
    ) func strictDecoding(_ mutation: String) throws {
        let backup = try makeBackup(validConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        var configuration = try #require(object["configuration"] as? [String: Any])
        var preferences = try #require(configuration["preferences"] as? [String: Any])
        if mutation == "missing" { preferences.removeValue(forKey: "max_iob") }
        if mutation == "unknown" { preferences["future_dosing_feature"] = true }
        if mutation == "mistyped" { preferences["max_iob"] = "invalid" }
        configuration["preferences"] = preferences
        object["configuration"] = configuration
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: BackupError.self) { _ = try TrioSettingsBackup.decode(bytes) }
    }

    @Test("Corrupt JSON and future schemas are rejected") func invalidImports() throws {
        #expect(throws: Error.self) { _ = try TrioSettingsBackup.decode(Data("{bad".utf8)) }
        let original = try makeBackup(validConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 999
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: BackupError.self) { _ = try TrioSettingsBackup.decode(bytes) }
    }

    @Test("Schema 2 verifies its checksum before normalization/migration") func migration() throws {
        let configuration = validConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(configuration)).map { String(format: "%02x", $0) }.joined()
        let legacy = try makeBackup(configuration, name: "Old settings", schemaVersion: 2, fingerprint: fingerprint)
        let bytes = try JSONEncoder().encode(legacy)
        let migrated = try TrioSettingsBackup.decode(bytes, expectedFingerprint: fingerprint)
        #expect(migrated.schemaVersion == TrioSettingsBackup.currentSchema)
        #expect(migrated.configuration.preferences.maxIOB == configuration.preferences.maxIOB)
        #expect(migrated.configuration.appConfiguration == nil)
        #expect(throws: BackupError.integrityCheckFailed) {
            _ = try TrioSettingsBackup.decode(bytes, expectedFingerprint: "wrong checksum")
        }
    }

    @Test(
        "Critical therapy validation rejects incomplete or inconsistent settings",
        arguments: [
            "negativeIOB",
            "autosens",
            "SMB",
            "peak",
            "nonmidnight",
            "duplicate",
            "basalLimit",
            "timeMismatch",
            "excessIOB",
            "excessSMB",
            "invalidCarbImpact"
        ]
    ) func therapyValidation(_ mutation: String) throws {
        let original = validConfiguration()
        var preferences = original.preferences
        var basal = original.basalProfile
        switch mutation {
        case "excessIOB": preferences.maxIOB = 31
        case "excessSMB": preferences.maxSMBBasalMinutes = 181
        case "invalidCarbImpact": preferences.min5mCarbimpact = 0
        case "negativeIOB": preferences.maxIOB = -1
        case "autosens": preferences.autosensMin = 2
            preferences.autosensMax = 1
        case "SMB": preferences.smbDeliveryRatio = 1.1
        case "peak": preferences.insulinPeakTime = 601
        case "nonmidnight": basal = [.init(start: "01:00:00", minutes: 60, rate: 1)]
        case "duplicate": basal.append(basal[0])
        case "basalLimit": basal = [.init(start: "00:00:00", minutes: 0, rate: 3)]
        default: basal = [.init(start: "01:00:00", minutes: 0, rate: 1)]
        }
        var invalid = original
        invalid.preferences = preferences
        invalid.basalProfile = basal
        #expect(throws: BackupError.self) { _ = try makeBackup(invalid).validated() }
    }

    @Test("App configuration round trips while snoozes and associations are removed") func completeAppConfiguration() throws {
        var configuration = validConfiguration()
        var alert = GlucoseAlert(type: .low)
        alert.snoozedUntil = Date().addingTimeInterval(600)
        configuration.appConfiguration = .init(
            appearance: .dark,
            liveActivityOrder: ["iob", "cob", "", ""],
            glucoseAlerts: [alert],
            glucoseAlertConfiguration: .init(),
            deviceAlertConfigurations: [.init(severity: .critical)]
        )
        let safe = try TrioSettingsBackup.normalized(configuration)
        let decoded = try TrioSettingsBackup.decode(JSONEncoder().encode(makeBackup(safe)))
        #expect(decoded.configuration.appConfiguration?.appearance == .dark)
        #expect(decoded.configuration.appConfiguration?.liveActivityOrder?.first == "iob")
        #expect(decoded.configuration.appConfiguration?.glucoseAlerts.first?.snoozedUntil == nil)
        #expect(decoded.configuration.settings.cgm == .none)
        let text = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!text.contains("pumpManagerRawValue"))
        #expect(!text.contains("snoozedUntil"))
        #expect(!text.contains("sharedSecret"))
    }

    @Test("Rollback reload retains the alert stores' existing migration and baseline rules") func alertStoreRollbackReload() throws {
        let defaults = isolatedDefaults()
        let glucose = GlucoseAlertsStore(defaults: defaults)
        let low = GlucoseAlert(type: .low)
        try defaults.set(JSONEncoder().encode([low]), forKey: "trio.glucoseAlerts.v1")
        glucose.reloadSavedConfiguration()
        #expect(Set(glucose.alerts.map(\.type)) == Set(GlucoseAlertType.allCases))
        #expect(glucose.alerts.contains(where: { $0.id == low.id }))
        let device = DeviceAlertsStore(defaults: defaults)
        try defaults.set(JSONEncoder().encode([DeviceAlertSeverityConfig]()), forKey: "trio.deviceAlertSeverityConfigs.v1")
        device.reloadSavedConfiguration()
        #expect(DeviceAlertSeverity.allCases.allSatisfy { severity in
            device.configs.contains(where: { $0.severity == severity && $0.activeOption == .always })
        })
    }

    @Test("Default alert row identities do not create redundant backups across launches") func alertIdentityNormalization() throws {
        var first = validConfiguration()
        first.appConfiguration = .init(
            appearance: .systemDefault,
            liveActivityOrder: nil,
            glucoseAlerts: [GlucoseAlert(type: .low)],
            glucoseAlertConfiguration: .init(),
            deviceAlertConfigurations: [.init(severity: .critical)]
        )
        var second = validConfiguration()
        second.appConfiguration = .init(
            appearance: .systemDefault,
            liveActivityOrder: nil,
            glucoseAlerts: [GlucoseAlert(type: .low)],
            glucoseAlertConfiguration: .init(),
            deviceAlertConfigurations: [.init(severity: .critical)]
        )
        #expect(try TrioSettingsBackup.fingerprint(for: first) == TrioSettingsBackup.fingerprint(for: second))
    }

    @MainActor
    @Test("Trailing debounce never exceeds the 15-minute continuous-edit limit") func coalescing() {
        let first = Date(timeIntervalSince1970: 1000)
        #expect(TrioCloudBackupCoordinator.deadline(first: first, last: first) == first.addingTimeInterval(300))
        #expect(
            TrioCloudBackupCoordinator.deadline(first: first, last: first.addingTimeInterval(120)) == first
                .addingTimeInterval(420)
        )
        #expect(
            TrioCloudBackupCoordinator.deadline(first: first, last: first.addingTimeInterval(800)) == first
                .addingTimeInterval(900)
        )
    }

    @MainActor
    @Test(
        "Continuous edits at the maximum deadline cannot indefinitely postpone a snapshot"
    ) func maximumWindowUnderConcurrentEdits() async throws {
        let directory = try directory()
        let cloud = FakeBackupCloud()
        weak var reference: TrioCloudBackupCoordinator?
        let coordinator = coordinator(
            cloud: cloud,
            directory: directory,
            capture: { origin, _ in
                reference?.markChanged()
                return try makeBackup(validConfiguration(), origin: origin)
            }
        )
        reference = coordinator
        coordinator.markChanged(at: Date().addingTimeInterval(-1000))
        await coordinator.runAutomaticBackup()
        #expect(cloud.uploads.count == 1)
        #expect(try coordinator.pendingOperationCount() == 1)
        coordinator.automaticEnabled = false
    }

    @Test("Oversized imports are rejected before JSON decoding") func oversizedImport() {
        #expect(throws: BackupError.backupTooLarge) {
            _ = try TrioSettingsBackup.decode(Data(repeating: 0, count: TrioSettingsBackup.maximumSize + 1))
        }
    }

    @Test("Cloud records validate inline/asset payloads, checksum and record identity") func cloudRecordValidation() throws {
        let directory = try directory()
        let snapshot = try makeBackup(validConfiguration())
        let bytes = try JSONEncoder().encode(snapshot)
        let record = CKRecord(recordType: "TrioSettingsBackup", recordID: .init(recordName: snapshot.id.uuidString))
        record.encryptedValues["snapshot"] = bytes as NSData
        record.encryptedValues["fingerprint"] = snapshot.fingerprint as NSString
        #expect(try TrioCloudBackupStore.snapshot(from: record).id == snapshot.id)
        record.encryptedValues["fingerprint"] = "wrong checksum" as NSString
        #expect(throws: BackupError.integrityCheckFailed) { _ = try TrioCloudBackupStore.snapshot(from: record) }
        record.encryptedValues["fingerprint"] = snapshot.fingerprint as NSString
        record.encryptedValues["snapshot"] = nil
        let url = directory.appendingPathComponent("backup.json")
        try bytes.write(to: url)
        record["snapshotAsset"] = CKAsset(fileURL: url)
        #expect(try TrioCloudBackupStore.snapshot(from: record).id == snapshot.id)
        let wrongID = CKRecord(recordType: "TrioSettingsBackup", recordID: .init(recordName: UUID().uuidString))
        wrongID.encryptedValues["snapshot"] = bytes as NSData
        wrongID.encryptedValues["fingerprint"] = snapshot.fingerprint as NSString
        #expect(throws: BackupError.invalidCloudRecord) { _ = try TrioCloudBackupStore.snapshot(from: wrongID) }
        record["snapshotAsset"] = nil
        #expect(throws: BackupError.invalidCloudRecord) { _ = try TrioCloudBackupStore.snapshot(from: record) }
    }

    @Test("File imports and CloudKit assets reject oversized files before parsing") func boundedFileRead() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("large.json")
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(TrioSettingsBackup.maximumSize + 1024))
        #expect(throws: BackupError.backupTooLarge) { _ = try TrioSettingsBackup.readBackupData(from: url) }
        let record = CKRecord(recordType: "TrioSettingsBackup")
        record.encryptedValues["fingerprint"] = "checksum" as NSString
        record["snapshotAsset"] = CKAsset(fileURL: url)
        #expect(throws: BackupError.backupTooLarge) { _ = try TrioCloudBackupStore.snapshot(from: record) }
        record["snapshotAsset"] = nil
        record.encryptedValues["snapshot"] = Data(repeating: 0, count: TrioSettingsBackup.maximumSize + 1) as NSData
        #expect(throws: BackupError.backupTooLarge) { _ = try TrioCloudBackupStore.snapshot(from: record) }
    }

    @MainActor
    @Test("Automatic duplicates are suppressed; distinct history and named manuals survive") func duplicateSuppression() async throws {
        let directory = try directory()
        let cloud = FakeBackupCloud()
        let configuration = ConfigurationBox(value: validConfiguration())
        let coordinator = coordinator(cloud: cloud, directory: directory, capture: { origin, name in
            try makeBackup(configuration.value, origin: origin, name: name)
        })
        coordinator.markChanged()
        await coordinator.runAutomaticBackup()
        coordinator.markChanged()
        await coordinator.runAutomaticBackup()
        #expect(cloud.uploads.count == 1)
        var preferences = Preferences()
        preferences.maxIOB = 5
        configuration.value = validConfiguration(preferences: preferences)
        coordinator.markChanged()
        await coordinator.runAutomaticBackup()
        #expect(cloud.uploads.count == 2)
        _ = try await coordinator.createManualBackup(name: "Before changing settings")
        _ = try await coordinator.createManualBackup(name: "Same settings")
        #expect(cloud.uploads.count == 4)
        #expect(cloud.uploads[2].fingerprint == cloud.uploads[3].fingerprint)
        #expect(cloud.uploads[2].id != cloud.uploads[3].id)
        coordinator.automaticEnabled = false
    }

    @MainActor
    @Test("Offline uploads survive coordinator recreation with the same snapshot UUID") func durableOfflineQueue() async throws {
        let directory = try directory()
        let cloud = FakeBackupCloud()
        cloud.fail = true
        let defaults = isolatedDefaults()
        func coordinator() -> TrioCloudBackupCoordinator {
            self.coordinator(cloud: cloud, directory: directory, defaults: defaults)
        }
        let original = coordinator()
        original.markChanged()
        await original.runAutomaticBackup()
        #expect(original.lastError != nil)
        let pending = try #require(original.loadQueue().first)
        let recreated = coordinator()
        cloud.fail = false
        await recreated.runAutomaticBackup(capturePending: false)
        #expect(cloud.uploads.last?.id == pending.id)
        #expect(try recreated.loadQueue().isEmpty)
        original.automaticEnabled = false
    }

    @MainActor
    @Test("A corrupt local upload queue is preserved and reported") func corruptQueue() async throws {
        let directory = try directory()
        let queue = directory.appendingPathComponent("queue.json")
        let bytes = Data("invalid queue".utf8)
        try bytes.write(to: queue)
        let coordinator = coordinator(cloud: FakeBackupCloud(), directory: directory)
        coordinator.markChanged()
        await coordinator.runAutomaticBackup()
        #expect(coordinator.lastError != nil)
        #expect(try Data(contentsOf: queue) == bytes)
        coordinator.automaticEnabled = false
    }

    private func context() async throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "BackupTest", managedObjectModel: CoreDataStack.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return container.newBackgroundContext()
    }

    @Test("Preset insertion, editing, deletion and ordering preserve treatment history") func coreDataPresets() async throws {
        let context = try await context()
        try await context.perform {
            let history = OverrideStored(context: context)
            history.isPreset = false
            history.name = "Historical"
            history.percentage = 100
            let targetHistory = TempTargetStored(context: context)
            targetHistory.isPreset = false
            targetHistory.name = "Historical target"
            try context.save()
        }
        let preset = TrioSettingsBackup.OverridePreset(
            name: "Exercise",
            order: 2,
            percentage: 70,
            duration: 60,
            indefinite: false,
            target: 120,
            isf: true,
            cr: false,
            isfAndCr: false,
            advancedSettings: true,
            smbIsScheduledOff: false,
            smbIsOff: true,
            smbMinutes: 15,
            uamMinutes: 20,
            start: 0,
            end: 23
        )
        let presets = TrioSettingsBackup.Presets(
            overrides: [preset],
            tempTargets: [.init(name: "Activity", order: 1, duration: 60, target: 120, halfBasalTarget: 160)],
            meals: [.init(dish: "Lunch", carbs: 42, fat: 10, protein: 20)]
        )
        try await TrioCloudSettingsRestore.replacePresets(with: presets, context: context)
        let first = try await TrioSettingsBackup.readPresets(context: context)
        #expect(first.overrides.first?.order == 2)
        #expect(first.overrides.first?.smbMinutes == 15)
        #expect(first.tempTargets.first?.halfBasalTarget == 160)
        #expect(first.meals.first?.carbs == 42)
        try await context.perform {
            let request = OverrideStored.fetchRequest()
            request.predicate = NSPredicate(format: "isPreset == YES")
            let row = try #require(context.fetch(request).first)
            #expect(!row.enabled)
            #expect(row.overrideRun == nil)
            row.orderPosition = 3
            row.percentage = 80
            let targets = TempTargetStored.fetchRequest()
            targets.predicate = NSPredicate(format: "isPreset == YES")
            #expect(try context.fetch(targets).allSatisfy { !$0.enabled && $0.tempTargetRun == nil })
            try context.save()
        }
        let edited = try await TrioSettingsBackup.readPresets(context: context)
        #expect(edited.overrides.first?.order == 3)
        #expect(edited.overrides.first?.percentage == 80)
        try await context.perform {
            let overrideRequest = OverrideStored.fetchRequest()
            overrideRequest.predicate = NSPredicate(format: "isPreset == YES")
            let override = try #require(context.fetch(overrideRequest).first)
            let run = OverrideRunStored(context: context)
            run.id = UUID()
            run.name = "Historical preset run"
            run.override = override
            let targetRequest = TempTargetStored.fetchRequest()
            targetRequest.predicate = NSPredicate(format: "isPreset == YES")
            let target = try #require(context.fetch(targetRequest).first)
            let targetRun = TempTargetRunStored(context: context)
            targetRun.id = UUID()
            targetRun.name = "Historical target run"
            targetRun.tempTarget = target
            try context.save()
        }
        try await TrioCloudSettingsRestore.replacePresets(
            with: .init(overrides: [], tempTargets: [], meals: []),
            context: context
        )
        let empty = try await TrioSettingsBackup.readPresets(context: context)
        #expect(empty.overrides.isEmpty && empty.tempTargets.isEmpty && empty.meals.isEmpty)
        try await context.perform {
            let overrides = try context.fetch(OverrideStored.fetchRequest())
            let targets = try context.fetch(TempTargetStored.fetchRequest())
            #expect(overrides.contains(where: { $0.name == "Historical" }))
            #expect(targets.contains(where: { $0.name == "Historical target" }))
            let runs = try context.fetch(OverrideRunStored.fetchRequest())
            let targetRuns = try context.fetch(TempTargetRunStored.fetchRequest())
            #expect(runs.first?.override?.percentage == 80)
            #expect(runs.first?.override?.isPreset == false)
            #expect(targetRuns.first?.tempTarget?.target?.decimalValue == 120)
            #expect(targetRuns.first?.tempTarget?.isPreset == false)
        }
    }

    @Test("Onboarding preserves non-default preferences and forces Open Loop") func onboardingConfiguration() throws {
        var prefs = Preferences()
        prefs.maxIOB = 5
        prefs.sigmoid = true
        prefs.useWeightedAverage = true
        prefs.insulinPeakTime = 65
        prefs.enableSMBAlways = true
        var source = validConfiguration(preferences: prefs)
        source.settings.dosingMode = .closed
        let restored = try TrioCloudSettingsRestore.onboardingConfiguration(source)
        #expect(restored.settings.dosingMode == .open)
        #expect(restored.preferences.maxIOB == 5)
        #expect(restored.preferences.sigmoid && restored.preferences.useWeightedAverage)
        #expect(restored.preferences.insulinPeakTime == 65)
        #expect(restored.preferences.enableSMBAlways)
    }

    #if os(iOS)
        @MainActor
        @Test("Staged onboarding restoration cannot run manual default-saving code") func onboardingCompletionDoesNotSaveDefaults() throws {
            let state = Onboarding.StateModel()
            state.pendingCloudRestore = try makeBackup(validConfiguration())
            // No injected SettingsManager/FileStorage: an accidental save would fail.
            state.saveOnboardingData()
            #expect(state.pendingCloudRestore != nil)
            state.chooseCloudRestoreOption(.startFresh)
            #expect(state.pendingCloudRestore == nil)
        }
    #endif

    private enum Interrupted: Error { case terminated }

    @MainActor
    @Test(
        "Interruption at every persistence phase recovers all files and presets",
        arguments: Array(0 ..< 11)
    ) func interruptedRestore(_ stop: Int) async throws {
        let directory = try directory()
        let context = try await context()
        let originals = validConfiguration().presets
        try await TrioCloudSettingsRestore.replacePresets(with: originals, context: context)
        let defaults = isolatedDefaults()
        defaults.set("dark", forKey: "colorSchemePreference")
        // Original files are absent: recovery must remove partially-created files.
        let files = TrioCloudSettingsRestore.names.map { ($0, Data("{}".utf8)) }
        var phaseIndex = 0
        await #expect(throws: Interrupted.self) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: files,
                presets: .init(overrides: [], tempTargets: [], meals: []),
                directory: directory,
                context: context,
                defaults: defaults,
                synchronizeCache: { defaults.set("light", forKey: "colorSchemePreference") },
                phase: { _ in
                    defer { phaseIndex += 1 }
                    if phaseIndex == stop { throw Interrupted.terminated }
                }
            )
        }
        #expect(
            journalExists(in: directory)
        )
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: defaults
        )
        #expect(
            !journalExists(in: directory)
        )
        for name in TrioCloudSettingsRestore.names {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        let recovered = try await TrioSettingsBackup.readPresets(context: context)
        #expect(recovered.meals.first?.dish == "Lunch")
        #expect(defaults.string(forKey: "colorSchemePreference") == "dark")
    }

    @MainActor
    @Test("Persistence verification failure retains journal for rollback") func failedVerification() async throws {
        let directory = try directory()
        let context = try await context()
        let files = TrioCloudSettingsRestore.names.map { ($0, Data("{}".utf8)) }
        await #expect(throws: BackupError.self) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: files,
                presets: validConfiguration().presets,
                directory: directory,
                context: context,
                defaults: isolatedDefaults(),
                synchronizeCache: {
                    try Data("unexpected mutation".utf8).write(to: directory.appendingPathComponent(files[0].0))
                }
            )
        }
        #expect(
            journalExists(in: directory)
        )
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: isolatedDefaults()
        )
    }

    @MainActor
    @Test("Active adjustments reject restore before any journal or file writes") func activeAdjustmentTransaction() async throws {
        let directory = try directory()
        let context = try await context()
        try await context.perform {
            let target = TempTargetStored(context: context)
            target.enabled = true
            target.isPreset = false
            try context.save()
        }
        await #expect(throws: BackupError.activeAdjustments) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: TrioCloudSettingsRestore.names.map { ($0, Data()) },
                presets: validConfiguration().presets, directory: directory, context: context, defaults: isolatedDefaults()
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @MainActor
    @Test("Successful persistence keeps a recoverable rollback and preserves non-default therapy") func successfulTransaction(
    ) async throws {
        let directory = try directory()
        let context = try await context()
        let original = validConfiguration()
        let originalSettings = directory.appendingPathComponent(OpenAPS.Trio.settings)
        try FileManager.default.createDirectory(
            at: originalSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var settings = original.settings
        settings.dosingMode = .closed
        try JSONCoding.encoder.encode(settings).write(to: originalSettings)
        let preferencesURL = directory.appendingPathComponent(OpenAPS.Settings.preferences)
        try JSONCoding.encoder.encode(original.preferences).write(to: preferencesURL)
        try await TrioCloudSettingsRestore.replacePresets(with: original.presets, context: context)
        var preferences = Preferences()
        preferences.maxIOB = 5
        preferences.sigmoid = true
        preferences.insulinPeakTime = 65
        let candidate = try TrioCloudSettingsRestore.onboardingConfiguration(validConfiguration(preferences: preferences))
        let files = try TrioCloudSettingsRestore.configurationFiles(candidate)
        var verified = false
        let defaults = isolatedDefaults()
        try await TrioCloudSettingsRestore.performTransaction(
            newFiles: files,
            presets: candidate.presets,
            directory: directory,
            context: context,
            defaults: defaults,
            verifyConfiguration: { verified = true }
        )
        #expect(verified)
        #expect(
            !journalExists(in: directory)
        )
        let saved = try JSONCoding.decoder.decode(Preferences.self, from: Data(contentsOf: preferencesURL))
        #expect(saved.maxIOB == 5 && saved.sigmoid && saved.insulinPeakTime == 65)
        let rollback = directory.appendingPathComponent(TrioCloudSettingsRestore.rollbackFileName)
        #expect(FileManager.default.fileExists(atPath: rollback.path))
        try FileManager.default.copyItem(
            at: rollback,
            to: directory.appendingPathComponent(TrioCloudSettingsRestore.journalFileName)
        )
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: defaults
        )
        let recovered = try JSONCoding.decoder.decode(Preferences.self, from: Data(contentsOf: preferencesURL))
        #expect(recovered == original.preferences)
        let recoveredSettings = try JSONCoding.decoder.decode(TrioSettings.self, from: Data(contentsOf: originalSettings))
        #expect(recoveredSettings.dosingMode == .open)
    }

    @MainActor
    @Test("A real filesystem write failure retains a journal and can be rolled back") func filesystemFailure() async throws {
        let directory = try directory()
        let context = try await context()
        let blocked = directory.appendingPathComponent("settings")
        try Data("original blocker".utf8).write(to: blocked)
        let defaults = isolatedDefaults()
        await #expect(throws: Error.self) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: TrioCloudSettingsRestore.names.map { ($0, Data("{}".utf8)) },
                presets: validConfiguration().presets, directory: directory, context: context, defaults: defaults
            )
        }
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: defaults
        )
        #expect(try Data(contentsOf: blocked) == Data("original blocker".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(OpenAPS.Settings.preferences).path))
    }

    @MainActor
    @Test("Core Data save failure keeps rollback until persistence becomes available") func coreDataSaveFailure() async throws {
        let directory = try directory()
        let ordinary = try await context()
        // Persist a real prior configuration so rollback itself requires a save.
        try await TrioCloudSettingsRestore.replacePresets(with: validConfiguration().presets, context: ordinary)
        let context = FailingSaveContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = ordinary.persistentStoreCoordinator
        let defaults = isolatedDefaults()
        await #expect(throws: FailingSaveContext.Failure.self) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: TrioCloudSettingsRestore.names.map { ($0, Data("{}".utf8)) },
                presets: validConfiguration().presets, directory: directory, context: context, defaults: defaults
            )
        }
        await #expect(throws: FailingSaveContext.Failure.self) {
            try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
                directory: directory,
                context: context,
                defaults: defaults
            )
        }
        let clean = await context.perform { !context.hasChanges && context.transactionAuthor == nil }
        #expect(clean)
        #expect(
            journalExists(in: directory)
        )
        await context.perform { context.shouldFail = false }
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: defaults
        )
        #expect(
            !journalExists(in: directory)
        )
    }

    @MainActor
    @Test("Reinstallation checks cloud history before uploading an identical automatic snapshot") func reinstallDeduplication(
    ) async throws {
        let directory = try directory()
        let cloud = FakeBackupCloud()
        let snapshot = try makeBackup(validConfiguration(), origin: .automatic)
        cloud.history = [.init(
            id: snapshot.id.uuidString,
            createdAt: snapshot.createdAt,
            origin: .automatic,
            name: nil,
            fingerprint: snapshot.fingerprint
        )]
        cloud.downloads[snapshot.id.uuidString] = snapshot
        let coordinator = coordinator(
            cloud: cloud,
            directory: directory,
            capture: { _, _ in snapshot }
        )
        coordinator.markChanged()
        await coordinator.runAutomaticBackup()
        #expect(cloud.uploads.isEmpty)
        #expect(try coordinator.loadQueue().isEmpty)
        coordinator.automaticEnabled = false
    }

    @MainActor
    @Test("Retention treats origins separately, ignores unavailable records and retries failed cleanup") func retention() async throws {
        let directory = try directory()
        let cloud = FakeBackupCloud()
        let now = Date()
        cloud.history = TrioSettingsBackup.Origin.allCases.flatMap { origin in
            (0 ..< 5).map { index in
                TrioCloudBackupEntry(
                    id: "\(origin.rawValue)-\(index)",
                    createdAt: now.addingTimeInterval(-Double(index)),
                    origin: origin,
                    fingerprint: "test"
                )
            }
        }
        cloud.history.append(.init(
            id: "unreadable",
            createdAt: .distantPast,
            origin: .manual,
            fingerprint: "",
            validationMessage: "Unavailable"
        ))
        let coordinator = coordinator(cloud: cloud, directory: directory)
        try await coordinator.setRetentionLimit(3, for: .manual)
        #expect(cloud.deleted == ["manual-3", "manual-4"])
        cloud.fail = true
        await #expect(throws: BackupError.iCloudUnavailable) { try await coordinator.setRetentionLimit(3, for: .automatic) }
        #expect(coordinator.retentionLimit(for: .automatic) == 3)
        cloud.fail = false
        await coordinator.runAutomaticBackup(capturePending: false)
        #expect(cloud.deleted == ["manual-3", "manual-4", "automatic-3", "automatic-4"])
        #expect(cloud.history.contains { $0.id == "unreadable" })
        coordinator.automaticEnabled = false
    }

    @MainActor
    @Test("Pending manual backups remain independent of the automatic toggle") func manualRetryWhenAutomaticDisabled() async throws {
        let directory = try directory()
        let cloud = FakeBackupCloud()
        cloud.fail = true
        let coordinator = coordinator(cloud: cloud, directory: directory)
        await #expect(throws: BackupError.iCloudUnavailable) {
            _ = try await coordinator.createManualBackup(name: "Offline manual") }
        coordinator.automaticEnabled = false
        cloud.fail = false
        await coordinator.runAutomaticBackup(capturePending: false)
        #expect(cloud.uploads.count == 1)
        #expect(try coordinator.loadQueue().isEmpty)
    }

    @Test("Corrupt and incomplete rollback journals fail without touching configuration") func corruptJournal() async throws {
        let directory = try directory()
        let context = try await context()
        let marker = directory.appendingPathComponent("preferences.json")
        try Data("original".utf8).write(to: marker)
        let journal = TrioCloudSettingsRestore.Journal(
            files: [.init(name: "../unsafe", contents: Data())],
            presets: validConfiguration().presets
        )
        let journalURL = directory.appendingPathComponent(TrioCloudSettingsRestore.journalFileName)
        try JSONEncoder().encode(journal).write(to: journalURL)
        await #expect(throws: BackupError.self) {
            try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
                directory: directory,
                context: context,
                defaults: isolatedDefaults()
            )
        }
        #expect(try Data(contentsOf: marker) == Data("original".utf8))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    private func tdd(_ date: Date, id: UUID = UUID(), total: Decimal = 40) -> TrioSettingsBackup.TDDRecord {
        .init(id: id, date: date, total: total, bolus: 20, tempBasal: 10, scheduledBasal: 10, weightedAverage: 40)
    }

    private func historyBackup(_ history: [TrioSettingsBackup.TDDRecord], createdAt: Date) throws -> TrioSettingsBackup {
        var backup = try makeBackup(validConfiguration(), createdAt: createdAt)
        backup.dynamicISFHistory = history
        backup.historyChecksum = try TrioSettingsBackup.historyDigest(history)
        return backup
    }

    @Test("History has independent integrity and does not change configuration deduplication") func historyIntegrity() throws {
        let now = Date()
        var backup = try historyBackup([tdd(now.addingTimeInterval(-300))], createdAt: now)
        let restored = try TrioSettingsBackup.decode(JSONEncoder().encode(backup))
        #expect(restored.dynamicISFHistory == backup.dynamicISFHistory)
        #expect(backup.fingerprint == (try makeBackup(validConfiguration())).fingerprint)
        backup.dynamicISFHistory = [tdd(now.addingTimeInterval(-300), total: 100)]
        #expect(throws: BackupError.integrityCheckFailed) { _ = try backup.validated() }
    }

    @Test("History is skipped at seven days, preserves dates and rejects future records") func historyAge() throws {
        let now = Date()
        let backup = try historyBackup([tdd(now.addingTimeInterval(-86400))], createdAt: now)
        #expect(backup.eligibleTDDHistory(now: now.addingTimeInterval(7 * 86400 - 1)).count == 1)
        #expect(backup.eligibleTDDHistory(now: now.addingTimeInterval(7 * 86400)).isEmpty)
        #expect(backup.eligibleTDDHistory(now: now.addingTimeInterval(-1)).isEmpty)
        #expect(backup.eligibleTDDHistory(now: now).first?.date == now.addingTimeInterval(-86400))
        let future = try historyBackup([tdd(now.addingTimeInterval(1))], createdAt: now)
        #expect(throws: BackupError.invalidTherapyConfiguration) { _ = try future.validated() }
    }

    @Test("Schema-three files remain readable without imported history") func schemaThree() throws {
        let current = try makeBackup(validConfiguration())
        let legacy = try makeBackup(current.configuration, schemaVersion: 3)
        let decoded = try TrioSettingsBackup.decode(JSONEncoder().encode(legacy))
        #expect(decoded.eligibleTDDHistory().isEmpty)
        #expect(decoded.fingerprint == current.fingerprint)
    }

    @Test("A running operation excludes restore and restore excludes every new operation") func bidirectionalInterlock() {
        let gate = TrioBackupOperationGate()
        #expect(gate.beginOperation())
        #expect(gate.beginOperation())
        #expect(!gate.beginRestore())
        gate.endOperation()
        #expect(!gate.beginRestore())
        gate.endOperation()
        #expect(gate.beginRestore())
        #expect(gate.isRestoring)
        #expect(!gate.beginRestore())
        #expect(!gate.beginOperation())
        gate.endRestore()
        #expect(!gate.isRestoring)
        #expect(gate.beginRestore())
        gate.endRestore()
        #expect(gate.beginOperation())
        gate.endOperation()
    }

    @Test("Configured restore preserves connections and pump bolus increment, forces Open Loop") func configuredConnections() throws {
        var settings = TrioSettings()
        settings.cgmPluginIdentifier = "existing-cgm"
        settings.isUploadEnabled = true
        settings.isDownloadEnabled = true
        settings.useLocalGlucoseSource = true
        var preferences = Preferences()
        preferences.bolusIncrement = 0.05
        let restored = TrioCloudSettingsRestore.configuredConfiguration(
            validConfiguration(),
            currentSettings: settings,
            currentPreferences: preferences
        )
        #expect(restored.settings.dosingMode == .open)
        #expect(restored.settings.cgmPluginIdentifier == "existing-cgm")
        #expect(
            restored.settings.isUploadEnabled && restored.settings.isDownloadEnabled && restored.settings
                .useLocalGlucoseSource
        )
        #expect(restored.preferences.bolusIncrement == 0.05)
    }

    @MainActor
    @Test("Verified suspension precedes hardware settings; a failed suspension prevents synchronization") func pumpPreparation(
    ) async throws {
        let pump = FakeRestorePump()
        try await TrioCloudSettingsRestore.preparePumpForRestore(pump, configuration: validConfiguration())
        #expect(pump.events == ["ready", "suspend", "verify", "synchronize", "verify"])
        #expect(pump.suspended)
        let failing = FakeRestorePump()
        failing.failSuspension = true
        await #expect(throws: BackupError.pumpNotReady) {
            try await TrioCloudSettingsRestore.preparePumpForRestore(failing, configuration: validConfiguration())
        }
        #expect(failing.events == ["ready", "suspend"])
        let resumed = FakeRestorePump()
        resumed.resumeDuringSync = true
        await #expect(throws: BackupError.pumpNotReady) {
            try await TrioCloudSettingsRestore.preparePumpForRestore(resumed, configuration: validConfiguration())
        }
    }

    @MainActor
    @Test("Failed pump suspension occurs after journaling but before therapy files change") func failedHardwareTransaction() async throws {
        let directory = try directory()
        let context = try await context()
        let original = Data("original".utf8)
        let path = directory.appendingPathComponent(OpenAPS.Settings.preferences)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: path)
        let candidate = validConfiguration()
        await #expect(throws: BackupError.pumpNotReady) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: TrioCloudSettingsRestore.configurationFiles(candidate),
                presets: candidate.presets,
                directory: directory,
                context: context,
                defaults: isolatedDefaults(),
                prepareHardware: { throw BackupError.pumpNotReady }
            )
        }
        #expect(try Data(contentsOf: path) == original)
        #expect(
            journalExists(in: directory)
        )
    }

    @MainActor
    @Test("History import deduplicates five-minute slots and rollback removes only new summaries") func historyRollback() async throws {
        let directory = try directory()
        let context = try await context()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 300) * 300)
        let existingID = UUID()
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(forEntityName: "TDDStored", into: context)
            row.setValue(existingID, forKey: "id")
            row.setValue(now, forKey: "date")
            row.setValue(NSDecimalNumber(value: 50), forKey: "total")
            try context.save()
        }
        let next = tdd(now.addingTimeInterval(-300))
        let history = [tdd(now.addingTimeInterval(1)), next, tdd(now.addingTimeInterval(-299))]
        let missing = try await TrioCloudSettingsRestore.missingTDDHistory(history, context: context)
        #expect(missing.count == 1)
        let candidate = validConfiguration()
        await #expect(throws: BackupError.restoreFailed) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: TrioCloudSettingsRestore.configurationFiles(candidate),
                presets: candidate.presets,
                directory: directory,
                context: context,
                defaults: isolatedDefaults(),
                tddHistory: history,
                phase: { if $0 == .historyWritten { throw BackupError.restoreFailed } }
            )
        }
        let before = try await TrioSettingsBackup.readTDDHistory(context: context, now: now.addingTimeInterval(10))
        #expect(before.count == 2)
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: isolatedDefaults()
        )
        let after = try await TrioSettingsBackup.readTDDHistory(context: context, now: now.addingTimeInterval(10))
        #expect(after.count == 1 && after[0].id == existingID && after[0].total == 50)
        #expect(after[0].date == now)
    }

    @MainActor
    @Test("Qualified local Dynamic ISF history is never supplemented by a backup") func preserveQualifiedHistory() async throws {
        let context = try await context()
        let now = Date()
        try await context.perform {
            for index in 0 ..< 1512 {
                let row = NSEntityDescription.insertNewObject(forEntityName: "TDDStored", into: context)
                row.setValue(UUID(), forKey: "id")
                row.setValue(now.addingTimeInterval(-Double(index) * 300), forKey: "date")
                row.setValue(NSDecimalNumber(value: 50), forKey: "total")
            }
            try context.save()
        }
        let missing = try await TrioCloudSettingsRestore.missingTDDHistory(
            [tdd(now.addingTimeInterval(-6 * 86400))],
            context: context
        )
        #expect(missing.isEmpty)
    }

    @Test("Pending pump reconciliation blocks delivery but permits protective cancellation") func recoveryInterlock() {
        let gate = TrioBackupOperationGate(needsRecovery: { true })
        #expect(!gate.beginOperation())
        #expect(gate.beginOperation(allowRecovery: true))
        #expect(!gate.beginRestore())
        gate.endOperation()
        #expect(gate.beginRestore())
        #expect(!gate.beginOperation(allowRecovery: true))
        gate.endRestore()
    }

    @MainActor
    @Test("Interrupted pump restore keeps a persistent reconciliation requirement after local rollback") func pendingPumpRecovery(
    ) async throws {
        let directory = try directory()
        let context = try await context()
        let candidate = validConfiguration()
        let defaults = isolatedDefaults()
        await #expect(throws: BackupError.pumpNotReady) {
            try await TrioCloudSettingsRestore.performTransaction(
                newFiles: TrioCloudSettingsRestore.configurationFiles(candidate),
                presets: candidate.presets,
                directory: directory,
                context: context,
                defaults: defaults,
                requiresPumpReconciliation: true,
                prepareHardware: { throw BackupError.pumpNotReady }
            )
        }
        #expect(defaults.bool(forKey: TrioCloudSettingsRestore.pumpRecoveryKey))
        // Model a terminated process whose latest defaults write was not persisted.
        defaults.removeObject(forKey: TrioCloudSettingsRestore.pumpRecoveryKey)
        try await TrioCloudSettingsRestore.recoverInterruptedRestoreIfNeeded(
            directory: directory,
            context: context,
            defaults: defaults
        )
        #expect(defaults.bool(forKey: TrioCloudSettingsRestore.pumpRecoveryKey))
        #expect(
            !journalExists(in: directory)
        )
    }

    #if os(iOS)
        @MainActor private func omnipodFixture(suspended: Bool) -> (OmniPumpManager, RestoreTestDeviceProvider) {
            var pod = PodState(
                address: 0x1F00_0001,
                firmwareVersion: "2.7.0",
                iFirmwareVersion: "2.7.0",
                lotNo: 1,
                lotSeq: 1,
                insulinType: .novolog,
                podType: erosType
            )
            pod.setupProgress = .completed
            pod.suspendState = suspended ? .suspended(Date()) : .resumed(Date())
            let state = OmniPumpManagerState(
                isOnboarded: true,
                podState: pod,
                timeZone: .current,
                basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1, startTime: 0, podType: erosType)]),
                maxBasalRateUnitsPerHour: 3,
                maxBolusUnits: 10,
                insulinType: .novolog,
                podType: erosType,
                podKeepAlive: .disabled
            )
            let provider = RestoreTestDeviceProvider()
            return (OmniPumpManager(state: state, rileyLinkDeviceProvider: provider), provider)
        }

        @MainActor
        @Test(
            "Omnipod restore saves the next resume profile without issuing commands or changing suspension"
        ) func suspendedOmnipodProfile() async throws {
            let (pump, provider) = omnipodFixture(suspended: true)
            let initialCalls = provider.deviceRequests
            let schedule: BasalRateSchedule = try await withCheckedThrowingContinuation { continuation in
                pump.syncBasalRateScheduleWhileSuspended(items: [.init(startTime: 0, value: 0.8)]) {
                    continuation.resume(with: $0)
                }
            }
            #expect(schedule.items[0].value == 0.8)
            #expect(pump.state.basalSchedule.entries[0].rate == 0.8)
            guard case .suspended = pump.status.basalDeliveryState else { Issue.record("Restore resumed pod delivery")
                return }
            #expect(provider.deviceRequests == initialCalls)
            #expect(pump.state.podState?.address == 0x1F00_0001)
        }

        @MainActor
        @Test("The suspended Omnipod profile path rejects an active pod without changing its schedule") func activeOmnipodProfile(
        ) async throws {
            let (pump, provider) = omnipodFixture(suspended: false)
            let initialCalls = provider.deviceRequests
            await #expect(throws: Error.self) {
                let _: BasalRateSchedule = try await withCheckedThrowingContinuation { continuation in
                    pump.syncBasalRateScheduleWhileSuspended(items: [.init(startTime: 0, value: 0.8)]) {
                        continuation.resume(with: $0)
                    }
                }
            }
            #expect(pump.state.basalSchedule.entries[0].rate == 1)
            #expect(provider.deviceRequests == initialCalls)
        }
    #endif

    @Test(
        "Open Loop is persisted before restore even on a fresh installation without settings folders"
    ) func freshOpenLoopPersistence() throws {
        let directory = try directory()
        var source = TrioSettings()
        source.dosingMode = .closed
        let open = try TrioCloudSettingsRestore.persistOpenLoop(source, directory: directory)
        let persisted = try JSONCoding.decoder.decode(TrioSettings.self, from: Data(
            contentsOf:
            directory.appendingPathComponent(OpenAPS.Trio.settings)
        ))
        #expect(open.dosingMode == .open && persisted.dosingMode == .open)
    }
}

/// Owns only resources created by this suite instance, including parameterized test cases.
private final class TestResources {
    private var directories: [URL] = []
    private var defaultsSuites: [String] = []

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    func defaults() -> UserDefaults {
        let name = "CloudBackupTests.\(UUID().uuidString)"
        defaultsSuites.append(name)
        return UserDefaults(suiteName: name)!
    }

    deinit {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        for name in defaultsSuites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }
}

@MainActor
private final class ConfigurationBox {
    var value: TrioSettingsBackup.Configuration
    init(value: TrioSettingsBackup.Configuration) { self.value = value }
}

private final class FakeBackupCloud: TrioCloudBackupStoring {
    var fail = false
    var uploads: [TrioSettingsBackup] = []
    var history: [TrioCloudBackupEntry] = []
    var downloads: [String: TrioSettingsBackup] = [:]
    var deleted: Set<String> = []
    func upload(_ snapshot: TrioSettingsBackup) async throws -> TrioCloudBackupEntry {
        if fail { throw BackupError.iCloudUnavailable }
        if !uploads.contains(where: { $0.id == snapshot.id }) { uploads.append(snapshot) }
        downloads[snapshot.id.uuidString] = snapshot
        return .init(
            id: snapshot.id.uuidString,
            createdAt: snapshot.createdAt,
            origin: snapshot.origin,
            name: snapshot.name,
            fingerprint: snapshot.fingerprint
        )
    }

    func list() async throws -> [TrioCloudBackupEntry] { if fail { throw BackupError.iCloudUnavailable }
        return history }

    func download(id: String) async throws -> TrioSettingsBackup {
        if fail { throw BackupError.iCloudUnavailable }
        guard let snapshot = downloads[id] else { throw BackupError.invalidCloudRecord }
        return snapshot
    }

    func delete(id: String) async throws {
        if fail { throw BackupError.iCloudUnavailable }
        deleted.insert(id)
        history.removeAll { $0.id == id }
        downloads.removeValue(forKey: id)
    }

    func rename(id _: String, name _: String) async throws -> TrioCloudBackupEntry { throw BackupError.invalidCloudRecord }
}

private final class FailingSaveContext: NSManagedObjectContext {
    enum Failure: Error { case unavailable }
    var shouldFail = true
    override func save() throws {
        if shouldFail { throw Failure.unavailable }
        try super.save()
    }
}

@MainActor private final class FakeRestorePump: TrioCloudSettingsRestore.RestorePump {
    var events: [String] = []
    var suspended = false
    var failSuspension = false
    var resumeDuringSync = false
    func checkReady() throws { events.append("ready") }
    func suspendAndVerify() async throws {
        events.append("suspend")
        if failSuspension { throw BackupError.pumpNotReady }
        suspended = true
    }

    func verifySuspended() async throws {
        events.append("verify")
        guard suspended else { throw BackupError.pumpNotReady }
    }

    func synchronize(_: TrioSettingsBackup.Configuration) async throws {
        events.append("synchronize")
        if resumeDuringSync { suspended = false }
    }
}

#if os(iOS)
    private final class RestoreTestDeviceProvider: RileyLinkDeviceProvider {
        weak var delegate: RileyLinkDeviceProviderDelegate?
        var idleListeningState: RileyLinkBluetoothDevice.IdleListeningState = .disabled
        var idleListeningEnabled: Bool { false }
        var timerTickEnabled = false
        var connectingCount: Int { 0 }
        var deviceRequests = 0
        var debugDescription: String { "Offline restore test" }
        func deprioritize(_: RileyLinkDevice, completion: (() -> Void)?) { completion?() }
        func assertIdleListening(forcingRestart _: Bool) {}
        func getDevices(_ completion: @escaping ([RileyLinkDevice]) -> Void) { deviceRequests += 1
            completion([]) }

        func connect(_: RileyLinkDevice) { deviceRequests += 1 }
        func disconnect(_: RileyLinkDevice) { deviceRequests += 1 }
        func setScanningEnabled(_ enabled: Bool) { if enabled { deviceRequests += 1 } }
        func shouldConnect(to _: String) -> Bool { false }
    }
#endif
