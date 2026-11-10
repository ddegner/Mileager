import AppCore
import Foundation
import Observation
import XCTest
@testable import MileageTracker

@MainActor
final class VehicleAutomationReceiptTests: XCTestCase {
    func testReceiptPersistsKeepsNewestDateAndClearsWithPreferences() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        let now = Date()
        XCTAssertNil(preferences.lastVehicleAutomationReceivedAt)
        preferences.recordVehicleAutomationReceipt(trigger: .vehicleBluetooth, at: now)
        preferences.recordVehicleAutomationReceipt(trigger: .carPlay, at: now.addingTimeInterval(-60))
        preferences.recordVehicleAutomationReceipt(trigger: .manual, at: now.addingTimeInterval(60))
        preferences.recordVehicleAutomationReceipt(trigger: .charger, at: now.addingTimeInterval(60))
        XCTAssertEqual(Preferences(defaults: defaults).lastVehicleAutomationReceivedAt, now)
        preferences.clearAll()
        XCTAssertNil(Preferences(defaults: defaults).lastVehicleAutomationReceivedAt)
    }

    func testModelLoadsReceiptAndRefreshesAfterForegroundAndActionDelivery() async throws {
        // Foreground bookkeeping predates injected model preferences. Restore
        // its one standard-defaults value after exercising the real lifecycle.
        let foregroundKey = "restartAdvisor.lastForegroundBootTime"
        let previousForeground = UserDefaults.standard.object(forKey: foregroundKey)
        defer { UserDefaults.standard.set(previousForeground, forKey: foregroundKey) }
        let preferences = Preferences(defaults: try makeTestDefaults())
        let first = Date().addingTimeInterval(-120)
        preferences.recordVehicleAutomationReceipt(trigger: .carPlay, at: first)
        let model = MileageAppModel(previewMode: true, preferences: preferences)
        XCTAssertEqual(model.lastVehicleAutomationReceivedAt, first)

        let foregroundReceipt = first.addingTimeInterval(30)
        preferences.recordVehicleAutomationReceipt(trigger: .vehicleBluetooth, at: foregroundReceipt)
        model.appDidBecomeActive()
        XCTAssertEqual(model.lastVehicleAutomationReceivedAt, foregroundReceipt)

        let updated = expectation(description: "Visible receipt updates when the intent finishes")
        withObservationTracking {
            _ = model.lastVehicleAutomationReceivedAt
        } onChange: {
            updated.fulfill()
        }
        let latest = Date()
        preferences.recordVehicleAutomationReceipt(trigger: .vehicleBluetooth, at: latest)
        NotificationCenter.default.post(name: .pendingDriveStartSignalCreated, object: nil)
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(model.lastVehicleAutomationReceivedAt, latest)
        model.appDidBecomeInactive()
    }

    func testSpoolReceiptRequiresUsableVehicleActionAndPreservesOriginalTime() throws {
        let cases: [(DriveStartExternalTrigger, TimeInterval, Bool)] = [
            (.vehicleBluetooth, -10, true),
            (.carPlay, -10, true),
            (.charger, -10, false),
            (.manual, -10, false),
            (.vehicleBluetooth, -10 * 60, false),
            (.vehicleBluetooth, -31 * 60, false)
        ]
        for (trigger, age, shouldRecord) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let spool = PendingSignalSpool(directory: directory)
            // The spool stores ISO8601 whole seconds.
            let sentAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + age)
            try spool.save(trigger: trigger, at: sentAt)
            let preferences = Preferences(defaults: try makeTestDefaults())
            let model = MileageAppModel(previewMode: true, preferences: preferences)
            model.drainSpooledStartSignals(from: spool)
            XCTAssertEqual(model.lastVehicleAutomationReceivedAt, shouldRecord ? sentAt : nil)
            XCTAssertEqual(preferences.lastVehicleAutomationReceivedAt, shouldRecord ? sentAt : nil)
            XCTAssertNil(spool.drain())
        }
    }
}
