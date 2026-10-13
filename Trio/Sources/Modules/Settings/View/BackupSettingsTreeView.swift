import CoreFoundation
import Foundation
import SwiftUI

/// A read-only projection of the saved snapshot. It never resolves live settings
/// modules or exposes controls that could edit the running app configuration.
struct BackupSettingsNode: Identifiable {
    let id: String
    let title: String
    var value: String? = nil
    var children: [Self] = []
    var note: String? = nil

    static func make(from backup: TrioSettingsBackup) -> [Self] {
        var builder = Builder(configuration: backup.configuration)
        builder.addFields(backup.configuration.settings, source: "trioSettings")
        builder.addFields(backup.configuration.preferences, source: "preferences")
        builder.addFields(backup.configuration.pumpSettings, source: "pumpSettings")
        builder.addSchedules()
        builder.addEncoded(backup.configuration.presets.overrides, title: "Overrides", path: ["Adjustments"])
        builder.addEncoded(backup.configuration.presets.tempTargets, title: "Temporary Targets", path: ["Adjustments"])
        builder.addEncoded(
            backup.configuration.presets.meals,
            title: "Meal Presets",
            path: ["Features", "Treatments", "Meal Settings"]
        )
        if let app = backup.configuration.appConfiguration {
            builder.add(
                .init(id: "appearance", title: "Appearance", value: Self.format(app.appearance)),
                path: ["Features", "User Interface"]
            )
            if let order = app.liveActivityOrder {
                builder.addEncoded(order, title: "Display Order", path: ["Notifications", "Live Activity"])
            }
            builder.addEncoded(app.glucoseAlerts, title: "Glucose Alarms", path: ["Notifications"])
            builder.addEncoded(app.glucoseAlertConfiguration, title: "Day & Night Windows", path: ["Notifications"])
            builder.addEncoded(app.deviceAlertConfigurations, title: "Device Alarms", path: ["Notifications"])
        }
        builder.add(
            .init(
                id: "tdd-history",
                title: "Dynamic ISF History",
                value: backup.eligibleTDDHistory().isEmpty
                    ? String(localized: "Not included") : String(localized: "Included")
            ),
            path: ["Algorithm", "Dynamic Settings"]
        )
        if let connections = backup.cloudConnections {
            if let nightscout = connections.nightscout {
                builder.add(.init(
                    id: "nightscout-account",
                    title: "Account",
                    value: nightscout.url,
                    note: "Sign-in details are included securely. An account already configured on this phone will be kept."
                ), path: ["Services", "Nightscout"])
            }
            if let session = connections.tidepoolSession,
               let json = try? JSONSerialization.jsonObject(with: session) as? [String: Any]
            {
                builder.add(.init(
                    id: "tidepool-account",
                    title: "Account",
                    value: json["username"] as? String,
                    note: "A saved session is included. Tidepool may require signing in again if it has expired or been replaced."
                ), path: ["Services", "Tidepool"])
            }
        }
        return builder.roots
    }

    private struct Group { let path: [String]
        let keys: [String] }

