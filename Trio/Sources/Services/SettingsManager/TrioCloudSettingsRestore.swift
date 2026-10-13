import CoreData
import CryptoKit
import Foundation
#if canImport(UIKit)
    import HealthKit
    import LoopKit
    import LoopKitUI
    import OmnipodKit
#endif

/// A restore journal is written BEFORE any therapy file or preset is changed.
/// If the process terminates mid-restore, the previous files and preset templates
/// are recovered at the next launch before SettingsManager or pump services load.
enum TrioCloudSettingsRestore {
    @MainActor static var isRestoring: Bool { TrioBackupOperationGate.shared.isRestoring }
    static let pumpRecoveryKey = "trio.cloudRestore.pumpReconciliationPending"
    static var requiresPumpReconciliation: Bool { UserDefaults.standard.bool(forKey: pumpRecoveryKey) }
    static let rollbackFileName = ".trio-cloud-rollback.json"
    static let journalFileName = ".trio-cloud-restore-journal.json"
    static let names = [
        OpenAPS.Trio.settings,
        OpenAPS.Settings.preferences,
        OpenAPS.Settings.settings,
        OpenAPS.Settings.basalProfile,
        OpenAPS.Settings.carbRatios,
        OpenAPS.Settings.insulinSensitivities,
        OpenAPS.Settings.bgTargets
    ]

    static func configurationFiles(_ value: TrioSettingsBackup.Configuration) throws -> [(String, Data)] {
        try [
            (OpenAPS.Trio.settings, JSONCoding.encoder.encode(value.settings)),
            (OpenAPS.Settings.preferences, JSONCoding.encoder.encode(value.preferences)),
            (OpenAPS.Settings.settings, JSONCoding.encoder.encode(value.pumpSettings)),
            (OpenAPS.Settings.basalProfile, JSONCoding.encoder.encode(value.basalProfile)),
            (OpenAPS.Settings.carbRatios, JSONCoding.encoder.encode(value.carbRatios)),
            (OpenAPS.Settings.insulinSensitivities, JSONCoding.encoder.encode(value.insulinSensitivities)),
            (OpenAPS.Settings.bgTargets, JSONCoding.encoder.encode(value.glucoseTargets))
        ]
    }

    struct PreviousFile: Codable {
        let name: String
        let contents: Data?
    }

    struct Journal: Codable {
        let files: [PreviousFile]
        let presets: TrioSettingsBackup.Presets
        var defaults: [String: Data]? = nil
        var checksum: String? = nil
        var insertedTDDIDs: [UUID]? = nil
        var requiresPumpReconciliation: Bool? = nil

        private func digest() throws -> String {
            var unsigned = self
            unsigned.checksum = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(unsigned)).map { String(format: "%02x", $0) }.joined()
        }

        func sealed() throws -> Self {
            var value = self
            value.checksum = try digest()
            return value
        }

        func verify() throws {
            // Older in-progress journals were written without a checksum.
            if let checksum, checksum != (try digest()) { throw BackupError.integrityCheckFailed }
        }
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Setup restoration never changes pump pairing or live state.
    @MainActor static func applyDuringOnboarding(
        _ candidate: TrioSettingsBackup,
        settingsManager: SettingsManager,
        deviceManager: DeviceDataManager
    ) async throws {
        guard OnboardingManager.shared.shouldShowOnboarding else { throw BackupError.notOnboarding }
        try await apply(candidate, settingsManager: settingsManager, deviceManager: deviceManager, onboarding: true)
    }

    /// Hardware is represented separately so failure ordering is testable without delivery.
    @MainActor protocol RestorePump: AnyObject {
        func checkReady() throws
        func suspendAndVerify() async throws
        func synchronize(_ configuration: TrioSettingsBackup.Configuration) async throws
        func verifySuspended() async throws
    }

