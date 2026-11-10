import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class AutomaticEnrichmentLifecycleTests: XCTestCase {
    func testOnlyGenuineForegroundActivationsStartFreshEnrichmentSessions() throws {
        var newSessionFlags: [Bool] = []
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true,
            automaticEnrichmentScheduleOverride: { newSessionFlags.append($0) }
        )

        model.appDidBecomeActive()
        model.appDidBecomeActive()
        XCTAssertEqual(newSessionFlags, [true])

        model.appDidBecomeInactive()
        model.appDidBecomeActive()
        XCTAssertEqual(newSessionFlags, [true, true])
    }

    func testProtectedDataReloadStartsFreshEnrichmentSession() async throws {
        var newSessionFlags: [Bool] = []
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false,
            automaticEnrichmentScheduleOverride: { newSessionFlags.append($0) }
        )

        XCTAssertTrue(model.isAwaitingProtectedData)
        await model.reloadPersistenceForProtectedData()

        XCTAssertFalse(model.isAwaitingProtectedData)
        XCTAssertEqual(newSessionFlags, [true])
    }

    func testForegroundCloudChangeSchedulesWithinCurrentSessionBudget() throws {
        var newSessionFlags: [Bool] = []
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true,
            automaticEnrichmentScheduleOverride: { newSessionFlags.append($0) }
        )

        model.appDidBecomeActive()
        model.handleRemoteCloudChange()

        XCTAssertEqual(newSessionFlags, [true, false])
    }

    func testBackgroundCloudChangeDoesNotScheduleEnrichment() throws {
        var newSessionFlags: [Bool] = []
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true,
            automaticEnrichmentScheduleOverride: { newSessionFlags.append($0) }
        )

        model.handleRemoteCloudChange()

        XCTAssertTrue(newSessionFlags.isEmpty)
    }

    func testStoreWiringReconcilesStaleAttemptsAndPreservesPendingAttempts() throws {
        let suffix = "enrichment-wiring-\(UUID().uuidString)"
        let directory = try XCTUnwrap(
            ResetCoordinator.storeDirectoryForUITesting(suffix: suffix)
        )
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validTripID = UUID()
        let completedTripID = UUID()
        let orphanTripID = UUID()
        do {
            let persistence = try PersistenceController(
                mode: .localOnly,
                storeDirectory: directory
            )
            let context = persistence.container.viewContext
            insertAutomaticTrip(
                id: validTripID,
                start: Date(timeIntervalSince1970: 1_800_000_000),
                startState: .pending,
                in: context
            )
            insertAutomaticTrip(
                id: completedTripID,
                start: Date(timeIntervalSince1970: 1_800_003_600),
                startAddress: "Resolved Remotely",
                startState: .complete,
                in: context
            )
            insertAttempt(tripID: validTripID, in: context)
            insertAttempt(tripID: completedTripID, in: context)
            insertAttempt(tripID: orphanTripID, in: context)
            try context.save()
            try closeStores(persistence)
        }

        let model = MileageAppModel(
            arguments: arguments(storeSuffix: suffix),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true,
            automaticEnrichmentScheduleOverride: { _ in }
        )

        XCTAssertNotNil(try model.tripStore.fetchEnrichmentAttempt(
            tripID: validTripID,
            component: .startAddress
        ))
        XCTAssertNil(try model.tripStore.fetchEnrichmentAttempt(
            tripID: completedTripID,
            component: .startAddress
        ))
        XCTAssertNil(try model.tripStore.fetchEnrichmentAttempt(
            tripID: orphanTripID,
            component: .startAddress
        ))
        try closeStores(model.persistence)
    }

    func testForegroundCloudChangeReconcilesImportedTripStateBeforeScheduling() throws {
        var newSessionFlags: [Bool] = []
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true,
            automaticEnrichmentScheduleOverride: { newSessionFlags.append($0) }
        )
        let context = model.persistence.container.viewContext
        let validTripID = UUID()
        let remotelyCompletedTripID = UUID()
        let orphanTripID = UUID()
        insertAutomaticTrip(
            id: validTripID,
            start: Date(timeIntervalSince1970: 1_800_000_000),
            startState: .pending,
            in: context
        )
        insertAutomaticTrip(
            id: remotelyCompletedTripID,
            start: Date(timeIntervalSince1970: 1_800_003_600),
            startAddress: "Completed on another device",
            startState: .complete,
            in: context
        )
        insertAttempt(tripID: validTripID, in: context)
        insertAttempt(tripID: remotelyCompletedTripID, in: context)
        insertAttempt(tripID: orphanTripID, in: context)
        try context.save()

        model.appDidBecomeActive()
        model.handleRemoteCloudChange()

        XCTAssertEqual(newSessionFlags, [true, false])
        XCTAssertNotNil(try model.tripStore.fetchEnrichmentAttempt(
            tripID: validTripID,
            component: .startAddress
        ))
        XCTAssertNil(try model.tripStore.fetchEnrichmentAttempt(
            tripID: remotelyCompletedTripID,
            component: .startAddress
        ))
        XCTAssertNil(try model.tripStore.fetchEnrichmentAttempt(
            tripID: orphanTripID,
            component: .startAddress
        ))
    }

    private func arguments(storeSuffix: String = "enrichment-lifecycle-\(UUID().uuidString)") -> [String] {
        [
            "MileageTracker",
            "--uitesting",
            "--skip-onboarding",
            "--test-store-suffix=\(storeSuffix)"
        ]
    }

    @discardableResult
    private func insertAutomaticTrip(
        id: UUID,
        start: Date,
        startAddress: String? = nil,
        startState: TripEnrichmentState,
        in context: NSManagedObjectContext
    ) -> NSManagedObject {
        let trip = NSEntityDescription.insertNewObject(
            forEntityName: "TripEntity",
            into: context
        )
        trip.setValue(id, forKey: "id")
        trip.setValue(start, forKey: "createdAt")
        trip.setValue(start, forKey: "updatedAt")
        trip.setValue("automatic", forKey: "captureSource")
        trip.setValue(start, forKey: "startDate")
        trip.setValue(start.addingTimeInterval(600), forKey: "endDate")
        trip.setValue(42.0, forKey: "startLatitude")
        trip.setValue(-71.0, forKey: "startLongitude")
        trip.setValue(42.1, forKey: "endLatitude")
        trip.setValue(-71.1, forKey: "endLongitude")
        trip.setValue(startAddress, forKey: "startAddress")
        trip.setValue(1_000.0, forKey: "distanceMeters")
        trip.setValue(600.0, forKey: "durationSeconds")
        trip.setValue(ReviewStatus.needsReview.rawValue, forKey: "reviewStatusRaw")
        trip.setValue(0.0, forKey: "tollsAmount")
        trip.setValue(0.0, forKey: "parkingAmount")
        trip.setValue(false, forKey: "needsAttention")
        trip.setValue(startState.rawValue, forKey: "startAddressEnrichmentStateRaw")
        trip.setValue(TripEnrichmentState.legacy.rawValue, forKey: "endAddressEnrichmentStateRaw")
        trip.setValue(TripEnrichmentState.legacy.rawValue, forKey: "routeEnrichmentStateRaw")
        return trip
    }

    private func insertAttempt(
        tripID: UUID,
        in context: NSManagedObjectContext
    ) {
        let attempt = NSEntityDescription.insertNewObject(
            forEntityName: "TripEnrichmentAttemptEntity",
            into: context
        )
        attempt.setValue(UUID(), forKey: "id")
        attempt.setValue(tripID, forKey: "tripID")
        attempt.setValue(TripEnrichmentComponent.startAddress.rawValue, forKey: "componentRaw")
        attempt.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "lastAttemptAt")
        attempt.setValue(1, forKey: "consecutiveFailures")
        attempt.setValue(
            TripEnrichmentFailureCategory.networkUnavailable.rawValue,
            forKey: "failureCategoryRaw"
        )
    }

    private func closeStores(_ persistence: PersistenceController) throws {
        let coordinator = persistence.container.persistentStoreCoordinator
        persistence.container.viewContext.reset()
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }
}