    // Paths mirror the settings modules; labels reuse the existing export/UI names.
    private static let groups: [Group] = [
        Group(
            path: ["Therapy", "Units and Limits"],
            keys: [
                "trioSettings.dosingMode",
                "trioSettings.units",
                "preferences.maxIOB",
                "pumpSettings.maxBolus",
                "pumpSettings.maxBasal",
                "preferences.maxCOB",
                "preferences.threshold_setting",
                "trioSettings.insulinConcentration",
                "trioSettings.allowDilution"
            ]
        ),
        Group(path: ["Devices", "Continuous Glucose Monitor"], keys: ["trioSettings.smoothGlucose"]),
        Group(
            path: ["Algorithm", "Autosens"],
            keys: ["preferences.autosensMax", "preferences.autosensMin", "preferences.rewindResetsAutosens"]
        ),
        Group(
            path: ["Algorithm", "Super Micro Bolus (SMB)"],
            keys: [
                "preferences.enableSMBAlways",
                "preferences.enableSMBWithCOB",
                "preferences.enableSMBWithTemptarget",
                "preferences.enableSMBAfterCarbs",
                "preferences.enableSMB_high_bg",
                "preferences.allowSMBWithHighTemptarget",
                "preferences.enableUAM",
                "preferences.maxSMBBasalMinutes",
                "preferences.maxUAMSMBBasalMinutes",
                "preferences.maxDeltaBGthreshold",
                "preferences.enableSMB_high_bg_target"
            ]
        ),
        Group(
            path: ["Algorithm", "Dynamic Settings"],
            keys: [
                "preferences.adjustmentFactor",
                "preferences.adjustmentFactorSigmoid",
                "preferences.weightPercentage",
                "preferences.tddAdjBasal",
                "preferences.useNewFormula",
                "preferences.sigmoid",
                "preferences.useWeightedAverage"
            ]
        ),
        Group(
            path: ["Algorithm", "Target Behavior"],
            keys: [
                "preferences.highTemptargetRaisesSensitivity",
                "preferences.lowTemptargetLowersSensitivity",
                "preferences.sensitivityRaisesTarget",
                "preferences.resistanceLowersTarget",
                "preferences.halfBasalExerciseTarget",
                "preferences.advTargetAdjustments",
                "preferences.exerciseMode",
                "preferences.wideBGTargetRange"
            ]
        ),
        Group(
            path: ["Algorithm", "Additionals"],
            keys: [
                "preferences.maxDailySafetyMultiplier",
                "preferences.currentBasalSafetyMultiplier",
                "preferences.useCustomPeakTime",
                "pumpSettings.insulinActionCurve",
                "preferences.insulinPeakTime",
                "preferences.skipNeutralTemps",
                "preferences.unsuspendIfNoTemp",
                "preferences.suspendZerosIOB",
                "preferences.smbDeliveryRatio",
                "preferences.smbInterval",
                "preferences.remainingCarbsFraction",
                "preferences.remainingCarbsCap",
                "preferences.noisyCGMTargetMultiplier",
                "preferences.min5mCarbimpact",
                "preferences.curve",
                "preferences.updateInterval",
                "preferences.a52RiskEnable"
            ]
        ),
        Group(
            path: ["Features", "Treatments", "Bolus Calculator"],
            keys: [
                "trioSettings.displayPresets",
                "trioSettings.overrideFactor",
                "trioSettings.fattyMeals",
                "trioSettings.fattyMealFactor",
                "trioSettings.sweetMeals",
                "trioSettings.sweetMealFactor",
                "trioSettings.confirmBolus"
            ]
        ),
        Group(path: ["Features", "Treatments", "Quick-Pick Treatments"], keys: ["trioSettings.enableQuickPickTreatments"]),
        Group(
            path: ["Features", "Treatments", "Meal Settings"],
            keys: [
                "trioSettings.maxCarbs",
                "trioSettings.maxFat",
                "trioSettings.maxProtein",
                "preferences.maxMealAbsorptionTime",
                "trioSettings.useFPUconversion",
                "trioSettings.delay",
                "trioSettings.minuteInterval",
                "trioSettings.individualAdjustmentFactor"
            ]
        ),
        Group(path: ["Features", "Shortcuts"], keys: ["trioSettings.bolusShortcut"]),
        Group(
            path: ["Features", "User Interface"],
            keys: [
                "trioSettings.xGridLines",
                "trioSettings.yGridLines",
                "trioSettings.rulerMarks",
                "trioSettings.eA1cDisplayUnit",
                "trioSettings.showCarbsRequiredBadge",
                "trioSettings.carbsRequiredThreshold",
                "trioSettings.forecastDisplayType",
                "trioSettings.glucoseColorScheme",
                "trioSettings.timeInRangeType",
                "trioSettings.requireAdjustmentsConfirmation",
                "trioSettings.bolusDisplayThreshold",
                "trioSettings.low",
                "trioSettings.high",
                "trioSettings.homeStatsPanelFace",
                "trioSettings.showCobIobChart",
                "trioSettings.hideInsulinBadge"
            ]
        ),
        Group(path: ["Notifications", "Glucose Alarms"], keys: ["trioSettings.glucoseBadge", "preferences.carbsReqThreshold"]),
        Group(
            path: ["Notifications", "Live Activity"],
            keys: [
                "trioSettings.useLiveActivity",
                "trioSettings.lockScreenView",
                "trioSettings.displayGlucoseForecasts",
                "trioSettings.smartStackView"
            ]
        ),
        Group(path: ["Services", "Nightscout"], keys: ["trioSettings.uploadGlucose", "trioSettings.uploadCGMSensorStates"]),
        Group(path: ["Services", "Apple Health"], keys: ["trioSettings.useAppleHealth"]),
        Group(
            path: ["Notifications", "Calendar Events"],
            keys: ["trioSettings.useCalendar", "trioSettings.displayCalendarIOBandCOB", "trioSettings.displayCalendarEmojis"]
        ),
        Group(
            path: ["Devices", "Smart Watch"],
            keys: ["trioSettings.garminSettings", "trioSettings.confirmBolusFaster", "trioSettings.showForecastWatch"]
        ),
        Group(
            path: ["Devices", "Smart Watch", "Garmin"],
            keys: [
                "trioSettings.garminWatchface",
                "trioSettings.garminDatafield",
                "trioSettings.primaryAttributeChoice",
                "trioSettings.secondaryAttributeChoice",
                "trioSettings.isWatchfaceDataEnabled"
            ]
        ),
        Group(path: ["Features", "App Diagnostics"], keys: ["trioSettings.debugOptions"])
    ]
    private static let paths = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
        group.keys.map { ($0, group.path) }
    })
    private static let labels: [String: String] = [
        "dosingMode": "Dosing Mode",
        "smoothGlucose": "Smooth Glucose Value",
        "units": "Glucose Units",
        "maxIOB": "Maximum Insulin on Board (IOB)",
        "maxBolus": "Maximum Bolus",
        "maxBasal": "Maximum Basal Rate",
        "maxCOB": "Maximum Carbs on Board (COB)",
        "autosensMax": "Autosens Max",
        "autosensMin": "Autosens Min",
        "rewindResetsAutosens": "Rewind Resets Autosens",
        "enableSMBAlways": "Enable SMB Always",
        "enableSMBWithCOB": "Enable SMB With COB",
        "enableSMBWithTemptarget": "Enable SMB With Temptarget",
        "enableSMBAfterCarbs": "Enable SMB After Carbs",
        "enableSMB_high_bg": "Enable SMB With High Glucose",
        "allowSMBWithHighTemptarget": "Allow SMB With High Temptarget",
        "enableUAM": "Enable UAM",
        "maxSMBBasalMinutes": "Maximum SMB Basal Minutes",
        "maxUAMSMBBasalMinutes": "Maximum UAM SMB Basal Minutes",
        "maxDeltaBGthreshold": "Maximum Allowed Glucose Rise for SMB",
        "adjustmentFactor": "Adjustment Factor",
        "adjustmentFactorSigmoid": "Sigmoid Adjustment Factor",
        "weightPercentage": "Weight Percentage",
        "tddAdjBasal": "TDD Adjusts Basal",
        "highTemptargetRaisesSensitivity": "High Temporary Target Raises Sensitivity",
        "lowTemptargetLowersSensitivity": "Low Temporary Target Lowers Sensitivity",
        "sensitivityRaisesTarget": "Sensitivity Raises Target",
        "resistanceLowersTarget": "Resistance Lowers Target",
        "maxDailySafetyMultiplier": "Max Daily Safety Multiplier",
        "currentBasalSafetyMultiplier": "Current Basal Safety Multiplier",
        "useCustomPeakTime": "Use Custom Peak Time",
        "insulinActionCurve": "Duration of Insulin Action",
        "insulinPeakTime": "Insulin Peak Time",
        "skipNeutralTemps": "Skip Neutral Temps",
        "unsuspendIfNoTemp": "Unsuspend If No Temp",
        "suspendZerosIOB": "Suspend Zeros IOB",
        "smbDeliveryRatio": "SMB Delivery Ratio",
        "smbInterval": "SMB Interval",
        "remainingCarbsFraction": "Remaining Carbs Percentage",
        "remainingCarbsCap": "Remaining Carbs Cap",
        "noisyCGMTargetMultiplier": "Noisy CGM Target Increase",
        "displayPresets": "Display Meal Presets",
        "overrideFactor": "Recommended Bolus Percentage",
        "fattyMeals": "Enable Reduced Bolus Option",
        "fattyMealFactor": "Reduced Bolus Percentage",
        "sweetMeals": "Enable Super Bolus Option",
        "sweetMealFactor": "Super Bolus Percentage",
        "confirmBolus": "Very Low Glucose Warning",
        "enableQuickPickTreatments": "Enable Quick-Pick Treatments",
        "maxCarbs": "Max Carbs",
        "maxFat": "Max Fat",
        "maxProtein": "Max Protein",
        "maxMealAbsorptionTime": "Maximum Meal Absorption Time",
        "useFPUconversion": "Enable Fat and Protein Entries",
        "delay": "Fat and Protein Delay",
        "minuteInterval": "Spread Interval",
        "individualAdjustmentFactor": "Fat and Protein Percentage",
        "bolusShortcut": "Allow Bolusing with Shortcuts",
        "xGridLines": "Show X-Axis Grid Lines",
        "yGridLines": "Show Y-Axis Grid Lines",
        "rulerMarks": "Show Low and High Thresholds",
        "eA1cDisplayUnit": "eA1c/GMI Display Unit",
        "showCarbsRequiredBadge": "Show Carbs Required Badge",
        "carbsRequiredThreshold": "Carbs Required Threshold",
        "forecastDisplayType": "Forecast Display Type",
        "glucoseColorScheme": "Glucose Color Scheme",
        "timeInRangeType": "Time in Range Type",
        "requireAdjustmentsConfirmation": "Require Adjustments Confirmation",
        "glucoseBadge": "Show Glucose App Badge",
        "useLiveActivity": "Enable Live Activity",
        "lockScreenView": "Lock Screen Widget Style",
        "displayGlucoseForecasts": "Display Glucose Forecasts",
        "uploadGlucose": "Upload Glucose",
        "uploadCGMSensorStates": "Upload CGM Sensor States",
        "useAppleHealth": "Apple Health",
        "threshold_setting": "Minimum Safety Threshold",
        "enableSMB_high_bg_target": "High Glucose Target",
        "useNewFormula": "Dynamic ISF",
        "sigmoid": "Sigmoid Formula",
        "halfBasalExerciseTarget": "Half Basal Exercise Target",
        "min5mCarbimpact": "Minimum Carb Impact",
        "low": "Low Glucose",
        "high": "High Glucose",
        "smartStackView": "Smart Stack View",
        "curve": "Insulin Curve",
        "useWeightedAverage": "Use Weighted Average",
        "updateInterval": "Update Interval",
        "carbsReqThreshold": "Carbs Required Threshold",
        "advTargetAdjustments": "Advanced Target Adjustments",
        "exerciseMode": "Exercise Mode",
        "wideBGTargetRange": "Wide Glucose Target Range",
        "a52RiskEnable": "A52 Risk Enable",
        "insulinConcentration": "Insulin Concentration",
        "allowDilution": "Allow Dilution",
        "debugOptions": "Debug Options"
    ]
    private static let units: [String: String] = [
        "maxIOB": "U",
        "maxBolus": "U",
        "maxBasal": "U/hr",
        "maxCOB": "g",
        "autosensMax": "%",
        "autosensMin": "%",
        "maxSMBBasalMinutes": "minutes",
        "maxUAMSMBBasalMinutes": "minutes",
        "maxDeltaBGthreshold": "%",
        "weightPercentage": "%",
        "maxDailySafetyMultiplier": "%",
        "currentBasalSafetyMultiplier": "%",
        "insulinActionCurve": "hours",
        "insulinPeakTime": "minutes",
        "smbDeliveryRatio": "%",
        "smbInterval": "minutes",
        "remainingCarbsFraction": "%",
        "remainingCarbsCap": "g",
        "noisyCGMTargetMultiplier": "%",
        "overrideFactor": "%",
        "fattyMealFactor": "%",
        "sweetMealFactor": "%",
        "maxCarbs": "g",
        "maxFat": "g",
        "maxProtein": "g",
        "maxMealAbsorptionTime": "hours",
        "delay": "minutes",
        "minuteInterval": "minutes",
        "individualAdjustmentFactor": "%",
        "carbsRequiredThreshold": "g",
        "updateInterval": "minutes",
        "carbsReqThreshold": "g"
    ]
    private static let glucoseFields: Set<String> = [
        "threshold_setting",
        "enableSMB_high_bg_target",
        "halfBasalExerciseTarget",
        "min5mCarbimpact",
        "low",
        "high"
    ]
    private static let excludedFields: Set<String> = [
        "bolusIncrement",
        "cgm",
        "cgmPluginIdentifier",
        "isDownloadEnabled",
        "isUploadEnabled",
        "localGlucosePort",
        "timestamp",
        "useLocalGlucoseSource"
    ]

    private struct Builder {
        let configuration: TrioSettingsBackup.Configuration
        var roots: [BackupSettingsNode] = [
            .init(id: "devices", title: "Devices", note: "Pump and CGM pairing is not included. Existing connections are kept."),
            .init(id: "therapy", title: "Therapy"),
            .init(id: "algorithm", title: "Algorithm"),
            .init(id: "features", title: "Features"),
            .init(id: "notifications", title: "Notifications"),
            .init(
                id: "services",
                title: "Services",
                note: "Cloud backups can include Nightscout and Tidepool sign-in details. JSON files exclude them. Existing accounts are kept."
            ),
            .init(
                id: "adjustments",
                title: "Adjustments",
                note: "Saved presets are included. Running overrides and temporary targets are not restored."
            )
        ]

        mutating func addFields(_ value: Any, source: String) {
            for field in Mirror(reflecting: value).children {
                guard let key = field.label, !excludedFields.contains(key) else { continue }
                let identifier = source + "." + key
                let path = paths[identifier]
                    ?? (source == "preferences" ? ["Algorithm", "Additionals"] : ["Features", "User Interface"])
                var value = field.value
                var unit = units[key]
                if var decimal = value as? Decimal, type(of: value) == Decimal.self {
                    if unit == "%" { decimal *= 100 }
                    if glucoseFields.contains(key) {
                        if configuration.settings.units == .mmolL { decimal = decimal.asMmolL }
                        unit = configuration.settings.units.rawValue
                    }
                    value = decimal
                }
                let text = format(value) + (unit.map { " " + $0 } ?? "")
                add(.init(id: identifier, title: labels[key] ?? title(key), value: text), path: path)
            }
        }

        mutating func addSchedules() {
            let config = configuration
            let schedules = [
                Self
                    .schedule(config.basalProfile, id: "basal", title: "Basal Rates", start: \.start) { format($0.rate) + " U/hr"
                    },
                Self
                    .schedule(config.carbRatios.schedule, id: "carbs", title: "Carb Ratios", start: \.start) {
                        format($0.ratio) + " g/U" },
                Self.schedule(
                    config.insulinSensitivities.sensitivities,
                    id: "isf",
                    title: "Insulin Sensitivities",
                    start: \.start
                ) {
                    glucose($0.sensitivity, source: config.insulinSensitivities.units) + "/U"
                },
                Self.schedule(config.glucoseTargets.targets, id: "targets", title: "Glucose Targets", start: \.start) { entry in
                    let low = glucose(entry.low, source: config.glucoseTargets.units)
                    return entry.low == entry.high ? low : low + " – " + glucose(entry.high, source: config.glucoseTargets.units)
                }
            ]
            for schedule in schedules { add(schedule, path: ["Therapy"]) }
        }

        private static func schedule<Entry>(
            _ entries: [Entry], id: String, title: String, start: KeyPath<Entry, String>, value: (Entry) -> String
        ) -> BackupSettingsNode {
            let children: [BackupSettingsNode] = entries.enumerated().map { index, entry in
                .init(id: "\(id)-\(index)", title: entry[keyPath: start].formattedHourMinuteFromTimeString(), value: value(entry))
            }
            return .init(id: id, title: title, children: children)
        }

        private func glucose(_ value: Decimal, source: GlucoseUnits) -> String {
            let destination = configuration.settings.units
            let converted = source == destination ? value : (destination == .mmolL ? value.asMmolL : value.asMgdL)
            return format(converted) + " " + destination.rawValue
        }

        mutating func addEncoded<Value: Encodable>(_ value: Value, title: String, path: [String]) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let bytes = try? encoder.encode(value),
                  let object = try? JSONSerialization.jsonObject(with: bytes) else { return }
            add(jsonNode(object, title: title, id: (path + [title]).joined(separator: "/")), path: path)
        }

        mutating func add(_ node: BackupSettingsNode, path: [String]) {
            Self.insert(node, into: &roots, path: path[...])
        }

        private static func insert(_ node: BackupSettingsNode, into nodes: inout [BackupSettingsNode], path: ArraySlice<String>) {
            guard let first = path.first else { nodes.append(node)
                return }
            let index: Int
            if let existing = nodes.firstIndex(where: { $0.title == first }) { index = existing }
            else {
                nodes.append(.init(id: path.joined(separator: "/"), title: first))
                index = nodes.count - 1
            }
            insert(node, into: &nodes[index].children, path: path.dropFirst())
        }
    }

    private static func jsonNode(_ value: Any, title: String, id: String) -> Self {
        if let object = value as? [String: Any] {
            let hidden: Set<String> = ["id", "objectID", "snoozedUntil"]
            let children = object.keys.sorted().filter { !hidden.contains($0) }.compactMap { key -> Self? in
                guard let value = object[key], !(value is NSNull) else { return nil }
                return jsonNode(value, title: Self.title(key), id: id + "/" + key)
            }
            return .init(id: id, title: title, children: children)
        }
        if let items = value as? [Any] {
            return .init(
                id: id,
                title: title,
                value: items.isEmpty ? String(localized: "None") : nil,
                children: items.enumerated().map { index, item in
                    let object = item as? [String: Any]
                    let name = object?["name"] as? String ?? object?["dish"] as? String ?? "\(index + 1)"
                    return jsonNode(item, title: name, id: id + "/\(index)")
                }
            )
        }
        return .init(id: id, title: title, value: format(value))
    }

    private static func format(_ value: Any) -> String {
        if let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() {
            return boolean.boolValue ? String(localized: "Enabled") : String(localized: "Disabled")
        }
        if let decimal = value as? Decimal { return number(NSDecimalNumber(decimal: decimal)) }
        if let value = value as? NSNumber {
            return number(value)
        }
        if let value = value as? any RawRepresentable {
            let text = String(describing: value.rawValue)
            return text.contains("/") ? text : title(text)
        }
        if let value = value as? String { return value }
        if let value = value as? Date { return value.formatted(date: .abbreviated, time: .shortened) }
        if value is NSNull { return String(localized: "None") }
        return String(describing: value)
    }

    private static func number(_ value: NSNumber) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8
        return formatter.string(from: value) ?? value.stringValue
    }

    private static func title(_ value: String) -> String {
        let words = value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        let acronyms = [
            "bg": "BG",
            "isf": "ISF",
            "smb": "SMB",
            "cgm": "CGM",
            "uam": "UAM",
            "cr": "CR",
            "tdd": "TDD",
            "iob": "IOB",
            "cob": "COB",
            "fpu": "FPU"
        ]
        return words.split(separator: " ").map { acronyms[$0.lowercased()] ?? $0.capitalized }.joined(separator: " ")
    }
}

struct BackupSettingsTreeView: View {
    let node: BackupSettingsNode
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                ForEach(node.children) { child in
                    if child.children.isEmpty {
                        LabeledContent {
                            Text(child.value ?? String(localized: "None")).foregroundStyle(.secondary)
                        } label: { Text(LocalizedStringKey(child.title)) }
                    } else {
                        NavigationLink { BackupSettingsTreeView(node: child) } label: { Text(LocalizedStringKey(child.title)) }
                    }
                }
                if node.children
                    .isEmpty { Text(node.value ?? String(localized: "No settings included.")).foregroundStyle(.secondary) }
            } footer: {
                if let note = node.note { Text(note) }
            }.listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(Text(LocalizedStringKey(node.title)))
        .navigationBarTitleDisplayMode(.inline)
    }
}