    @MainActor static func preparePumpForRestore(
        _ pump: RestorePump,
        configuration: TrioSettingsBackup.Configuration,
        willSynchronize: () -> Void = {}
    ) async throws {
        try pump.checkReady()
        try await pump.suspendAndVerify()
        try await pump.verifySuspended()
        willSynchronize()
        try await pump.synchronize(configuration)
        try await pump.verifySuspended()
    }

    @MainActor static func withRestoreInterlock(_ operation: () async throws -> Void) async throws {
        guard !TrioCloudBackupCoordinator.shared.isUploading,
              TrioBackupOperationGate.shared.beginRestore() else { throw BackupError.operationInProgress }
        defer { TrioBackupOperationGate.shared.endRestore() }
        try await operation()
    }

    @MainActor static func applyConfigured(
        _ candidate: TrioSettingsBackup,
        settingsManager: SettingsManager,
        deviceManager: DeviceDataManager
    ) async throws {
        try await apply(candidate, settingsManager: settingsManager, deviceManager: deviceManager, onboarding: false)
    }

    @MainActor private static func apply(
        _ candidate: TrioSettingsBackup,
        settingsManager: SettingsManager,
        deviceManager: DeviceDataManager,
        onboarding: Bool
    ) async throws {
        let snapshot = try candidate.validated()
        try await withRestoreInterlock {
            let oldSettings = settingsManager.settings
            let oldPreferences = settingsManager.preferences
            let safe = configuredConfiguration(
                try TrioSettingsBackup.normalized(snapshot.configuration),
                currentSettings: oldSettings,
                currentPreferences: oldPreferences
            )
            var pump: RestorePump?
            #if canImport(UIKit)
                if let connected = deviceManager.pumpManager {
                    guard snapshot.configuration.settings.insulinConcentration == oldSettings.insulinConcentration else {
                        throw BackupError.incompatiblePumpSettings
                    }
                    pump = ConnectedRestorePump(pump: connected, deviceManager: deviceManager)
                    try pump?.checkReady()
                    try ConnectedRestorePump.validate(safe, pump: connected)
                }
            #endif
            let previousPumpConfiguration = pump == nil ? nil : try await savedConfiguration(
                settings: oldSettings,
                preferences: oldPreferences
            )
            var hardwareSettingsAttempted = false
            let newFiles = try configurationFiles(safe)
            do {
                try await performTransaction(
                    newFiles: newFiles, presets: safe.presets, directory: documents,
                    tddHistory: snapshot.eligibleTDDHistory(), requiresPumpReconciliation: pump != nil,
                    preflight: {
                        if onboarding, !OnboardingManager.shared.shouldShowOnboarding { throw BackupError.notOnboarding }
                        if pump == nil, deviceManager.pumpManager != nil { throw BackupError.pumpNotReady }
                        try pump?.checkReady()
                    }, prepareHardware: {
                        // Persist Open Loop before touching hardware; interrupted restores recover Open Loop too.
                        settingsManager.settings = try persistOpenLoop(oldSettings)
                        if let pump {
                            try await preparePumpForRestore(
                                pump,
                                configuration: safe,
                                willSynchronize: { hardwareSettingsAttempted = true }
                            )
                        }
                    }, synchronizeCache: {
                        try safe.appConfiguration?.apply()
                        settingsManager.settings = safe.settings
                        settingsManager.preferences = safe.preferences
                    }, verifyConfiguration: {
                        guard settingsManager.settings == safe.settings else { throw BackupError.restoreFailed }
                        if let expected = safe.appConfiguration {
                            guard try canonical(expected) == canonical(TrioSettingsBackup.AppConfiguration.capture()) else {
                                throw BackupError.restoreFailed
                            }
                        }
                    }, verifyHardware: {
                        try await pump?.verifySuspended()
                    }
                )
                await CoreDataStack.shared.fetchPersistentHistory()
            } catch {
                // A failed restore never resumes delivery or re-enables automation.
                do {
                    try await recoverInterruptedRestoreIfNeeded()
                    settingsManager.settings = try persistOpenLoop(oldSettings)
                    settingsManager.preferences = oldPreferences
                    if hardwareSettingsAttempted, let pump, let previousPumpConfiguration {
                        try await preparePumpForRestore(pump, configuration: previousPumpConfiguration)
                        UserDefaults.standard.removeObject(forKey: pumpRecoveryKey)
                    }
                    GlucoseAlertsStore.shared.reloadSavedConfiguration()
                    DeviceAlertsStore.shared.reloadSavedConfiguration()
                } catch { throw BackupError.restoreFailed }
                throw error
            }
        }
    }

