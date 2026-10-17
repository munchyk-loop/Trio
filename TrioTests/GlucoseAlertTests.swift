import Foundation
import Testing

@testable import Trio

@Suite("Trio Alerts: GlucoseAlert") struct GlucoseAlertTests {
    // MARK: - Group A: shouldEvaluate

    @Test("urgentLow evaluates even when isEnabled is false") func urgentLowDisabledStillEvaluates() {
        var a = GlucoseAlert(type: .urgentLow)
        a.isEnabled = false
        #expect(a.shouldEvaluate == true)
    }

    @Test("urgentLow evaluates when isEnabled is true") func urgentLowEnabledEvaluates() {
        var a = GlucoseAlert(type: .urgentLow)
        a.isEnabled = true
        #expect(a.shouldEvaluate == true)
    }

    @Test("low does not evaluate when disabled") func lowDisabledDoesNotEvaluate() {
        var a = GlucoseAlert(type: .low)
        a.isEnabled = false
        #expect(a.shouldEvaluate == false)
    }

    @Test("low evaluates when enabled") func lowEnabledEvaluates() {
        var a = GlucoseAlert(type: .low)
        a.isEnabled = true
        #expect(a.shouldEvaluate == true)
    }

    @Test("high does not evaluate when disabled") func highDisabledDoesNotEvaluate() {
        var a = GlucoseAlert(type: .high)
        a.isEnabled = false
        #expect(a.shouldEvaluate == false)
    }

    @Test("high evaluates when enabled") func highEnabledEvaluates() {
        var a = GlucoseAlert(type: .high)
        a.isEnabled = true
        #expect(a.shouldEvaluate == true)
    }

    @Test("forecastedLow does not evaluate when disabled") func forecastedLowDisabledDoesNotEvaluate() {
        var a = GlucoseAlert(type: .forecastedLow)
        a.isEnabled = false
        #expect(a.shouldEvaluate == false)
    }

    @Test("forecastedLow evaluates when enabled") func forecastedLowEnabledEvaluates() {
        var a = GlucoseAlert(type: .forecastedLow)
        a.isEnabled = true
        #expect(a.shouldEvaluate == true)
    }

    @Test("carbsRequired does not evaluate when disabled") func carbsRequiredDisabledDoesNotEvaluate() {
        var a = GlucoseAlert(type: .carbsRequired)
        a.isEnabled = false
        #expect(a.shouldEvaluate == false)
    }

    @Test("carbsRequired evaluates when enabled") func carbsRequiredEnabledEvaluates() {
        var a = GlucoseAlert(type: .carbsRequired)
        a.isEnabled = true
        #expect(a.shouldEvaluate == true)
    }

    // MARK: - Group A.5: type metadata

    @Test("carbsRequired defaults: threshold 10 g, bloop.caf, no override") func carbsRequiredDefaults() {
        let a = GlucoseAlert(type: .carbsRequired)
        #expect(a.thresholdMgDL == 10)
        #expect(a.soundFilename == "bloop.caf")
        #expect(a.overridesSilenceAndDND == false)
    }

    @Test("isReadingDriven: true for low family + high, false for forecast + carbs") func isReadingDriven() {
        #expect(GlucoseAlertType.urgentLow.isReadingDriven)
        #expect(GlucoseAlertType.low.isReadingDriven)
        #expect(GlucoseAlertType.high.isReadingDriven)
        #expect(!GlucoseAlertType.forecastedLow.isReadingDriven)
        #expect(!GlucoseAlertType.carbsRequired.isReadingDriven)
    }

    // MARK: - Group C: round-trip

    @Test("Fully-populated value survives encode/decode round-trip") func roundTrip() throws {
        var original = GlucoseAlert(type: .low)
        original.name = "Custom Low Alarm"
        original.isEnabled = false
        original.thresholdMgDL = 65
        original.soundFilename = "custom_sound.caf"
        original.playsSound = false
        original.overridesSilenceAndDND = true
        original.activeOption = .night
        original.snoozedUntil = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlucoseAlert.self, from: data)
        #expect(decoded == original)
    }
}
