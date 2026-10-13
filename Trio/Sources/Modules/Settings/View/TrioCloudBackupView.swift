import SwiftUI
import UniformTypeIdentifiers

struct TrioCloudBackupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var busy = false
    @State private var naming = false
    @State private var name = ""
    @State private var message: String?
    @State private var createdName: String?
    @State private var importing = false
    @State private var imported: TrioSettingsBackup?
    @State private var exported: ExportedBackup?
    @State private var lastBackup: Date?

    private struct ExportedBackup: Identifiable { let id = UUID()
        let url: URL }

    var body: some View {
        List {
            Section {
                Button("Back Up Now") { name = ""
                    naming = true }.disabled(busy)
            } header: { Text("iCloud Backup") } footer: {
                Text(
                    lastBackup
                        .map { "Last successful backup: \($0.formatted(date: .abbreviated, time: .shortened))" } ??
                        "No successful iCloud backup yet."
                )
            }.listRowBackground(Color.chart)
            Section {
                NavigationLink("Recent Backups") { TrioCloudBackupBrowser() }
            }.listRowBackground(Color.chart)
            Section {
                NavigationLink("Configuration") { TrioCloudBackupConfigurationView() }
            }.listRowBackground(Color.chart)
            Section("Manual Backup") {
                Button("Export Backup File") {
                    Task { await perform {
                        exported = ExportedBackup(url: try await TrioCloudBackupCoordinator.shared.exportBackupFile())
                    } }
                }.disabled(busy)
                Button("Import Backup File") { importing = true }.disabled(busy)
            }.listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { lastBackup = TrioCloudBackupCoordinator.shared.lastSuccessfulBackupDate }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: TrioCloudBackupCoordinator.uploadNotification)) { _ in
            lastBackup = TrioCloudBackupCoordinator.shared.lastSuccessfulBackupDate
        }
        .alert("Name Your Backup", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create Backup") {
                let requestedName = name
                Task { await perform {
                    let entry = try await TrioCloudBackupCoordinator.shared.createManualBackup(name: requestedName)
                    createdName = entry.name ?? TrioSettingsBackup.normalizedName(requestedName)
                    name = ""
                } }
            }
            .disabled(TrioSettingsBackup.normalizedName(name) == nil)
        }
        .alert("Success!", isPresented: Binding(get: { createdName != nil }, set: { if !$0 { createdName = nil } })) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Your \"\(createdName ?? "")\" backup has been saved to iCloud.")
        }
        .alert("Backup & Restore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .sheet(item: $exported) { file in
            ShareSheet(activityItems: [file.url])
        }
        .sheet(isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } })) {
            if let imported {
                NavigationStack {
                    TrioCloudBackupDetailView(
                        entry: imported.entry, snapshot: imported, onSelectForOnboarding: nil
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                imported = try TrioSettingsBackup.decode(TrioSettingsBackup.readBackupData(from: url))
            } catch { message = error.localizedDescription }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false
            lastBackup = TrioCloudBackupCoordinator.shared.lastSuccessfulBackupDate }
        do { try await operation() } catch { message = error.localizedDescription }
    }
}

private struct TrioCloudBackupConfigurationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var automatic = true
    @State private var manualRetention = 15
    @State private var automaticRetention = 15
    @State private var updatingRetention = false
    @State private var pending = 0
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Toggle("Automatic iCloud Backup", isOn: $automatic)
                    .onChange(of: automatic) { _, value in TrioCloudBackupCoordinator.shared.automaticEnabled = value }
            } footer: {
                Text(
                    "Changed settings are backed up after five minutes, or within fifteen minutes if you keep editing. Backups wait until iCloud is available."
                )
            }.listRowBackground(Color.chart)
            Section {
                retentionPicker("Manual", selection: $manualRetention, origin: .manual)
                retentionPicker("Automatic", selection: $automaticRetention, origin: .automatic)
            } header: {
                Text("Backup Retention")
            } footer: {
                Text(
                    "Choose the maximum number of backups to keep in iCloud. When this limit is exceeded, Trio will automatically delete the oldest backups to make room for new ones."
                )
            }.listRowBackground(Color.chart)
            if pending > 0 { Text("\(pending) backup operation(s) pending.").listRowBackground(Color.chart) }
            if let error { Text(error).foregroundStyle(.secondary).listRowBackground(Color.chart) }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let coordinator = TrioCloudBackupCoordinator.shared
            automatic = coordinator.automaticEnabled
            manualRetention = coordinator.retentionLimit(for: .manual)
            automaticRetention = coordinator.retentionLimit(for: .automatic)
            do { pending = try coordinator.pendingOperationCount() }
            catch { self.error = error.localizedDescription }
            if error == nil {
                error = coordinator.lastRetentionError
                    .map { _ in "Some older backups couldn’t be removed. Trio will retry when you reopen the app." }
                    ?? coordinator.lastError?.localizedDescription
            }
        }
    }

    private func retentionPicker(_ title: String, selection: Binding<Int>, origin: TrioSettingsBackup.Origin) -> some View {
        Picker(title, selection: selection) {
            ForEach(TrioCloudBackupCoordinator.retentionChoices, id: \.self) { count in Text("\(count)").tag(count) }
        }
        .pickerStyle(.menu)
        .disabled(updatingRetention)
        .onChange(of: selection.wrappedValue) { _, limit in
            let coordinator = TrioCloudBackupCoordinator.shared
            guard coordinator.retentionLimit(for: origin) != limit else { return }
            updatingRetention = true
            Task { @MainActor in
                defer { updatingRetention = false }
                do {
                    try await coordinator.setRetentionLimit(limit, for: origin)
                    error = nil
                } catch {
                    selection.wrappedValue = coordinator.retentionLimit(for: origin)
                    self.error = coordinator.retentionLimit(for: origin) == limit && coordinator.lastRetentionError != nil
                        ? "Your limit is saved. Older backups will be removed when iCloud is available."
                        : error.localizedDescription
                }
            }
        }
    }
}

