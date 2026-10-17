import Foundation

enum SettingsAlertSoundMode: String, Codable, CaseIterable, Identifiable {
    case soundAlways
    case vibrateAlways
    case matchPhone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .soundAlways: return String(localized: "Sound Always")
        case .vibrateAlways: return String(localized: "Vibrate Always")
        case .matchPhone: return String(localized: "Match Phone")
        }
    }

    var symbol: String {
        switch self {
        case .soundAlways: return "speaker.wave.2.fill"
        case .vibrateAlways: return "speaker.slash.fill"
        case .matchPhone: return "iphone"
        }
    }
}

enum SettingsAlertDelivery: String, Codable, CaseIterable, Identifiable {
    case timeSensitive
    case critical
    case alarm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timeSensitive: return String(localized: "Time Sensitive")
        case .critical: return String(localized: "Critical")
        case .alarm: return String(localized: "Alarm")
        }
    }
}

struct SettingsAlertSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case always, time, location }
    var kind: Kind = .always
    var startMinute = 0
    var endMinute = 0
    var weekdays: Set<Int> = Set(1 ... 7)
    var locationName = ""
    var latitude = 0.0
    var longitude = 0.0
    var radius = 200.0

    private enum CodingKeys: String, CodingKey {
        case kind, startMinute, endMinute, weekdays, locationName, latitude, longitude, radius
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(startMinute, forKey: .startMinute)
        try values.encode(endMinute, forKey: .endMinute)
        // Stable ordering keeps strict backup validation and fingerprints deterministic.
        try values.encode(weekdays.sorted(), forKey: .weekdays)
        try values.encode(locationName, forKey: .locationName)
        try values.encode(latitude, forKey: .latitude)
        try values.encode(longitude, forKey: .longitude)
        try values.encode(radius, forKey: .radius)
    }

    func matches(at date: Date, calendar: Calendar = .current, isInsideLocation: Bool = false) -> Bool {
        switch kind {
        case .always: return true
        case .location: return isInsideLocation
        case .time:
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let weekday = calendar.component(.weekday, from: date)
            if startMinute == endMinute { return weekdays.contains(weekday) }
            if startMinute < endMinute {
                return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
            }
            if minute >= startMinute { return weekdays.contains(weekday) }
            let previous = weekday == 1 ? 7 : weekday - 1
            return minute < endMinute && weekdays.contains(previous)
        }
    }
}

struct SettingsAlertProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var symbol: String? = nil
    var isEnabled = true
    var isFallback = false
    var schedule = SettingsAlertSchedule()
    var alerts: [GlucoseAlert] = []

    var displaySymbol: String {
        if let symbol { return symbol }
        if schedule.kind == .location { return "briefcase.fill" }
        if schedule.kind == .time { return schedule.startMinute >= 18 * 60 ? "moon.fill" : "sun.max.fill" }
        return "bell.fill"
    }

    var supportedAlerts: [GlucoseAlert] { alerts.filter { $0.type != .carbsRequired } }

    static func selected(
        from profiles: [Self], at date: Date, insideLocations: Set<UUID>,
        calendar: Calendar = .current
    ) -> Self? {
        let eligible = profiles.filter {
            $0.isEnabled && !$0.isFallback &&
                $0.schedule.matches(at: date, calendar: calendar, isInsideLocation: insideLocations.contains($0.id))
        }
        // Explicit list order breaks ties within each schedule type.
        return eligible.first { $0.schedule.kind == .location } ??
            eligible.first { $0.schedule.kind == .time } ??
            eligible.first ??
            profiles.first { $0.isFallback && $0.isEnabled }
    }
}
