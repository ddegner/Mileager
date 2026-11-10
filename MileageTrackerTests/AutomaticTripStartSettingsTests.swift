import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class AutomaticTripStartSettingsTests: XCTestCase {
    func testMissingAndUnknownPreferencesDefaultToBoth() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.automaticTrackingEnabled = true
        XCTAssertEqual(preferences.automaticTripStartMode, .both)
        defaults.set("future-value", forKey: "AutomaticTripStartMode")
        XCTAssertEqual(preferences.automaticTripStartMode, .both)
        XCTAssertEqual(preferences.automaticTrackingEnabled, true)
        preferences.automaticTripStartMode = .bluetoothOrCarPlay
        XCTAssertEqual(Preferences(defaults: defaults).automaticTripStartMode, .bluetoothOrCarPlay)
        preferences.automaticTripStartMode = .both
        XCTAssertEqual(Preferences(defaults: defaults).automaticTripStartMode, .both)
        preferences.automaticTripStartMode = .motionDetection
        XCTAssertEqual(Preferences(defaults: defaults).automaticTripStartMode, .motionDetection)
        preferences.clearAll()
        XCTAssertEqual(preferences.automaticTripStartMode, .both)
    }

    func testPreviouslySavedChoicesKeepTheirSelectionAfterDefaultChanges() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        defaults.set("allDrives", forKey: "AutomaticTripStartMode")
        XCTAssertEqual(preferences.automaticTripStartMode, .motionDetection)
        defaults.set("savedCarsOnly", forKey: "AutomaticTripStartMode")
        XCTAssertEqual(preferences.automaticTripStartMode, .bluetoothOrCarPlay)
    }

    func testBluetoothModeNeedsNoSavedVehicleOrLiveConnection() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        let model = MileageAppModel(previewMode: true, preferences: preferences)
        XCTAssertEqual(model.automaticTripStartMode, .both)
        XCTAssertTrue(try model.bluetoothHintStore.fetchHints().isEmpty)
        XCTAssertTrue(model.setAutomaticTripStartMode(.bluetoothOrCarPlay))
        XCTAssertEqual(model.automaticTripStartMode, .bluetoothOrCarPlay)
        XCTAssertEqual(preferences.automaticTripStartMode, .bluetoothOrCarPlay)
        XCTAssertFalse(model.trackingActive, "Choosing a trigger must not enable stopped tracking")
        XCTAssertFalse(model.vehicleBluetoothHintsEnabled, "Automation selection does not change Bluetooth permissions")

        let relaunched = MileageAppModel(previewMode: true, preferences: preferences)
        XCTAssertEqual(relaunched.automaticTripStartMode, .bluetoothOrCarPlay)
        XCTAssertTrue(relaunched.setAutomaticTripStartMode(.motionDetection))
        XCTAssertEqual(preferences.automaticTripStartMode, .motionDetection)
    }

    func testMacCannotEnableCaptureMode() throws {
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: try makeTestDefaults()), platformOverride: .mac)
        XCTAssertFalse(model.setAutomaticTripStartMode(.bluetoothOrCarPlay))
        XCTAssertEqual(model.automaticTripStartMode, .both)
    }
}
