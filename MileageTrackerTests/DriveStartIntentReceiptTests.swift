import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class DriveStartIntentReceiptTests: XCTestCase {
    func testVehicleActionsRecordReceiptAfterSavingSignalWithoutChangingTrackingSettings() throws {
        for trigger in [DriveStartTriggerAppEnum.vehicleBluetooth, .carPlay] {
            try withEnvironment { environment in
                let preferences = environment.preferences
                preferences.automaticTrackingEnabled = false
                preferences.automaticTripStartMode = .motionDetection
                preferences.detailedDiagnosticsEnabled = true

                try DriveStartIntentPerformer.armDriveStart(
                    trigger: trigger,
                    platform: .iOS,
                    preferences: preferences,
                    spool: environment.spool
                )

                let signal = try XCTUnwrap(environment.stack.pendingDriveStartSignalStore.fetchLatest())
                XCTAssertEqual(signal.trigger, trigger.domainTrigger)
                XCTAssertEqual(signal.status, .pending)
                XCTAssertEqual(preferences.lastVehicleAutomationReceivedAt, signal.createdAt)
                XCTAssertEqual(preferences.automaticTrackingEnabled, false)
                XCTAssertEqual(preferences.automaticTripStartMode, .motionDetection)
                XCTAssertNil(environment.spool.drain())
            }
        }
    }

    func testManualAndChargerActionsDoNotVerifyVehicleAutomation() throws {
        for trigger in [DriveStartTriggerAppEnum.manual, .charger] {
            try withEnvironment { environment in
                try DriveStartIntentPerformer.armDriveStart(
                    trigger: trigger,
                    platform: .iOS,
                    preferences: environment.preferences,
                    spool: environment.spool
                )

                let signal = try XCTUnwrap(environment.stack.pendingDriveStartSignalStore.fetchLatest())
                XCTAssertEqual(signal.trigger, trigger.domainTrigger)
                XCTAssertNil(environment.preferences.lastVehicleAutomationReceivedAt)
            }
        }
    }

    func testSpooledVehicleActionWaitsForPromotionBeforeRecordingReceipt() throws {
        try withEnvironment { environment in
            IntentDataProvider.stackFactory = { throw TestError.sealedStore }

            try DriveStartIntentPerformer.armDriveStart(
                trigger: .vehicleBluetooth,
                platform: .iOS,
                preferences: environment.preferences,
                spool: environment.spool
            )

            XCTAssertNil(environment.preferences.lastVehicleAutomationReceivedAt)
            XCTAssertNil(try environment.stack.pendingDriveStartSignalStore.fetchLatest())
            let spooled = try XCTUnwrap(environment.spool.drain())
            XCTAssertEqual(spooled.trigger, .vehicleBluetooth)
        }
    }

    func testFailedSpoolDoesNotRecordReceipt() throws {
        try withEnvironment { environment in
            IntentDataProvider.stackFactory = { throw TestError.sealedStore }
            let blockedDirectory = environment.directory.appendingPathComponent("not-a-directory")
            try Data().write(to: blockedDirectory)
            let spool = PendingSignalSpool(directory: blockedDirectory)

            XCTAssertThrowsError(try DriveStartIntentPerformer.armDriveStart(
                trigger: .carPlay,
                platform: .iOS,
                preferences: environment.preferences,
                spool: spool
            ))

            XCTAssertNil(environment.preferences.lastVehicleAutomationReceivedAt)
            XCTAssertNil(try environment.stack.pendingDriveStartSignalStore.fetchLatest())
        }
    }

    func testMacRejectsActionBeforeOpeningStoreOrRecordingReceipt() throws {
        try withEnvironment { environment in
            var openedStore = false
            IntentDataProvider.stackFactory = {
                openedStore = true
                return environment.stack
            }

            XCTAssertThrowsError(try DriveStartIntentPerformer.armDriveStart(
                trigger: .vehicleBluetooth,
                platform: .mac,
                preferences: environment.preferences,
                spool: environment.spool
            )) { error in
                XCTAssertTrue(error is DriveStartIntentError)
            }

            XCTAssertFalse(openedStore)
            XCTAssertNil(environment.preferences.lastVehicleAutomationReceivedAt)
            XCTAssertNil(try environment.stack.pendingDriveStartSignalStore.fetchLatest())
            XCTAssertNil(environment.spool.drain())
        }
    }

    private enum TestError: Error {
        case sealedStore
    }

    private struct Environment {
        let preferences: Preferences
        let stack: IntentDataStack
        let spool: PendingSignalSpool
        let directory: URL
    }

    private func withEnvironment(_ body: (Environment) throws -> Void) throws {
        let suiteName = "DriveStartIntentReceiptTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveStartIntentReceiptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            IntentDataProvider.resetFactoryForTesting()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let stack = try IntentDataStack(mode: .localOnly, storeDirectory: directory.appendingPathComponent("Store"))
        defer {
            stack.persistence.container.viewContext.reset()
            let coordinator = stack.persistence.container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        IntentDataProvider.stackFactory = { stack }
        try body(Environment(
            preferences: Preferences(defaults: defaults),
            stack: stack,
            spool: PendingSignalSpool(directory: directory.appendingPathComponent("Spool")),
            directory: directory
        ))
    }
}
