# CloudKit backup and restore

The public-beta flow is implemented in Swift and SwiftUI. Settings → Backup & Restore opens a screen with Back Up Now, Recent Backups, Configuration, and JSON export/import. Export immediately opens the share sheet with a `TrioSettings_yyyyMMdd_HHmmss.json` file. Automatic backup settings live in Configuration; Recent Backups groups Manual Backups and Automatic Backups. Its white toolbar refresh icon becomes a spinner in place. Swipe or long-press a row to delete, or rename a manual backup. Manual backup creation requires a nonblank name; success includes the saved name. Configuration offers separate manual/automatic retention limits of 3, 5, 10, or 15, defaulting to 15 each. Configuration uses an inline title. Backup Details opens a separate card containing Info and a read-only settings hierarchy for Devices, Therapy, Algorithm, Features, Notifications, Services, and Adjustments. Preview navigation never opens the running app’s editable settings screens. The card includes restore and cloud-delete actions; JSON imports cannot delete a cloud record. Onboarding cards reuse Trio’s existing colors, fonts, and information-box treatment.

## What is included

Schema 4 includes Trio settings, algorithm preferences, basal/ISF/CR/target schedules, insulin action and delivery limits, saved override/temp-target/meal presets, alert settings, appearance, live-activity layout, and up to ten days of timestamped TDD summaries used by Dynamic ISF.

Portable JSON exports exclude credentials and device connections. Private CloudKit backups additionally include Nightscout credentials and activation flags, and a Tidepool OAuth session. Pump/CGM pairing, certificates, live delivery state, glucose data, raw pump events, running overrides/temp targets, remote-control secrets, snoozes, and permissions remain excluded. Existing destination service accounts and pump connections are preserved. Dynamic ISF preferences were already part of the complete preferences snapshot.

TDD history has its own checksum. It does not affect configuration fingerprints or trigger automatic backups. History is imported only from backups less than seven days old, with original timestamps and at most one imported summary per five-minute interval. If local history already meets Trio’s Dynamic ISF requirement, no backup history is imported. Otherwise existing local summaries take precedence while missing history is added. Old backups preserve local history. The existing gate counts positive TDD records in the last seven days and requires at least 1,512 (75% of 2,016 expected five-minute samples). A recent backup does not guarantee sufficient coverage. The gate does not require seven complete calendar days.

Schemas 2 and 3 remain readable. Original checksums are verified before schema-2 migration. Schema 4 adds JSON content inside the existing CloudKit payload; it introduces no CloudKit record fields or indexes.

## Restore behavior

Onboarding chapter 1 is Import Settings: choose iCloud restoration or start fresh. Choosing restoration opens the in-flow backup browser. Next applies the selected backup and shows Settings Restored! Continue shows the Algorithm Settings completion overview (section 4), with the first four progress bars filled; Next proceeds to permissions. Back from permissions returns through the section-4 completion overview to the iCloud Restore choice. Starting fresh also shows the chapter-1 completion overview before Therapy Settings. Every chapter completion overview participates in forward and backward navigation and retains the completed chapter’s title. The five progress bars fill according to the current screen and conditional substeps. Units & Pump is in Therapy Settings, chapter 2. The restored configuration is not overwritten by onboarding defaults.

Restoration is also available in configured apps, including with a paired pump. The user explicitly confirms Open Loop and pump suspension. Restoration is blocked during a bolus, uncertain/transitional pump status, incomplete pairing, conflicting pump operations, running overrides, or active temporary targets. The exclusive lease covers loops, determinations, dosing commands, pump refreshes, pump configuration writes, remote adjustments, and driver settings/setup UI.

Before replacing settings, Trio writes a rollback journal, persists Open Loop, refreshes the connected pump, suspends it, and verifies suspension. The restored basal schedule and delivery limits must match the values accepted by the driver. Incompatible insulin concentration or unsupported schedule/limits are rejected. Suspension is checked through the transaction and at completion. Restore never resumes delivery or enables automation. The confirmation/result messages explain separate resumption and pump-specific suspension time limits.

Omnipod’s ordinary basal-profile update starts delivery. The restore-specific driver method saves the next-resume schedule locally while the pod stays suspended; the existing explicit resume command programs that schedule. The feature pins a small OmnipodKit change in the user’s fork.

Failed restoration rolls back local settings and newly inserted TDD summaries, and attempts to restore previous pump settings while suspended. Interrupted paired-pump restoration leaves a persistent reconciliation requirement. At launch, local recovery runs before settings/device services initialize, then hardware reconciliation verifies suspension and restores the recovered pump settings. Dosing and driver controls remain blocked until reconciliation succeeds; protective bolus cancellation/suspension remain available. Pump controls provide a retry action. The selected backup never supplies pairing state or certificates.