    /// Fresh installations may not have created the nested settings directory yet.
    static func persistOpenLoop(_ source: TrioSettings, directory: URL? = nil) throws -> TrioSettings {
        var settings = source
        settings.dosingMode = .open
        let url = (directory ?? documents).appendingPathComponent(OpenAPS.Trio.settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(settings).write(to: url, options: [.atomic, .completeFileProtection])
        return settings
    }

    @MainActor private static func savedConfiguration(
        settings: TrioSettings,
        preferences: Preferences
    ) async throws -> TrioSettingsBackup
        .Configuration
    {
        func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            try JSONCoding.decoder.decode(type, from: Data(contentsOf: documents.appendingPathComponent(name)))
        }
        return try await .init(
            settings: settings,
            preferences: preferences,
            pumpSettings: read(OpenAPS.Settings.settings, as: PumpSettings.self),
            basalProfile: read(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self),
            carbRatios: read(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
            insulinSensitivities: read(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self),
            glucoseTargets: read(OpenAPS.Settings.bgTargets, as: BGTargets.self),
            presets: TrioSettingsBackup.readPresets(),
            appConfiguration: TrioSettingsBackup.AppConfiguration.capture()
        )
    }

    /// Launch recovery restores local files before managers load. Hardware is reconciled
    /// under the same lease before dosing or driver controls are made available again.
    @MainActor static func reconcilePumpAfterRecovery(
        settingsManager: SettingsManager,
        deviceManager: DeviceDataManager
    ) async throws {
        guard requiresPumpReconciliation else { return }
        try await withRestoreInterlock {
            #if canImport(UIKit)
                guard let connected = deviceManager.pumpManager else { throw BackupError.pumpNotReady }
                let open = try persistOpenLoop(settingsManager.settings)
                settingsManager.settings = open
                let configuration = try await savedConfiguration(settings: open, preferences: settingsManager.preferences)
                let pump = ConnectedRestorePump(pump: connected, deviceManager: deviceManager)
                try await preparePumpForRestore(pump, configuration: configuration)
                settingsManager.settings = try persistOpenLoop(open)
                UserDefaults.standard.removeObject(forKey: pumpRecoveryKey)
            #endif
        }
    }

    static func configuredConfiguration(
        _ source: TrioSettingsBackup.Configuration,
        currentSettings: TrioSettings,
        currentPreferences: Preferences
    ) -> TrioSettingsBackup.Configuration {
        var result = source
        result.settings.dosingMode = .open
        result.settings.cgm = currentSettings.cgm
        result.settings.cgmPluginIdentifier = currentSettings.cgmPluginIdentifier
        result.settings.isUploadEnabled = currentSettings.isUploadEnabled
        result.settings.isDownloadEnabled = currentSettings.isDownloadEnabled
        result.settings.useLocalGlucoseSource = currentSettings.useLocalGlucoseSource
        result.preferences.bolusIncrement = currentPreferences.bolusIncrement
        return result
    }

    static func onboardingConfiguration(_ source: TrioSettingsBackup.Configuration) throws -> TrioSettingsBackup.Configuration {
        var result = try TrioSettingsBackup.normalized(source)
        result.settings.dosingMode = .open
        return result
    }

    enum Phase: Equatable {
        case journalWritten
        case fileWritten(String)
        case presetsWritten
        case historyWritten
        case configurationWritten
        case verified
    }

    /// Shared transaction primitive. Injection enables real filesystem/Core Data
    /// fault and interruption tests without changing the app's documents or drivers.
    @MainActor static func performTransaction(
        newFiles: [(String, Data)], presets: TrioSettingsBackup.Presets,
        directory: URL, context: NSManagedObjectContext? = nil,
        defaults: UserDefaults = .standard,
        tddHistory: [TrioSettingsBackup.TDDRecord] = [],
        requiresPumpReconciliation: Bool = false,
        preflight: () throws -> Void = {},
        prepareHardware: () async throws -> Void = {},
        synchronizeCache: () throws -> Void = {},
        verifyConfiguration: () throws -> Void = {},
        verifyHardware: () async throws -> Void = {},
        phase: (Phase) throws -> Void = { _ in }
    ) async throws {
        let journalURL = directory.appendingPathComponent(journalFileName)
        guard !FileManager.default.fileExists(atPath: journalURL.path),
              newFiles.count == names.count, Set(newFiles.map(\.0)) == Set(names)
        else {
            throw BackupError.restoreFailed
        }
        let previousFiles = try names.map { name in
            let url = directory.appendingPathComponent(name)
            return PreviousFile(
                name: name,
                contents: FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            )
        }
        let taskContext = context ?? CoreDataStack.shared.newTaskContext()
        let originalPresets = try await TrioSettingsBackup.readPresets(context: taskContext)
        func checkPreflight() throws {
            try preflight()
            let active = try taskContext.performAndWait {
                let overrides = OverrideStored.fetchRequest()
                overrides.predicate = NSPredicate(format: "enabled == YES")
                let targets = TempTargetStored.fetchRequest()
                targets.predicate = NSPredicate(format: "enabled == YES")
                return try taskContext.count(for: overrides) > 0 || taskContext.count(for: targets) > 0
            }
            guard !active else { throw BackupError.activeAdjustments }
        }
        try checkPreflight()
        let history = try await missingTDDHistory(tddHistory, context: taskContext)
        let journal = try Journal(
            files: previousFiles,
            presets: originalPresets,
            defaults: readDefaults(defaults: defaults),
            insertedTDDIDs: history.isEmpty ? nil : history.map(\.id),
            requiresPumpReconciliation: requiresPumpReconciliation ? true : nil
        ).sealed()
        let encoded = try JSONEncoder().encode(journal)
        // A successful restore also leaves an independent recoverable local rollback.
        try encoded.write(
            to: directory.appendingPathComponent(rollbackFileName),
            options: [.atomic, .completeFileProtection]
        )
        try encoded.write(to: journalURL, options: [.atomic, .completeFileProtection])
        try phase(.journalWritten)
        if requiresPumpReconciliation { defaults.set(true, forKey: pumpRecoveryKey) }
        try await prepareHardware()
        try checkPreflight()
        for (name, data) in newFiles {
            try checkPreflight()
            let target = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: [.atomic, .completeFileProtection])
            try phase(.fileWritten(name))
        }
        try await replacePresets(with: presets, context: taskContext)
        try phase(.presetsWritten)
        if !history.isEmpty {
            try await insertTDDHistory(history, context: taskContext)
            try phase(.historyWritten)
        }
        try checkPreflight()
        try synchronizeCache()
        try phase(.configurationWritten)
        for (name, expected) in newFiles {
            guard (try? TrioSettingsBackup.contentsEqual(Data(contentsOf: directory.appendingPathComponent(name)), expected)) ==
                true else { throw BackupError.restoreFailed }
        }
        try await verifyPresets(presets, context: taskContext)
        try checkPreflight()
        try verifyConfiguration()
        try await verifyHardware()
        try phase(.verified)
        try FileManager.default.removeItem(at: journalURL)
        if requiresPumpReconciliation { defaults.removeObject(forKey: pumpRecoveryKey) }
    }