/// Both entry points present a separate, read-only backup settings tree.
struct TrioCloudBackupBrowser: View {
    var onSelectForOnboarding: ((TrioSettingsBackup) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var backups: [TrioCloudBackupEntry] = []
    @State private var error: String?
    @State private var loading = false
    @State private var modifying = false
    @State private var selected: TrioCloudBackupEntry?
    @State private var deleting: TrioCloudBackupEntry?
    @State private var renaming: TrioCloudBackupEntry?
    @State private var renameName = ""
    private var busy: Bool { loading || modifying }
    private var canManage: Bool { onSelectForOnboarding == nil }

    var body: some View {
        Group {
            if !canManage {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Choose a backup to restore.").font(.headline)
                        Spacer()
                        refreshButton
                    }
                    status
                    ForEach(TrioSettingsBackup.Origin.allCases, id: \.self) { origin in
                        let entries = backups.filter { $0.origin == origin }
                        if !entries.isEmpty {
                            Text(sectionTitle(origin)).font(.headline).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(entries) { entry in
                                    backupRow(entry).padding()
                                    if entry.id != entries.last?.id { Divider().padding(.horizontal) }
                                }
                            }
                            .background(Color.chart.opacity(0.65))
                            .cornerRadius(10)
                        }
                    }
                }
            } else {
                List {
                    status
                    ForEach(TrioSettingsBackup.Origin.allCases, id: \.self) { origin in
                        Section(sectionTitle(origin)) {
                            let entries = backups.filter { $0.origin == origin }
                            ForEach(entries) { entry in
                                backupRow(entry)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { managementActions(entry) }
                                    .contextMenu { managementActions(entry, inContextMenu: true) }
                            }
                            if entries.isEmpty && !loading { Text("No backups found").foregroundStyle(.secondary) }
                        }.listRowBackground(Color.chart)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("Recent Backups")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { refreshButton } }
            }
        }
        .task { await refresh() }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: TrioCloudBackupCoordinator.changesNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: TrioCloudBackupCoordinator.uploadNotification)) { _ in
            Task { await refresh() }
        }
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { entry in
            NavigationStack {
                TrioCloudBackupDetailView(
                    entry: entry, onSelectForOnboarding: onSelectForOnboarding,
                    onDelete: canManage ? { backups.removeAll { $0.id == entry.id } } : nil
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .alert("Delete Backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let entry = deleting else { return }
                deleting = nil
                Task { await delete(entry) }
            }
        } message: { Text("This removes the backup from iCloud.") }
        .alert("Rename Backup", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                guard let entry = renaming else { return }
                let requestedName = renameName
                renaming = nil
                Task { await rename(entry, name: requestedName) }
            }
            .disabled(TrioSettingsBackup.normalizedName(renameName) == nil)
        }
    }

    private func sectionTitle(_ origin: TrioSettingsBackup.Origin) -> String {
        origin == .manual ? String(localized: "Manual Backups") : String(localized: "Automatic Backups")
    }

    private func backupRow(_ entry: TrioCloudBackupEntry) -> some View {
        Button { selected = entry } label: {
            HStack {
                TrioCloudBackupRow(entry: entry)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    @ViewBuilder private func managementActions(_ entry: TrioCloudBackupEntry, inContextMenu: Bool = false) -> some View {
        Button(role: .destructive) { deleting = entry } label: {
            Label {
                Text("Delete")
            } icon: {
                Image(systemName: "trash")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(inContextMenu ? Color.red : Color.white)
            }
        }
        .tint(.red)
        .disabled(busy)
        if entry.origin == .manual && entry.validationMessage == nil {
            Button { renameName = entry.name ?? ""
                renaming = entry } label: { Label("Rename", systemImage: "pencil") }
                .tint(.accentColor)
                .disabled(busy)
        }
    }

    private var refreshButton: some View {
        Button { Task { await refresh() } } label: {
            Group {
                if loading { ProgressView().tint(.primary) }
                else { Image(systemName: "arrow.clockwise").foregroundStyle(.primary) }
            }
            .frame(width: 24, height: 24)
        }
        .tint(.primary)
        .accessibilityLabel("Refresh backups")
        .disabled(busy)
    }

    @ViewBuilder private var status: some View {
        if let error { Text(error).foregroundStyle(.secondary).listRowBackground(Color.chart) }
        if !canManage && backups.isEmpty && !busy && error == nil {
            Text("No backups found").foregroundStyle(.secondary)
        }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        loading = true
        defer { loading = false }
        do { backups = try await TrioCloudBackupCoordinator.shared.listBackups()
            error = nil } catch { self.error = error.localizedDescription }
    }

    @MainActor private func delete(_ entry: TrioCloudBackupEntry) async {
        guard !busy else { return }
        modifying = true
        defer { modifying = false }
        do {
            try await TrioCloudBackupCoordinator.shared.deleteBackup(id: entry.id)
            backups.removeAll { $0.id == entry.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func rename(_ entry: TrioCloudBackupEntry, name: String) async {
        guard !busy else { return }
        modifying = true
        defer { modifying = false }
        do {
            let updated = try await TrioCloudBackupCoordinator.shared.renameBackup(id: entry.id, name: name)
            if let index = backups.firstIndex(where: { $0.id == entry.id }) { backups[index] = updated }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private extension TrioSettingsBackup {
    var entry: TrioCloudBackupEntry {
        .init(id: id.uuidString, createdAt: createdAt, origin: origin, name: name, fingerprint: fingerprint)
    }
}

private struct TrioCloudBackupDetailView: View {
    let entry: TrioCloudBackupEntry
    let onSelectForOnboarding: ((TrioSettingsBackup) -> Void)?
    let onDelete: (() -> Void)?
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var backup: TrioSettingsBackup?
    @State private var loading = true
    @State private var message: String?
    @State private var showingRestoreConfirmation = false
    @State private var restoring = false
    @State private var restored = false
    @State private var deleting = false
    @State private var showingDeleteConfirmation = false
    private var busy: Bool { restoring || deleting }

    init(
        entry: TrioCloudBackupEntry,
        snapshot: TrioSettingsBackup? = nil,
        onSelectForOnboarding: ((TrioSettingsBackup) -> Void)?,
        onDelete: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.onSelectForOnboarding = onSelectForOnboarding
        self.onDelete = onDelete
        _backup = State(initialValue: snapshot)
    }

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: entry.name ?? (entry.origin == .manual ? "Manual Backup" : "Automatic Backup"))
                LabeledContent("Created", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("App Version", value: backup?.appVersion ?? entry.appVersion ?? "—")
            }.listRowBackground(Color.chart)
            if let backup {
                let nodes = BackupSettingsNode.make(from: backup)
                Section("Settings") {
                    ForEach(nodes.filter { !["Services", "Adjustments"].contains($0.title) }) { node in
                        NavigationLink { BackupSettingsTreeView(node: node) } label: { Text(LocalizedStringKey(node.title)) }
                    }
                }.listRowBackground(Color.chart)
                ForEach(nodes.filter { ["Services", "Adjustments"].contains($0.title) }) { node in
                    Section {
                        NavigationLink { BackupSettingsTreeView(node: node) } label: { Text(LocalizedStringKey(node.title)) }
                    }.listRowBackground(Color.chart)
                }
                Section {
                    VStack {
                        restoreButton
                        if onDelete != nil { deleteButton }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }.listRowBackground(Color.clear)
            } else {
                Section {
                    if loading { ProgressView("Loading backup…") }
                    else { Text("This backup couldn’t be opened.").foregroundStyle(.secondary) }
                }.listRowBackground(Color.chart)
            }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Backup Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .tint(.primary).accessibilityLabel("Close backup details").disabled(busy)
            }
        }
        .task {
            defer { loading = false }
            do {
                if backup == nil { backup = try await TrioCloudBackupCoordinator.shared.downloadBackup(id: entry.id) }
            } catch { message = error.localizedDescription }
        }
        .alert("Backup & Restore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Done", role: .cancel) {}
        } message: { Text(message ?? "") }
        .alert("Settings Restored!", isPresented: $restored) {
            Button("Continue") { dismiss() }
        } message: {
            Text(
                "Trio is in Open Loop and connected pump delivery is suspended. Review your settings before resuming delivery. Pump suspension limits still apply."
                    +
                    (
                        TrioCloudBackupCoordinator.shared.restoreConnectionMessages
                            .isEmpty ? "" : "\n\n" + TrioCloudBackupCoordinator.shared.restoreConnectionMessages
                            .joined(separator: "\n")
                    )
            )
        }
        .overlay {
            if busy {
                ZStack {
                    appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()
                    ProgressView(restoring ? "Restoring settings… Keep Trio open." : "Deleting backup…")
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var restoreButton: some View {
        Button {
            guard let backup else { return }
            if let onSelectForOnboarding {
                onSelectForOnboarding(backup)
                dismiss()
            } else {
                showingRestoreConfirmation = true
            }
        } label: {
            actionLabel(
                onSelectForOnboarding == nil ? "Restore Settings" : "Select Backup",
                systemImage: "icloud.and.arrow.down",
                color: .accentColor
            )
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.accentColor)
        .disabled(backup == nil || busy)
        // Attach the confirmation to its source button so iPad popovers anchor correctly.
        .confirmationDialog("Restore Settings?", isPresented: $showingRestoreConfirmation, titleVisibility: .visible) {
            Button("Restore Settings", role: .destructive) {
                Task { await restore() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This replaces your settings, switches Trio to Open Loop, and suspends pump delivery. You’ll need to review the settings and resume delivery afterward."
            )
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            actionLabel("Delete Backup", systemImage: "trash", color: .red)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.red)
        .confirmationDialog("Delete Backup?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Backup", role: .destructive) {
                Task { @MainActor in
                    guard !busy else { return }
                    deleting = true
                    defer { deleting = false }
                    do {
                        try await TrioCloudBackupCoordinator.shared.deleteBackup(id: entry.id)
                        onDelete?()
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the backup from iCloud.") }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(title).multilineTextAlignment(.center)
            Spacer(minLength: 0)
            // Reserve matching space so the title stays centered independently of the leading icon.
            Image(systemName: systemImage).hidden().accessibilityHidden(true)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .bold()
    }

    @MainActor private func restore() async {
        guard let backup, !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            try await TrioCloudBackupCoordinator.shared.restoreConfiguredApp(backup)
            restored = true
        } catch {
            message = "Restore stopped. Check pump delivery before continuing.\n\n" + error.localizedDescription
        }
    }
}

private struct TrioCloudBackupRow: View {
    let entry: TrioCloudBackupEntry
    private var title: String { entry.name ?? (entry.origin == .manual ? "Manual Backup" : "Automatic Backup") }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.primary)
            if let warning = entry.validationMessage {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(entry.createdAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
