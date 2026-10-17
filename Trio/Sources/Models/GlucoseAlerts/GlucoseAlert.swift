import Foundation

/// A single configurable glucose alarm. Multiple entries of the same type are
/// allowed — e.g. a Low alarm `active: .day` at 80 mg/dL plus a second Low
/// `active: .night` at 70 mg/dL.
struct GlucoseAlert: Identifiable, Codable, Equatable {
    var id: UUID
    var type: GlucoseAlertType
    var name: String
    var isEnabled: Bool
    var thresholdMgDL: Decimal
    var soundFilename: String
    /// When false, the alarm fires the banner / notification but no sound.
    /// iOS still drives haptics from the interruption level.
    var playsSound: Bool
    /// When true, this alarm bypasses Focus Mode / silent switch
    /// modes. Maps to `Alert.InterruptionLevel.critical` and triggers the
    /// in-process `CriticalAlertAudioPlayer` fallback for builds without the
    /// Critical Alerts entitlement.
    var overridesSilenceAndDND: Bool
    var activeOption: ActiveOption
    /// Per-alarm snooze. Distinct from the global mute on `AlertMuter`.
    var snoozedUntil: Date?
    var delivery: SettingsAlertDelivery?
    var snoozeMinutes: Int?
    var soundMode: SettingsAlertSoundMode?

    init(type: GlucoseAlertType) {
        id = UUID()
        self.type = type
        name = type.displayName
        isEnabled = type != .fallingFast
        thresholdMgDL = type.defaultThresholdMgDL
        soundFilename = type.defaultSoundFilename
        playsSound = true
        overridesSilenceAndDND = type.defaultOverridesSilenceAndDND
        activeOption = .always
        snoozedUntil = nil
    }

    /// Whether the coordinator should fire this alarm when a reading breaches.
    /// Urgent-low is always active; its editor does not expose an Enabled toggle.
    var shouldEvaluate: Bool {
        type == .urgentLow || isEnabled
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case isEnabled
        case thresholdMgDL
        case soundFilename
        case playsSound
        case overridesSilenceAndDND
        case activeOption
        case snoozedUntil
        case delivery
        case snoozeMinutes
        case soundMode
    }
}