    /// Called after Core Data initialization, BEFORE the application loads
    /// SettingsManager and pump/CGM services.
    static func recoverInterruptedRestoreIfNeeded(
        directory: URL? = nil,
        context: NSManagedObjectContext? = nil,
        defaults: UserDefaults = .standard
    ) async throws {
        let documents = directory ?? Self.documents
        let journalURL = documents.appendingPathComponent(journalFileName)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        try journal.verify()
        if journal.requiresPumpReconciliation == true { defaults.set(true, forKey: pumpRecoveryKey) }
        guard journal.files.count == names.count, Set(journal.files.map(\.name)) == Set(names) else {
            throw BackupError.restoreFailed
        }
        // Check the entire journal before writing any file.
        if let saved = journal.defaults, !Set(saved.keys).isSubset(of: Set(TrioSettingsBackup.AppConfiguration.keys)) {
            throw BackupError.restoreFailed
        }
        for item in journal.files {
            if item.name == OpenAPS.Trio.settings, let contents = item.contents {
                _ = try JSONCoding.decoder.decode(TrioSettings.self, from: contents)
            }
        }
        for data in journal.defaults?.values ?? [String: Data]().values {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            guard object?["value"] != nil else { throw BackupError.restoreFailed }
        }
        for item in journal.files {
            let target = documents.appendingPathComponent(item.name)
            if let contents = item.contents {
                let data: Data
                if item.name == OpenAPS.Trio.settings {
                    var settings = try JSONCoding.decoder.decode(TrioSettings.self, from: contents)
                    settings.dosingMode = .open
                    data = try JSONCoding.encoder.encode(settings)
                } else { data = contents }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: [.atomic, .completeFileProtection])
            } else if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }

        if let ids = journal.insertedTDDIDs {
            let historyContext = context ?? CoreDataStack.shared.newTaskContext()
            try await historyContext.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "TDDStored")
                request.predicate = NSPredicate(format: "id IN %@", ids)
                for row in try historyContext.fetch(request) { historyContext.delete(row) }
                do { if historyContext.hasChanges { try historyContext.save() } }
                catch { historyContext.rollback()
                    throw error }
            }
        }
        try await replacePresets(with: journal.presets, context: context)
        if let saved = journal.defaults {
            for key in TrioSettingsBackup.AppConfiguration.keys {
                if let data = saved[key] {
                    let object = try PropertyListSerialization
                        .propertyList(from: data, options: [], format: nil) as? [String: Any]
                    guard let value = object?["value"] else { throw BackupError.restoreFailed }
                    defaults.set(value, forKey: key)
                } else { defaults.removeObject(forKey: key) }
            }
            guard try readDefaults(defaults: defaults) == saved else { throw BackupError.restoreFailed }
        }
        for item in journal.files {
            let target = documents.appendingPathComponent(item.name)
            if let old = item.contents {
                if item.name == OpenAPS.Trio.settings {
                    let recovered = try JSONCoding.decoder.decode(TrioSettings.self, from: Data(contentsOf: target))
                    var expected = try JSONCoding.decoder.decode(TrioSettings.self, from: old)
                    expected.dosingMode = .open
                    guard recovered == expected else { throw BackupError.restoreFailed }
                } else {
                    guard try Data(contentsOf: target) == old else { throw BackupError.restoreFailed }
                }
            } else if FileManager.default.fileExists(atPath: target.path) { throw BackupError.restoreFailed }
        }
        try await verifyPresets(journal.presets, context: context)
        try FileManager.default.removeItem(at: journalURL)
        if context == nil { await CoreDataStack.shared.fetchPersistentHistory() }
    }

    /// At most one imported sample per five-minute bucket. Existing local history wins.
    static func missingTDDHistory(
        _ history: [TrioSettingsBackup.TDDRecord],
        context: NSManagedObjectContext
    ) async throws -> [TrioSettingsBackup.TDDRecord] {
        guard !history.isEmpty else { return [] }
        // Use the same gate as Dynamic ISF. Qualified local history must not be
        // mixed with an older backup, which would change its TDD averages.
        guard !(try await BaseTDDStorage.hasSufficientTDD(context: context)) else { return [] }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "TDDStored")
            request.predicate = NSPredicate(
                format: "date >= %@ OR id IN %@",
                (history.map(\.date).min() ?? Date()).addingTimeInterval(-300) as NSDate,
                history.map(\.id)
            )
            let existing = try context.fetch(request)
            var ids = Set(existing.compactMap { $0.value(forKey: "id") as? UUID })
            var slots = Set(
                existing
                    .compactMap { ($0.value(forKey: "date") as? Date).map { Int($0.timeIntervalSince1970 / 300) } }
            )
            return history.sorted { $0.date < $1.date }.filter { row in
                let slot = Int(row.date.timeIntervalSince1970 / 300)
                guard !ids.contains(row.id), !slots.contains(slot) else { return false }
                ids.insert(row.id)
                slots.insert(slot)
                return true
            }
        }
    }

    private static func insertTDDHistory(
        _ history: [TrioSettingsBackup.TDDRecord],
        context: NSManagedObjectContext
    ) async throws {
        try await context.perform {
            let previousAuthor = context.transactionAuthor
            context.transactionAuthor = "TrioCloudRestore"
            defer { context.transactionAuthor = previousAuthor }
            do {
                for sample in history {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "TDDStored", into: context)
                    row.setValue(sample.id, forKey: "id")
                    row.setValue(sample.date, forKey: "date")
                    for (key, value) in [
                        ("total", sample.total),
                        ("bolus", sample.bolus),
                        ("tempBasal", sample.tempBasal),
                        ("scheduledBasal", sample.scheduledBasal),
                        ("weightedAverage", sample.weightedAverage)
                    ] {
                        row.setValue(NSDecimalNumber(decimal: value), forKey: key)
                    }
                }
                if context.hasChanges { try context.save() }
            } catch { context.rollback()
                throw error }
        }
    }

    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func readDefaults(defaults: UserDefaults = .standard) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for key in TrioSettingsBackup.AppConfiguration.keys {
            if let value = defaults.object(forKey: key) {
                result[key] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
            }
        }
        return result
    }

    private static func verifyPresets(
        _ expected: TrioSettingsBackup.Presets,
        context: NSManagedObjectContext? = nil
    ) async throws {
        let actual = try await TrioSettingsBackup.readPresets(context: context ?? CoreDataStack.shared.newTaskContext())
        let sorted = TrioSettingsBackup.Presets(
            overrides: try TrioSettingsBackup.stableSort(expected.overrides),
            tempTargets: try TrioSettingsBackup.stableSort(expected.tempTargets),
            meals: try TrioSettingsBackup.stableSort(expected.meals)
        )
        guard try canonical(actual) == canonical(sorted) else { throw BackupError.restoreFailed }
    }

    /// A single Core Data save replaces ONLY preset templates. Historical and
    /// currently active overrides / temp targets are left untouched.
    static func replacePresets(with source: TrioSettingsBackup.Presets, context: NSManagedObjectContext? = nil) async throws {
        let context = context ?? CoreDataStack.shared.newTaskContext()
        try await context.perform {
            let previousAuthor = context.transactionAuthor
            defer { context.transactionAuthor = previousAuthor }
            context.transactionAuthor = "TrioCloudRestore"
            do {
                let overrideRequest = OverrideStored.fetchRequest()
                overrideRequest.predicate = NSPredicate(format: "isPreset == YES")
                for row in try context.fetch(overrideRequest) {
                    if row.overrideRun != nil {
                        // Historical runs retain their configuration relationship.
                        // Retire the template rather than nullifying its history link.
                        row.isPreset = false
                        row.enabled = false
                    } else { context.delete(row) }
                }

                let targetRequest = TempTargetStored.fetchRequest()
                targetRequest.predicate = NSPredicate(format: "isPreset == YES")
                for row in try context.fetch(targetRequest) {
                    if row.tempTargetRun != nil {
                        row.isPreset = false
                        row.enabled = false
                    } else { context.delete(row) }
                }

                for row in try context.fetch(MealPresetStored.fetchRequest()) { context.delete(row) }

                for preset in source.overrides {
                    let row = OverrideStored(context: context)
                    row.id = UUID().uuidString
                    row.name = preset.name
                    row.date = .distantPast
                    row.isPreset = true
                    row.enabled = false
                    row.isUploadedToNS = false
                    row.orderPosition = preset.order
                    row.percentage = preset.percentage
                    row.duration = preset.duration.map(NSDecimalNumber.init(decimal:))
                    row.indefinite = preset.indefinite
                    row.target = preset.target.map(NSDecimalNumber.init(decimal:))
                    row.isf = preset.isf
                    row.cr = preset.cr
                    row.isfAndCr = preset.isfAndCr
                    row.advancedSettings = preset.advancedSettings
                    row.smbIsScheduledOff = preset.smbIsScheduledOff
                    row.smbIsOff = preset.smbIsOff
                    row.smbMinutes = preset.smbMinutes.map(NSDecimalNumber.init(decimal:))
                    row.uamMinutes = preset.uamMinutes.map(NSDecimalNumber.init(decimal:))
                    row.start = preset.start.map(NSDecimalNumber.init(decimal:))
                    row.end = preset.end.map(NSDecimalNumber.init(decimal:))
                }

                for preset in source.tempTargets {
                    let row = TempTargetStored(context: context)
                    row.id = UUID()
                    row.name = preset.name
                    row.date = .distantPast
                    row.isPreset = true
                    row.enabled = false
                    row.isUploadedToNS = false
                    row.orderPosition = preset.order
                    row.duration = preset.duration.map(NSDecimalNumber.init(decimal:))
                    row.target = preset.target.map(NSDecimalNumber.init(decimal:))
                    row.halfBasalTarget = preset.halfBasalTarget.map(NSDecimalNumber.init(decimal:))
                }

                for preset in source.meals {
                    let row = MealPresetStored(context: context)
                    row.dish = preset.dish
                    row.carbs = preset.carbs.map(NSDecimalNumber.init(decimal:))
                    row.fat = preset.fat.map(NSDecimalNumber.init(decimal:))
                    row.protein = preset.protein.map(NSDecimalNumber.init(decimal:))
                }
                if context.hasChanges { try context.save() }
            } catch {
                // A failed save must not leave pending template mutations in
                // the context used for recovery or a later retry.
                context.rollback()
                throw error
            }
        }
    }
}

