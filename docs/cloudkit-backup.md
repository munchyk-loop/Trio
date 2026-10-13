# CloudKit settings backup

See [CloudKit Backup Deployment](CloudKit-Backup-Deployment.md) for the current schema, restore behavior, Dynamic ISF history rules, and Apple Developer setup.

## Code map

- `Trio/Sources/Services/SettingsManager/CloudSettingsBackup.swift`: schema-4 snapshots, integrity checks, typed configuration, preset DTOs, timestamped TDD history, and private CloudKit operations.
- `Trio/Sources/Services/SettingsManager/TrioCloudBackupCoordinator.swift`: change-triggered backup, debounce, deduplication, durable uploads, manual backups, JSON export, and restore entry points.
- `Trio/Sources/Services/SettingsManager/TrioCloudSettingsRestore.swift`: exclusive restore interlock, suspension verification, rollback journal, preset replacement, history import, and startup recovery.
- `Trio/Sources/Modules/Settings/View/TrioCloudBackupView.swift`: backup settings, native recent-backup navigation, configuration, import/export, detail preview, and restore confirmation.
- `Trio/Sources/Modules/Onboarding/View/OnboardingRootView.swift`: iCloud restore selection, section progress, completion overviews, and onboarding routing.
- `Trio/Sources/APS/Storage/TDDStorage.swift`: the shared Dynamic ISF history sufficiency gate.
- `Trio/Resources/Trio.entitlements`: CloudKit container entitlement.
- `TrioTests/CloudSettingsBackupTests.swift`: snapshot, restore, integrity, history, and recovery tests.

## Local development

Open `Trio.xcworkspace` to include the device-driver dependencies. Use the **Trio** scheme to run the app and **Trio Tests** to run tests. The `.github/workflows/cloudkit-validation.yml` workflow can also be dispatched manually.

Configured-app restore supports an existing pump connection, switches to Open Loop, and verifies suspension before replacing settings. It never resumes delivery automatically. Portable JSON excludes pairing, credentials, and live treatment state; CloudKit connection payloads are separate. Device and pump behavior still require user evaluation.

Service account payloads live in `TrioCloudConnections.swift` and the encrypted CloudKit envelope. Portable JSON contains no account credentials. Device migration and certificates are excluded. Existing pump/CGM connections are retained, and configured-app restore keeps its suspension and recovery protections. See [service account details](CloudKit-Backup-Deployment.md#service-account-connections).
