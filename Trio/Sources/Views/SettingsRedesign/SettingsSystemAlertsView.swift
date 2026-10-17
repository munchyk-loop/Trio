import Combine
import Foundation
import LoopKit
import SwiftUI

struct SettingsSystemAlertPreferences: Codable, Equatable {
    static let key = "trio.systemAlertPreferences.v2"
    var algorithm = true
    var pump = true
    var cgm = true
    var urgentDelivery: SettingsAlertDelivery?
    var standardDelivery: SettingsAlertDelivery?

    static var current: Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func allows(_ entry: LoopKit.Alert.CatalogEntry) -> Bool {
        guard entry.interruptionLevel != .critical else { return true }
        let manager = entry.identifier.managerIdentifier.lowercased()
        if manager.contains("trio") || entry.category == "Algorithm" { return algorithm }
        if manager.contains("libre") || manager.contains("cgm") || manager.contains("dexcom") ||
            manager.contains("sensor") { return cgm }
        return pump
    }

    func apply(to alert: LoopKit.Alert, entry: LoopKit.Alert.CatalogEntry) -> LoopKit.Alert {
        guard let delivery = entry.interruptionLevel == .critical ? urgentDelivery : standardDelivery else { return alert }
        var metadata = alert.metadata ?? [:]
        metadata["settings.delivery"] = .init(delivery.rawValue)
        return LoopKit.Alert(
            identifier: alert.identifier, foregroundContent: alert.foregroundContent,
            backgroundContent: alert.backgroundContent, trigger: alert.trigger,
            interruptionLevel: delivery == .timeSensitive && entry.interruptionLevel != .critical ? .timeSensitive : .critical,
            sound: alert.sound, metadata: metadata
        )
    }
}

struct SettingsSystemAlertsView: View {
    @State private var working = SettingsSystemAlertPreferences.current
    var body: some View {
        Form {
            Group {
                Section {
                    Text("For your safety, urgent System Alerts cannot be turned off.").foregroundStyle(.secondary)
                }
                Section("Urgent Alerts") {
                    Toggle("Algorithm", isOn: .constant(true)).disabled(true)
                    Toggle("Insulin Pump", isOn: .constant(true)).disabled(true)
                    Toggle("CGM", isOn: .constant(true)).disabled(true)
                    SettingsAlertDeliveryRow(selection: Binding(
                        get: { working.urgentDelivery ?? .alarm }, set: { working.urgentDelivery = $0 }
                    ), allowsTimeSensitive: false)
                }
                Section {
                    Toggle("Algorithm", isOn: $working.algorithm)
                    Toggle("Insulin Pump", isOn: $working.pump)
                    Toggle("CGM", isOn: $working.cgm)
                    SettingsAlertDeliveryRow(selection: Binding(
                        get: { working.standardDelivery ?? .timeSensitive }, set: { working.standardDelivery = $0 }
                    ))

                } header: { Text("Standard Alerts") } footer: {
                    SettingsHelpFooter(
                        title: "Standard Alerts",
                        text: "Standard alerts notify you about non-urgent system updates, status changes, and expiration reminders."
                    )
                }
            }.listRowBackground(Color.chart).tint(Color.tabBar)
        }
        .settingsBackground().tint(.white)
        .navigationTitle("System Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: working) { _, value in
            if let data = try? JSONEncoder()
                .encode(value) { UserDefaults.standard.set(data, forKey: SettingsSystemAlertPreferences.key) }
            if value.urgentDelivery == .alarm || value.standardDelivery == .alarm {
                Task { await CriticalAlertAlarmScheduler.requestAuthorization() }
            }
        }
    }
}

struct SettingsAlertDeliveryRow: View {
    @Binding var selection: SettingsAlertDelivery
    var allowsTimeSensitive = true

    var body: some View {
        NavigationLink {
            SettingsAlertDeliveryView(selection: $selection, allowsTimeSensitive: allowsTimeSensitive)
        } label: { LabeledContent("Delivery", value: selection.title) }
    }
}

struct SettingsAlertDeliveryView: View {
    @Binding var selection: SettingsAlertDelivery
    var allowsTimeSensitive = true

    var body: some View {
        Form {
            Section("Configuration") {
                ForEach(SettingsAlertDelivery.allCases.filter { allowsTimeSensitive || $0 != .timeSensitive }) { delivery in
                    Button { selection = delivery } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label { Text(delivery.title).lineLimit(1).minimumScaleFactor(0.8) } icon: {
                                    Image(systemName: delivery.symbol).foregroundStyle(delivery.iconColor)
                                }
                                .font(.headline)
                                Text(delivery.detail).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.tabBar)
                                .frame(width: 24)
                                .opacity(selection == delivery ? 1 : 0)
                                .accessibilityHidden(true)
                        }.padding(.vertical, 8)
                    }.foregroundStyle(Color.primary)
                }
            }.listRowBackground(Color.chart).tint(Color.tabBar)
        }
        .settingsBackground().tint(.white)
        .navigationTitle("Delivery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension SettingsAlertDelivery {
    var symbol: String {
        switch self {
        case .timeSensitive: return "clock.fill"
        case .critical: return "exclamationmark.triangle.fill"
        case .alarm: return "alarm.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .timeSensitive: return .yellow
        case .critical: return .red
        case .alarm: return .orange
        }
    }

    var detail: String {
        switch self {
        case .timeSensitive: return String(
                localized: "A momentary banner that appears on screen briefly. Prioritized at the top of Notification Center. Can override Focus, but cannot override Silent mode."
            )
        case .critical: return String(
                localized: "A persistent banner that remains on screen until dismissed. Creates a more noticeable interruption. Prioritized at the top of Notification Center. Can override Focus and Silent mode."
            )
        case .alarm: return String(localized: "A full-screen alarm that continues alerting until dismissed. Can override Focus and Silent mode.")
        }
    }
}
