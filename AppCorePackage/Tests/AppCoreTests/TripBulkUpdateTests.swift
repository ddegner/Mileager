import CoreData
import XCTest
@testable import AppCore

@MainActor
final class TripBulkUpdateTests: XCTestCase {
    func testBulkUpdateSavesOnceReturnsStableOrderAndChangesEveryRequestedField() throws {
        let (store, context) = try makeStore()
        let vehicleStore = VehicleStore(context: context)
        let vehicle = try vehicleStore.createVehicle(name: "Work Van")
        let first = try makeTrip(store, day: 1)
        let second = try makeTrip(store, day: 2)
        _ = try store.appendAttentionReason(tripID: first.id, reason: "Verify route")
        _ = try store.appendAttentionReason(tripID: second.id, reason: "Verify route")
        let observer = ChangeObserver()
        store.changeObserver = observer

        let updated = try store.updateTrips(
            tripIDs: [second.id, first.id],
            update: TripBulkUpdate(
                classification: .set(.business),
                businessPurpose: "Client meeting",
                vehicle: .set(vehicle.id),
                resolveAttention: true
            )
        )

        XCTAssertEqual(updated.map(\.id), [second.id, first.id])
        XCTAssertTrue(updated.allSatisfy { $0.classification == .business })
        XCTAssertTrue(updated.allSatisfy { $0.businessPurpose == "Client meeting" })
        XCTAssertTrue(updated.allSatisfy { $0.vehicleID == vehicle.id })
        XCTAssertTrue(updated.allSatisfy { $0.vehicleAssignmentSource == .manual })
        XCTAssertTrue(updated.allSatisfy { !$0.needsAttention && $0.attentionReasons.isEmpty })
        XCTAssertEqual(observer.changes.count, 1)
        XCTAssertEqual(Set(observer.changes[0].upserted.map(\.id)), [first.id, second.id])
    }

    func testMissingTripRejectsWholeBulkUpdateBeforeMutation() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let before = try store.editableSnapshot(tripID: trip.id)

        XCTAssertThrowsError(try store.updateTrips(
            tripIDs: [trip.id, UUID()],
            update: TripBulkUpdate(classification: .set(.personal))
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .tripNotFound)
        }

