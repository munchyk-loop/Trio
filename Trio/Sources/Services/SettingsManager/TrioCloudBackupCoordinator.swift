import CloudKit
import Combine
import CoreData
import Foundation
import Network
import Swinject

/// A trailing five-minute debounce groups edits into one automatic backup.
/// Continuous editing cannot delay a backup more than fifteen minutes.
/// There is NO daily timer and unchanged snapshots are never uploaded.
@MainActor final class TrioCloudBackupCoordinator {
    static let shared = TrioCloudBackupCoordinator()
    static let uploadNotification = Notification.Name("trioCloudBackupUploaded")
    static let changesNotification = Notification.Name("trioCloudBackupsChanged")
    static let retentionChoices = [3, 5, 10, 15]

    private enum Keys {
        static let manualRetention = "trio.cloudBackup.manualRetention"
        static let automaticRetention = "trio.cloudBackup.automaticRetention"
        static let retentionPending = "trio.cloudBackup.retentionPending"
        static let enabled = "trio.cloudBackup.automaticEnabled"
        static let pendingFirst = "trio.cloudBackup.pendingFirst"
        static let pendingLast = "trio.cloudBackup.pendingLast"
        static let lastSuccessfulUploadAt = "trio.cloudBackup.lastSuccessfulUploadAt"
        static let lastBackedAt = "trio.cloudBackup.lastBackedAt"
        static let lastFingerprint = "trio.cloudBackup.lastFingerprint"
    }

    private let cloud: TrioCloudBackupStoring
    private let defaults: UserDefaults
    private let queueURL: URL
    private let onboardingInProgress: () -> Bool
    private let captureOverride: ((TrioSettingsBackup.Origin, String?) async throws -> TrioSettingsBackup)?
    private var timer: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var dataObserver: NSObjectProtocol?
    private var coreDataChanges: AnyCancellable?
    private var accountObserver: NSObjectProtocol?
    private var networkMonitor: NWPathMonitor?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppConfiguration: Data?
    private var revision = 0
    private var onboardingObserver: NSObjectProtocol?
    private var resolver: Resolver?
    private var storage: FileStorage?
    private var settingsManager: SettingsManager?
    private var deviceManager: DeviceDataManager?
    #if canImport(UIKit)
        private var broadcaster: Broadcaster?
    #endif
    private(set) var isUploading = false
    private(set) var lastError: Error?
    private(set) var lastRetentionError: Error?
    private(set) var restoreConnectionMessages: [String] = []