## Backup retention and renaming

Limits are local backup preferences and apply independently to each backup origin. Cleanup deletes the oldest records with readable metadata after a confirmed upload, or after the user changes a limit. A newly created manual backup is protected during that cleanup. Unreadable records and records with a pending durable upload are not silently removed. Failed cleanup stays pending and retries on foreground/connectivity recovery; it does not turn a successful upload into a failed backup. Retention never deletes queued snapshots to make an upload fit.

Renaming a manual backup updates its encrypted name and payload together, retaining its UUID, creation date, configuration fingerprint, and dated Dynamic ISF history. CloudKit change tags reject concurrent edits. Explicit deletion removes a matching pending upload so it is not recreated later.

## Backup policy and integrity

There are no daily or periodic backups. Saved configuration and preset changes use a five-minute trailing debounce, capped at fifteen minutes of continuous editing. Identical configurations are deduplicated; explicit manual backups remain independent. Queued snapshots retain their UUID and are atomically persisted until iCloud becomes available.

Snapshots validate complete typed settings, schedules, limits, checksums, and CloudKit record identity. JSON/asset reads are bounded to 8 MiB before decoding. Configuration groups restore together. Journals include previous files, presets, allowlisted defaults, and identifiers of inserted TDD summaries. Completed restores retain the most recent local rollback in `.trio-cloud-rollback.json`; subsequent restores replace it atomically. Recovery preserves existing treatment/run relationships and forces Open Loop.

CloudKit uses the current user’s private database. Names, small snapshots and checksums use encrypted fields; larger payloads use CKAsset. Local queue/export/rollback files use complete file protection. Shared JSON exports are ordinary portable JSON. See [Apple’s encryption documentation](https://developer.apple.com/documentation/cloudkit/encrypting-user-data) for account protection behavior.

## Apple Developer and TestFlight setup

1. Enable iCloud with CloudKit on the exact App ID used by GitHub Actions. The default bundle identifier is `org.nightscout.<TEAM_ID>.trio`; its container is `iCloud.org.nightscout.<TEAM_ID>.trio`.
2. Assign that exact container to the App ID. Regenerate development/distribution provisioning profiles after changing capabilities. Verify the signed app and embedded profile use the same container.
3. Initialize `TrioSettingsBackup` in Development with `createdAt` (Date), `origin` (String), `appVersion` (String), `schemaVersion` (Int64), encrypted `snapshot` (Bytes), encrypted `fingerprint` (String), optional encrypted `name` (String), and `snapshotAsset` (Asset). Make the `recordName` index Queryable.
4. Deploy the schema to Production before TestFlight. TestFlight uses Production; development builds signed with development provisioning use Development. The environments have separate data.
5. Test with an iPhone signed into iCloud. Backups are scoped to the provisioned container and Apple account. Different bundle IDs do not share a container automatically.

If these capabilities, profiles, and Production schema are already configured, this update needs no additional portal/schema changes. The GitHub Actions validation workflow can build the app and run restore tests without distributing a build. Manual workflow dispatch remains available. Commit messages containing `[skip ci]` suppress push validation.

## Validation scope

Tests cover serialization/migration, strict inputs and bounded reads, offline/deduplicated queues, lease exclusion, verified suspension ordering, failure before therapy replacement, preset relationships, filesystem/Core Data failure, journal recovery at each persistence phase, history age/integrity/deduplication/rollback, pending hardware reconciliation, and the Omnipod suspension-preserving profile path.

Simulator and injected-driver tests establish software behavior; physical communication, pump-specific suspension timing, and actual iCloud account behavior still need device evaluation. This implementation task does not upload a TestFlight build.

## Service account connections

Private CloudKit backups include Nightscout’s URL, secret and activation flags, and a Tidepool OAuth session. Exported JSON remains free of credentials. Existing destination accounts are preserved. Tidepool validates the saved session and uses a new service/dataset identity; an expired or replaced session may require signing in again. Account failures are reported separately from successfully restored settings.

A versioned, checksummed envelope uses the existing encrypted snapshot/asset fields; no additional CloudKit schema deployment is needed. Existing settings-only backups remain readable. The protected offline queue retains service credentials, and account changes participate in automatic-backup deduplication.

Device migration is excluded. Pump/CGM pairing, certificates, pump communication state and recent dose-event migration are not captured or restored. Dynamic ISF history remains included under its existing seven-day rules. Restoring settings on an already configured pump retains the established Open Loop, verified suspension and recovery protections.

The existing OmnipodKit fork supplies only the suspension-preserving basal schedule method required for configured-app settings restoration. No device-migration SDK changes are included. Full app, account, and physical-pump evaluation remain separate from source/compiler validation.