/// Thread-safe observer suppression and an exclusive restore lease. No pump
/// driver safety is inferred from this software coordination primitive.
final class TrioBackupOperationGate: @unchecked Sendable {
    static let shared = TrioBackupOperationGate()
    private let lock = NSLock()
    private var restoring = false
    private var operations = 0
    private let needsRecovery: () -> Bool
    init(needsRecovery: @escaping () -> Bool = { TrioCloudSettingsRestore.requiresPumpReconciliation }) {
        self.needsRecovery = needsRecovery
    }

    var isRestoring: Bool { lock.withLock { restoring } }
    func beginRestore() -> Bool {
        lock.withLock {
            guard !restoring, operations == 0 else { return false }
            restoring = true
            return true
        }
    }

    func endRestore() { lock.withLock { restoring = false } }
    func beginOperation(allowRecovery: Bool = false) -> Bool {
        lock.withLock {
            guard !restoring, allowRecovery || !needsRecovery() else { return false }
            operations += 1
            return true
        }
    }

    func endOperation() {
        lock.withLock {
            precondition(operations > 0)
            operations -= 1
        }
    }
}

#if canImport(UIKit)
    /// Commands under the exclusive lease bypass ordinary pump entry points intentionally.
    @MainActor private final class ConnectedRestorePump: TrioCloudSettingsRestore.RestorePump {
        let pump: PumpManagerUI
        let deviceManager: DeviceDataManager
        private var requiresSuspended = false
        init(pump: PumpManagerUI, deviceManager: DeviceDataManager) {
            self.pump = pump
            self.deviceManager = deviceManager
        }

        func checkReady() throws {
            guard let current = deviceManager.pumpManager, current === pump,
                  pump.isOnboarded, !pump.status.deliveryIsUncertain,
                  case .noBolus = pump.status.bolusState else { throw BackupError.pumpNotReady }
            if requiresSuspended {
                guard case .suspended = pump.status.basalDeliveryState else { throw BackupError.pumpNotReady }
            }
            switch pump.status.basalDeliveryState {
            case .active,
                 .suspended,
                 .tempBasal: break
            default: throw BackupError.pumpNotReady
            }
        }

        func refresh() async throws {
            let sync: Date? = await withCheckedContinuation { continuation in
                pump.ensureCurrentPumpData { continuation.resume(returning: $0) }
            }
            // Some drivers return nil when their cached data is already current.
            guard let lastSync = sync ?? pump.lastSync,
                  abs(lastSync.timeIntervalSinceNow) < 60 else { throw BackupError.pumpNotReady }
            try checkReady()
        }

        func suspendAndVerify() async throws {
            requiresSuspended = false
            try await refresh()
            if case .suspended = pump.status.basalDeliveryState { requiresSuspended = true
                return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pump.suspendDelivery { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            requiresSuspended = true
            try await verifySuspended()
        }

        func verifySuspended() async throws {
            try await refresh()
            guard case .suspended = pump.status.basalDeliveryState else { throw BackupError.pumpNotReady }
        }

        static func validate(_ value: TrioSettingsBackup.Configuration, pump: PumpManagerUI) throws {
            guard value.basalProfile.count <= pump.maximumBasalScheduleEntryCount
            else { throw BackupError.incompatiblePumpSettings }
            let rates = value.basalProfile.map { Double($0.rate) }
            guard rates.allSatisfy({ rate in pump.supportedBasalRates.contains { abs($0 - rate) < 0.000001 } }),
                  pump.supportedMaximumBolusVolumes.contains(where: { abs($0 - Double(value.pumpSettings.maxBolus)) < 0.000001 })
            else {
                throw BackupError.incompatiblePumpSettings
            }
            let offsets = value.basalProfile.map { TimeInterval($0.minutes * 60) } + [86400]
            guard zip(offsets, offsets.dropFirst()).allSatisfy({ $1 - $0 >= pump.minimumBasalScheduleEntryDuration }) else {
                throw BackupError.incompatiblePumpSettings
            }
        }

        func synchronize(_ value: TrioSettingsBackup.Configuration) async throws {
            try await verifySuspended()
            let items = value.basalProfile.map {
                RepeatingScheduleValue(
                    startTime: TimeInterval($0.minutes * 60),
                    value: Double($0.rate)
                )
            }
            let schedule: BasalRateSchedule = try await withCheckedThrowingContinuation { continuation in
                if let omnipod = pump as? OmniPumpManager {
                    omnipod.syncBasalRateScheduleWhileSuspended(items: items) { continuation.resume(with: $0) }
                } else {
                    pump.syncBasalRateSchedule(items: items) { continuation.resume(with: $0) }
                }
            }
            guard schedule.items.count == items.count, zip(schedule.items, items).allSatisfy({
                abs($0.startTime - $1.startTime) < 0.000001 && abs($0.value - $1.value) < 0.000001
            }) else { throw BackupError.incompatiblePumpSettings }
            let requested = DeliveryLimits(
                maximumBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(value.pumpSettings.maxBasal)),
                maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: Double(value.pumpSettings.maxBolus))
            )
            let actual: DeliveryLimits = try await withCheckedThrowingContinuation { continuation in
                pump.syncDeliveryLimits(limits: requested) { continuation.resume(with: $0) }
            }
            guard actual.maximumBasalRate == requested.maximumBasalRate,
                  actual.maximumBolus == requested.maximumBolus else { throw BackupError.incompatiblePumpSettings }
            try await verifySuspended()
        }
    }
#endif