        XCTAssertEqual(try store.editableSnapshot(tripID: trip.id), before)
    }

    func testInvalidVehiclePurposeAndDuplicateIDsRejectWithoutMutation() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let before = try store.editableSnapshot(tripID: trip.id)

        XCTAssertThrowsError(try store.updateTrips(
            tripIDs: [trip.id],
            update: TripBulkUpdate(vehicle: .set(UUID()))
        )) { error in
            XCTAssertEqual(error as? VehicleStoreError, .vehicleNotFound)
        }
        XCTAssertThrowsError(try store.updateTrips(
            tripIDs: [trip.id],
            update: TripBulkUpdate(
                classification: .set(.personal),
                businessPurpose: "Client meeting"
            )
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidBusinessPurpose)
        }
        XCTAssertThrowsError(try store.updateTrips(
            tripIDs: [trip.id, trip.id],
            update: TripBulkUpdate(classification: .set(.personal))
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidBulkRequest)
        }

        XCTAssertEqual(try store.editableSnapshot(tripID: trip.id), before)
    }

    func testBulkRestoreIsExactOrderedAndSavesOnce() throws {
        let (store, _) = try makeStore()
        let first = try makeTrip(store, day: 1, purpose: "Site visit")
        let second = try makeTrip(store, day: 2, purpose: "Delivery")
        _ = try store.addFee(TripFee(
            tripID: first.id,
            category: .parking,
            amount: 12,
            occurredAt: first.startDate,
            label: "Garage"
        ))
        _ = try store.addFee(TripFee(
            tripID: second.id,
            category: .toll,
            amount: 8,
            occurredAt: second.startDate,
            label: "Bridge"
        ))
        let before = try store.editableSnapshots(tripIDs: [second.id, first.id])
        _ = try store.updateTrips(
            tripIDs: [second.id, first.id],
            update: TripBulkUpdate(
                classification: .set(.personal),
                businessPurpose: ""
            )
        )
        let observer = ChangeObserver()
        store.changeObserver = observer

        let restored = try store.restoreEditableSnapshots(before)

        XCTAssertEqual(restored.map(\.id), [second.id, first.id])
        XCTAssertEqual(try store.editableSnapshots(tripIDs: [second.id, first.id]), before)
        XCTAssertEqual(observer.changes.count, 1)
        XCTAssertEqual(Set(observer.changes[0].upserted.map(\.id)), [first.id, second.id])
    }

    func testBulkRestoreMissingTripDoesNotRestoreEarlierRows() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        var snapshot = try store.editableSnapshot(tripID: trip.id)
        snapshot.notes = "Should not be restored"
        var missing = snapshot
        missing.tripID = UUID()
        let before = try store.editableSnapshot(tripID: trip.id)

        XCTAssertThrowsError(try store.restoreEditableSnapshots([snapshot, missing])) { error in
            XCTAssertEqual(error as? TripStoreError, .tripNotFound)
        }

        XCTAssertEqual(try store.editableSnapshot(tripID: trip.id), before)
    }

    func testClearClassificationPreservesPurposeAndResolveReturnsUnclassifiedTripToReview() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1, purpose: "Site visit")
        _ = try store.appendAttentionReason(tripID: trip.id, reason: "Verify route")

        let updated = try XCTUnwrap(store.updateTrips(
            tripIDs: [trip.id],
            update: TripBulkUpdate(classification: .clear, resolveAttention: true)
        ).first)

        XCTAssertNil(updated.classification)
        XCTAssertEqual(updated.businessPurpose, "Site visit")
        XCTAssertEqual(updated.reviewStatus, .needsReview)
        XCTAssertFalse(updated.needsAttention)
        XCTAssertTrue(updated.attentionReasons.isEmpty)
    }

    func testBulkReclassifyAwayFromBusinessPreservesPurposeForRoundTrip() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1, purpose: "Site visit")

        let personal = try XCTUnwrap(store.updateTrips(
            tripIDs: [trip.id],
            update: TripBulkUpdate(classification: .set(.personal))
        ).first)
        XCTAssertEqual(personal.classification, .personal)
        XCTAssertEqual(personal.businessPurpose, "Site visit")

        let restored = try XCTUnwrap(store.updateTrips(
            tripIDs: [trip.id],
            update: TripBulkUpdate(classification: .set(.business))
        ).first)
        XCTAssertEqual(restored.businessPurpose, "Site visit")
    }

    func testBulkReclassifyToNotADriveClearsPurpose() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1, purpose: "Site visit")

        let updated = try XCTUnwrap(store.updateTrips(
            tripIDs: [trip.id],
            update: TripBulkUpdate(classification: .set(.notADrive))
        ).first)

        XCTAssertEqual(updated.classification, .notADrive)
        XCTAssertNil(updated.businessPurpose)
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
    }

    func testBulkDeleteValidatesFirstAndEmitsOneDeletionChangeSet() throws {
        let (store, _) = try makeStore()
        let first = try makeTrip(store, day: 1)
        let second = try makeTrip(store, day: 2)
        let observer = ChangeObserver()
        store.changeObserver = observer

        try store.deleteTrips(ids: [second.id, first.id])

        XCTAssertThrowsError(try store.fetchTrip(id: first.id))
        XCTAssertThrowsError(try store.fetchTrip(id: second.id))
        XCTAssertEqual(observer.changes.count, 1)
        XCTAssertEqual(Set(observer.changes[0].deletedIDs), [first.id, second.id])
        XCTAssertTrue(observer.changes[0].upserted.isEmpty)
    }

    func testBulkDeleteMissingOrDuplicateIDRollsBackEveryTrip() throws {
        let (store, _) = try makeStore()
        let first = try makeTrip(store, day: 1)
        let second = try makeTrip(store, day: 2)

        XCTAssertThrowsError(try store.deleteTrips(ids: [first.id, UUID()])) { error in
            XCTAssertEqual(error as? TripStoreError, .tripNotFound)
        }
        XCTAssertNoThrow(try store.fetchTrip(id: first.id))
        XCTAssertNoThrow(try store.fetchTrip(id: second.id))

        XCTAssertThrowsError(try store.deleteTrips(ids: [first.id, first.id])) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidBulkRequest)
        }
        XCTAssertNoThrow(try store.fetchTrip(id: first.id))
        XCTAssertNoThrow(try store.fetchTrip(id: second.id))
    }

    private func makeStore() throws -> (TripStore, NSManagedObjectContext) {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        return (TripStore(context: context), context)
    }

    private func makeTrip(
        _ store: TripStore,
        day: Int,
        purpose: String? = nil
    ) throws -> TripSummary {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(day * 86_400))
        return try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Origin \(day)",
            endAddress: "Destination \(day)",
            distanceMeters: 5_000,
            classification: purpose == nil ? nil : .business,
            businessPurpose: purpose,
            notes: "Trip \(day)"
        ))
    }
}

private final class ChangeObserver: TripStoreChangeObserver {
    private(set) var changes: [TripChangeSet] = []

    func tripStoreDidChange(_ change: TripChangeSet) {
        changes.append(change)
    }
}