    init(
        cloud: TrioCloudBackupStoring = TrioCloudBackupStore(),
        defaults: UserDefaults = .standard,
        queueURL: URL? = nil,
        onboardingInProgress: @escaping () -> Bool = { OnboardingManager.shared.shouldShowOnboarding },
        capture: ((TrioSettingsBackup.Origin, String?) async throws -> TrioSettingsBackup)? = nil
    ) {
        self.cloud = cloud
        self.defaults = defaults
        self.queueURL = queueURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".trio-cloud-backup-queue.json")
        self.onboardingInProgress = onboardingInProgress
        captureOverride = capture
    }

    func loadQueue() throws -> [TrioSettingsBackup] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        // A corrupt queue is an error, never interpreted as an empty queue.
        let data = try Data(contentsOf: queueURL)
        if let payloads = try? JSONDecoder().decode([TrioCloudBackupPayload].self, from: data) {
            return try payloads.map { try $0.snapshot() }
        }
        return try JSONDecoder().decode([TrioSettingsBackup].self, from: data).map { try $0.validated() }
    }

    private func saveQueue(_ queue: [TrioSettingsBackup]) throws {
        try JSONEncoder().encode(queue.map(TrioCloudBackupPayload.init))
            .write(to: queueURL, options: [.atomic, .completeFileProtection])
    }

    private func snapshot(
        origin: TrioSettingsBackup.Origin,
        name: String? = nil,
        includeConnections: Bool = true
    ) async throws -> TrioSettingsBackup {
        if let captureOverride { return try await captureOverride(origin, name).validated() }
        guard let storage else { throw BackupError.incompleteConfiguration }
        var snapshot = try await TrioSettingsBackup.capture(storage: storage, origin: origin, name: name)
        if includeConnections { snapshot.cloudConnections = try captureConnections() }
        return snapshot
    }

    deinit {
        timer?.cancel()
        networkMonitor?.cancel()
        for token in [changeObserver, dataObserver, defaultsObserver, onboardingObserver, accountObserver] {
            if let token { Foundation.NotificationCenter.default.removeObserver(token) }
        }
    }

    private func appConfigurationData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(TrioSettingsBackup.AppConfiguration.capture(defaults: defaults))
    }

    private func recordSuccess(_ snapshot: TrioSettingsBackup) {
        defer { Foundation.NotificationCenter.default.post(name: Self.uploadNotification, object: nil) }
        defaults.set(Date(), forKey: Keys.lastSuccessfulUploadAt)
        let previous = defaults.object(forKey: Keys.lastBackedAt) as? Date ?? .distantPast
        guard snapshot.createdAt >= previous else { return }
        defaults.set(try? snapshot.cloudFingerprint(), forKey: Keys.lastFingerprint)
        defaults.set(snapshot.createdAt, forKey: Keys.lastBackedAt)
    }

    var lastSuccessfulBackupDate: Date? {
        defaults.object(forKey: Keys.lastSuccessfulUploadAt) as? Date ?? defaults.object(forKey: Keys.lastBackedAt) as? Date
    }

    func restoreConfiguredApp(_ backup: TrioSettingsBackup) async throws {
        guard let settingsManager, let deviceManager else { throw BackupError.restoreFailed }
        #if canImport(UIKit)
            defer {
                if let basal = storage?.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) {
                    broadcaster?.notify(BasalProfileObserver.self, on: .main) { $0.basalProfileDidChange(basal) }
                }
                let pumpSettings = settingsManager.pumpSettings
                broadcaster?.notify(PumpSettingsObserver.self, on: .main) { $0.pumpSettingsDidChange(pumpSettings) }
            }
        #endif
        try await TrioCloudSettingsRestore.applyConfigured(backup, settingsManager: settingsManager, deviceManager: deviceManager)
        await restoreConnections(backup.cloudConnections)
        markChanged()
    }

    func restoreDuringOnboarding(_ backup: TrioSettingsBackup) async throws {
        guard let settingsManager, let deviceManager else { throw BackupError.restoreFailed }
        try await TrioCloudSettingsRestore.applyDuringOnboarding(
            backup,
            settingsManager: settingsManager,
            deviceManager: deviceManager
        )
        await restoreConnections(backup.cloudConnections)
    }

    private func captureConnections() throws -> TrioCloudConnections? {
        guard let resolver, let keychain = resolver.resolve(Keychain.self), let settingsManager else { return nil }
        let urlResult: Result<String?, KeychainError> = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey)
        let secretResult: Result<String?, KeychainError> = keychain
            .getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
        let url = try urlResult.get()
        let secret = try secretResult.get()
        let nightscout = url.flatMap { url -> TrioCloudConnections.Nightscout? in
            guard let parsed = URL(string: url), parsed.host != nil else { return nil }
            return secret.map { TrioCloudConnections.Nightscout(
                url: url,
                secret: $0,
                uploadEnabled: settingsManager.settings.isUploadEnabled,
                downloadEnabled: settingsManager.settings.isDownloadEnabled
            ) }
        }
        let value = try TrioCloudConnections(
            nightscout: nightscout,
            tidepoolSession: resolver.resolve(TidepoolManager.self)?.backupSession()
        )
        try value.validate()
        return value.nightscout == nil && value.tidepoolSession == nil ? nil : value
    }

    private func restoreConnections(_ connections: TrioCloudConnections?) async {
        restoreConnectionMessages = []
        guard let connections, let resolver, let keychain = resolver.resolve(Keychain.self), let settingsManager else { return }
        if let nightscout = connections.nightscout {
            do {
                let hasURL = try keychain.hasValue(forKey: NightscoutConfig.Config.urlKey).get()
                let hasSecret = try keychain.hasValue(forKey: NightscoutConfig.Config.secretKey).get()
                if !hasURL, !hasSecret {
                    let savedSecret: Result<Void, KeychainError> = keychain
                        .setValue(nightscout.secret, forKey: NightscoutConfig.Config.secretKey)
                    try savedSecret.get()
                    do {
                        let savedURL: Result<Void, KeychainError> = keychain
                            .setValue(nightscout.url, forKey: NightscoutConfig.Config.urlKey)
                        try savedURL.get()
                    } catch {
                        _ = keychain.removeObject(forKey: NightscoutConfig.Config.secretKey)
                        throw error
                    }
                    var settings = settingsManager.settings
                    settings.isUploadEnabled = nightscout.uploadEnabled
                    settings.isDownloadEnabled = nightscout.downloadEnabled
                    settingsManager.settings = settings
                }
            } catch { restoreConnectionMessages.append("Nightscout could not be restored. Connect it in Services.") }
        }
        if let session = connections.tidepoolSession {
            do { _ = try await resolver.resolve(TidepoolManager.self)?.restoreBackupSession(session) }
            catch { restoreConnectionMessages.append("Sign in to Tidepool in Services to reconnect your account.") }
        }
    }

    func reconcilePendingPumpRestore() async throws {
        guard let settingsManager, let deviceManager else { throw BackupError.restoreFailed }
        try await TrioCloudSettingsRestore.reconcilePumpAfterRecovery(
            settingsManager: settingsManager,
            deviceManager: deviceManager
        )
    }

    var automaticEnabled: Bool {
        get { (defaults.object(forKey: Keys.enabled) as? Bool) ?? true }
        set {
            defaults.set(newValue, forKey: Keys.enabled)
            if newValue { schedulePendingIfNeeded() }
            else { timer?.cancel()
                timer = nil }
        }
    }

    func start(resolver: Resolver) {
        guard changeObserver == nil else { return }
        self.resolver = resolver
        storage = resolver.resolve(FileStorage.self)
        settingsManager = resolver.resolve(SettingsManager.self)
        deviceManager = resolver.resolve(DeviceDataManager.self)
        #if canImport(UIKit)
            broadcaster = resolver.resolve(Broadcaster.self)
        #endif

        changeObserver = Foundation.NotificationCenter.default.addObserver(
            forName: .trioBackupConfigurationChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.markChanged() }
        }

        // Core Data presets do not pass through FileStorage; watch only preset
        // entities. Both local context saves and persistent-history changes are
        // observed because some edits can happen in background contexts.
        dataObserver = Foundation.NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
        ) { [weak self] note in
            guard (note.object as? NSManagedObjectContext)?.transactionAuthor != "TrioCloudRestore" else { return }
            let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
            // Inspect on the posting context's queue; never send managed objects across actors.
            let changed = keys.contains { key in
                let objects = note.userInfo?[key] as? Set<NSManagedObject> ?? []
                return objects.contains { Self.isPresetEntity($0.entity.name) }
            }
            if changed { Task { @MainActor in self?.markChanged() } }
        }

        coreDataChanges = CoreDataStack.shared.backupEntityChangePublisher.sink { [weak self] objectIDs in
            if objectIDs.contains(where: { Self.isPresetEntity($0.entity.name) }) {
                Task { @MainActor in self?.markChanged() }
            }
        }

        onboardingObserver = Foundation.NotificationCenter.default.addObserver(
            forName: .onboardingCompleted, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.markChanged() }
        }

        lastAppConfiguration = try? appConfigurationData()
        defaultsObserver = Foundation.NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = try? self.appConfigurationData()
                if current != self.lastAppConfiguration {
                    self.lastAppConfiguration = current
                    self.markChanged()
                }
            }
        }
        accountObserver = Foundation.NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.defaults.removeObject(forKey: Keys.lastFingerprint)
                self.defaults.removeObject(forKey: Keys.lastBackedAt)
                self.defaults.removeObject(forKey: Keys.lastSuccessfulUploadAt)
                await self.runAutomaticBackup(capturePending: false)
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.runAutomaticBackup(capturePending: false) }
        }
        monitor.start(queue: DispatchQueue(label: "TrioCloudBackup.connectivity"))
        networkMonitor = monitor
        applicationDidBecomeActive()
    }

    nonisolated private static func isPresetEntity(_ name: String?) -> Bool {
        ["OverrideStored", "TempTargetStored", "MealPresetStored"].contains(name)
    }

    /// Called on every relevant edit; no snapshot is created until editing has
    /// gone quiet, or the maximum coalescing window is reached.
    func markChanged(at now: Date = Date()) {
        guard !onboardingInProgress(), !TrioCloudSettingsRestore.isRestoring else { return }
        revision += 1
        if defaults.object(forKey: Keys.pendingFirst) == nil {
            defaults.set(now, forKey: Keys.pendingFirst)
        }
        defaults.set(now, forKey: Keys.pendingLast)
        schedulePendingIfNeeded()
    }

    /// Process persisted changes after foregrounding. This also covers cases
    /// where iOS suspended the app before the debounce timer could fire.
    func applicationDidBecomeActive() {
        schedulePendingIfNeeded()
        Task { await reconcileSavedConfiguration() }
    }

    private func reconcileSavedConfiguration() async {
        guard !isUploading, !TrioCloudSettingsRestore.isRestoring, !onboardingInProgress() else { return }
        do {
            // Detect edits persisted immediately before process termination, before an observer ran.
            let snapshot = try await snapshot(origin: .automatic)
            let queue = try loadQueue()
            if defaults.object(forKey: Keys.pendingFirst) == nil,
               try snapshot
               .cloudFingerprint() != (queue.last?.cloudFingerprint() ?? defaults.string(forKey: Keys.lastFingerprint))
            {
                markChanged()
            }
            if !queue.isEmpty || defaults.bool(forKey: Keys.retentionPending) {
                await runAutomaticBackup(capturePending: false)
            }
        } catch { lastError = error }
    }

    private func schedulePendingIfNeeded() {
        timer?.cancel()
        timer = nil
        guard !isUploading, !TrioCloudSettingsRestore.isRestoring, automaticEnabled,
              !onboardingInProgress(),
              let first = defaults.object(forKey: Keys.pendingFirst) as? Date,
              let last = defaults.object(forKey: Keys.pendingLast) as? Date
        else { return }
        let deadline = Self.deadline(first: first, last: last)
        let wait = max(0, deadline.timeIntervalSinceNow)
        timer = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.timer = nil
            await self?.runAutomaticBackup()
        }
    }

    private func clearPending(unchangedSince attemptedAt: Date) {
        guard (defaults.object(forKey: Keys.pendingLast) as? Date) == attemptedAt else {
            schedulePendingIfNeeded()
            return
        }
        defaults.removeObject(forKey: Keys.pendingFirst)
        defaults.removeObject(forKey: Keys.pendingLast)
    }

    static func deadline(first: Date, last: Date) -> Date {
        min(last.addingTimeInterval(5 * 60), first.addingTimeInterval(15 * 60))
    }

    func runAutomaticBackup(capturePending: Bool = true) async {
        guard !isUploading, !TrioCloudSettingsRestore.isRestoring, !capturePending || automaticEnabled,
              !onboardingInProgress() else { return }
        isUploading = true
        let startRevision = revision
        var succeeded = false
        defer {
            isUploading = false
            // Validation failures must not create a tight retry loop on an overdue deadline.
            if succeeded || revision != startRevision { schedulePendingIfNeeded() }
        }
        do {
            // The operation lock excludes other local queue writers. Keep one
            // decoded queue, but persist every confirmed upload before continuing.
            var queue = try loadQueue()
            if capturePending, let attemptedAt = defaults.object(forKey: Keys.pendingLast) as? Date {
                let capturedRevision = revision
                let snapshot = try await snapshot(origin: .automatic)
                let first = defaults.object(forKey: Keys.pendingFirst) as? Date ?? attemptedAt
                let reachedMaximum = Date() >= first.addingTimeInterval(15 * 60)
                guard !TrioCloudSettingsRestore.isRestoring,
                      capturedRevision == revision || reachedMaximum else { return }
                let previous = try queue.last?.cloudFingerprint() ?? defaults.string(forKey: Keys.lastFingerprint)
                if try previous != snapshot.cloudFingerprint() {
                    queue.append(snapshot)
                    try saveQueue(queue) // UUID and payload survive ambiguous upload failure/termination.
                }
                if capturedRevision != revision {
                    // A captured maximum-window snapshot must not be postponed
                    // forever by continuous notifications. Keep subsequent edits
                    // pending in a fresh coalescing window.
                    defaults.set(Date(), forKey: Keys.pendingFirst)
                }
                clearPending(unchangedSince: attemptedAt)
            }
            while let snapshot = queue.first(where: { automaticEnabled || $0.origin == .manual }) {
                if snapshot.origin == .automatic, defaults.string(forKey: Keys.lastFingerprint) == nil {
                    // Reinstall/cache-reset deduplication. The snapshot is already
                    // durable, so an unavailable account never loses this edit.
                    let existing = try await cloud.list().first(where: { $0.validationMessage == nil })
                    if let existing, try await cloud.download(id: existing.id).cloudFingerprint() == snapshot.cloudFingerprint() {
                        recordSuccess(snapshot)
                        queue.removeAll { $0.id == snapshot.id }
                        try saveQueue(queue)
                        continue
                    }
                }
                _ = try await cloud.upload(snapshot)
                queue.removeAll { $0.id == snapshot.id }
                // Older offline snapshots must not replace a newer manual baseline.
                recordSuccess(snapshot)
                try saveQueue(queue)
                defaults.set(true, forKey: Keys.retentionPending)
            }
            await maintainRetentionIfNeeded()
            lastError = nil
            succeeded = true
        } catch {
            lastError = error
            // Durable snapshots and future edits remain queued. Retry on foreground,
            // connectivity/account recovery, or the next meaningful change; no daily timer.
        }
    }

    /// Manual backup operations share one exclusion and timer-rescheduling boundary.
    private func withBackupOperation<Value>(_ operation: () async throws -> Value) async throws -> Value {
        guard !isUploading, !TrioCloudSettingsRestore.isRestoring else { throw BackupError.operationInProgress }
        isUploading = true
        defer { isUploading = false
            schedulePendingIfNeeded() }
        return try await operation()
    }

    func createManualBackup(name: String?) async throws -> TrioCloudBackupEntry {
        guard let name = TrioSettingsBackup.normalizedName(name) else { throw BackupError.backupNameRequired }
        return try await withBackupOperation {
            let capturedRevision = revision
            let attemptedAt = defaults.object(forKey: Keys.pendingLast) as? Date
            let snapshot = try await snapshot(origin: .manual, name: name)
            guard capturedRevision == revision else { throw BackupError.operationInProgress }
            // Manual snapshots stay independent even if the fingerprint is identical.
            var queue = try loadQueue()
            queue.append(snapshot)
            try saveQueue(queue)
            let entry = try await cloud.upload(snapshot)
            queue.removeAll { $0.id == snapshot.id }
            try saveQueue(queue)
            recordSuccess(snapshot)
            if let attemptedAt { clearPending(unchangedSince: attemptedAt) }
            defaults.set(true, forKey: Keys.retentionPending)
            await maintainRetentionIfNeeded(protecting: [entry.id])
            return entry
        }
    }

    func exportBackupFile() async throws -> URL {
        try await withBackupOperation {
            let capturedRevision = revision
            let snapshot = try await snapshot(origin: .manual, includeConnections: false)
            guard capturedRevision == revision else { throw BackupError.operationInProgress }
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= TrioSettingsBackup.maximumSize else { throw BackupError.backupTooLarge }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TrioSettings_\(formatter.string(from: snapshot.createdAt)).json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }
    }

    func pendingOperationCount() throws -> Int {
        try loadQueue().count + (defaults.object(forKey: Keys.pendingFirst) == nil ? 0 : 1)
    }

    func listBackups() async throws -> [TrioCloudBackupEntry] {
        try await cloud.list()
    }

    func downloadBackup(id: String) async throws -> TrioSettingsBackup {
        try await cloud.download(id: id)
    }

    func deleteBackup(id: String) async throws {
        try await withBackupOperation {
            let queue = try loadQueue()
            try await cloud.delete(id: id)
            // An ambiguous prior upload must not recreate a backup the user deleted.
            try saveQueue(queue.filter { $0.id.uuidString != id })
            Foundation.NotificationCenter.default.post(name: Self.changesNotification, object: nil)
        }
    }

    func renameBackup(id: String, name: String) async throws -> TrioCloudBackupEntry {
        guard let name = TrioSettingsBackup.normalizedName(name) else { throw BackupError.backupNameRequired }
        return try await withBackupOperation {
            var queue = try loadQueue()
            let entry = try await cloud.rename(id: id, name: name)
            if let index = queue.firstIndex(where: { $0.id.uuidString == id }) {
                queue[index].name = name
                try saveQueue(queue)
            }
            Foundation.NotificationCenter.default.post(name: Self.changesNotification, object: nil)
            return entry
        }
    }

    func retentionLimit(for origin: TrioSettingsBackup.Origin) -> Int {
        let key = origin == .manual ? Keys.manualRetention : Keys.automaticRetention
        let value = defaults.integer(forKey: key)
        return Self.retentionChoices.contains(value) ? value : 15
    }

    func setRetentionLimit(_ limit: Int, for origin: TrioSettingsBackup.Origin) async throws {
        guard Self.retentionChoices.contains(limit) else { throw BackupError.invalidRetentionLimit }
        return try await withBackupOperation {
            defaults.set(limit, forKey: origin == .manual ? Keys.manualRetention : Keys.automaticRetention)
            defaults.set(true, forKey: Keys.retentionPending)
            await maintainRetentionIfNeeded()
            if let lastRetentionError { throw lastRetentionError }
        }
    }

    /// Pruning is maintenance after a confirmed upload, never a prerequisite for
    /// saving a replacement. Failed cleanup remains pending for a foreground retry.
    private func maintainRetentionIfNeeded(protecting protected: Set<String> = []) async {
        guard defaults.bool(forKey: Keys.retentionPending) else { return }
        do {
            let entries = try await cloud.list()
            let queued = Set(try loadQueue().map(\.id.uuidString))
            var deferred = false
            for origin in TrioSettingsBackup.Origin.allCases {
                let group = entries.filter { $0.origin == origin && $0.validationMessage == nil }
                    .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
                let protectedCount = group.filter { protected.contains($0.id) }.count
                let remaining = group.filter { !protected.contains($0.id) }
                let excess = remaining.dropFirst(max(0, retentionLimit(for: origin) - protectedCount))
                for entry in excess.reversed() {
                    if queued.contains(entry.id) { deferred = true
                        continue }
                    try await cloud.delete(id: entry.id)
                }
            }
            defaults.set(deferred, forKey: Keys.retentionPending)
            lastRetentionError = nil
            Foundation.NotificationCenter.default.post(name: Self.changesNotification, object: nil)
        } catch { lastRetentionError = error }
    }
}
