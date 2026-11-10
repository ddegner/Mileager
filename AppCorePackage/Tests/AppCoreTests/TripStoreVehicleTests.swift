import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class TripStoreVehicleTests: XCTestCase {
    private func makeStore() throws -> TripStore {
        let persistence = try PersistenceController(inMemory: true)
        return TripStore(context: persistence.container.viewContext)
    }

    private func makeStores() throws -> (trips: TripStore, vehicles: VehicleStore) {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        return (TripStore(context: context), VehicleStore(context: context))
    }

    @discardableResult
    private func makeTrip(
        _ store: TripStore,
        origin: String = "Home",
        destination: String = "Office",
        miles: Double = 10,
        startOffset: TimeInterval = 0
    ) throws -> TripSummary {
        try AppCoreTests.makeTrip(
            store,
            start: Date(timeIntervalSince1970: 1_700_000_000 + startOffset),
            duration: 1_000,
            distanceMiles: miles,
            classification: .business,
            businessPurpose: "Work",
            startAddress: origin,
            endAddress: destination
        )
    }

    func testAssignAndClearVehicle() throws {
        let store = try makeStore()
        let trip = try makeTrip(store)
        let vehicle = UUID()
        let assigned = try store.assignVehicle(tripID: trip.id, vehicleID: vehicle)
        XCTAssertEqual(assigned.vehicleID, vehicle)
        XCTAssertEqual(assigned.vehicleAssignmentSource, .manual)

        let cleared = try store.assignVehicle(tripID: trip.id, vehicleID: nil)
        XCTAssertNil(cleared.vehicleID)
        XCTAssertNil(cleared.vehicleAssignmentSource)
    }

    func testAutomaticAssignmentNeverOverridesManual() throws {
        let store = try makeStore()
        let trip = try makeTrip(store)
        let manualVehicle = UUID()
        _ = try store.assignVehicle(tripID: trip.id, vehicleID: manualVehicle)

        let attempted = try store.applyAutomaticVehicleAssignment(
            tripID: trip.id,
            vehicleID: UUID(),
            source: .bluetooth
        )
        XCTAssertEqual(attempted.vehicleID, manualVehicle)
        XCTAssertEqual(attempted.vehicleAssignmentSource, .manual)
    }

    func testFetchTripsByVehicleIncludesUnassignedForPrimary() throws {
        let store = try makeStore()
        let primary = UUID()
        let other = UUID()
        let unassigned = try makeTrip(store, destination: "Unassigned")
        let onPrimary = try makeTrip(store, destination: "Primary")
        let onOther = try makeTrip(store, destination: "Other")
        _ = try store.assignVehicle(tripID: onPrimary.id, vehicleID: primary)
        _ = try store.assignVehicle(tripID: onOther.id, vehicleID: other)

        let primaryTrips = try store.fetchTrips(vehicle: .vehicle(primary, includesUnassigned: true))
        let ids = Set(primaryTrips.map(\.id))
        XCTAssertTrue(ids.contains(onPrimary.id))
        XCTAssertTrue(ids.contains(unassigned.id))
        XCTAssertFalse(ids.contains(onOther.id))

        let strictOther = try store.fetchTrips(vehicle: .vehicle(other, includesUnassigned: false))
        XCTAssertEqual(strictOther.map(\.id), [onOther.id])

        let unassignedOnly = try store.fetchTrips(vehicle: .unassigned)
        XCTAssertEqual(unassignedOnly.map(\.id), [unassigned.id])
    }

    func testReattributeOnlyTouchesNonManualMatchingHash() throws {
        let store = try makeStore()
        let hash = "device-hash-1"
        let matching = try makeTrip(store, destination: "Matching")
        _ = try store.setStartBluetoothHints(tripID: matching.id, identifierHashes: [hash])
        let manual = try makeTrip(store, destination: "Manual")
        _ = try store.setStartBluetoothHints(tripID: manual.id, identifierHashes: [hash])
        _ = try store.assignVehicle(tripID: manual.id, vehicleID: UUID())
        let noHash = try makeTrip(store, destination: "NoHash")

        let candidates = try store.vehicleReattributionCandidates(startHintHash: hash)
        XCTAssertEqual(candidates.map(\.tripID), [matching.id])

        let vehicle = UUID()
        let changed = try store.reattributeTrips(startHintHash: hash, to: vehicle)
        XCTAssertEqual(changed, 1)

        let refreshedMatching = try store.fetchTrip(id: matching.id)
        XCTAssertEqual(refreshedMatching.vehicleID, vehicle)
        XCTAssertEqual(refreshedMatching.vehicleAssignmentSource, .bluetooth)
        // The manual trip and the no-hash trip are untouched.
        XCTAssertEqual(try store.fetchTrip(id: manual.id).vehicleAssignmentSource, .manual)
        XCTAssertNil(try store.fetchTrip(id: noHash.id).vehicleID)
    }

    func testDuplicateTripIdentityProducesOneReattributionAndOneChange() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let hash = "duplicate-trip-hash"
        let trip = try makeTrip(store, destination: "Duplicate identity")
        _ = try store.setStartBluetoothHints(tripID: trip.id, identifierHashes: [hash])
        let request = TripEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", trip.id as CVarArg)
        let current = try XCTUnwrap(context.fetch(request).first)
        let duplicate = try clone(current, in: context)
        duplicate.createdAt = current.createdAt?.addingTimeInterval(-60)
        duplicate.updatedAt = current.updatedAt?.addingTimeInterval(-60)
        try context.save()
        let observer = VehicleTripChangeObserver()
        store.changeObserver = observer

        XCTAssertEqual(
            try store.vehicleReattributionCandidates(startHintHash: hash).map(\.tripID),
            [trip.id]
        )
        let vehicleID = UUID()
        XCTAssertEqual(try store.reattributeTrips(startHintHash: hash, to: vehicleID), 1)
        XCTAssertEqual(observer.lastChange?.upserted.map(\.id), [trip.id])
        XCTAssertEqual(try store.fetchTrip(id: trip.id).vehicleID, vehicleID)

        duplicate.vehicleID = vehicleID
        duplicate.vehicleAssignmentSource = .bluetooth
        try context.save()
        let deletionObserver = VehicleTripChangeObserver()
        store.changeObserver = deletionObserver
        XCTAssertEqual(try store.reassignTrips(from: vehicleID, to: nil), 1)
        XCTAssertEqual(deletionObserver.lastChange?.upserted.map(\.id), [trip.id])
        XCTAssertNil(try store.fetchTrip(id: trip.id).vehicleID)
    }

    /// A stale Shortcut automation or unlinked Bluetooth hint can carry a
    /// deleted vehicle's ID; automatic assignment must reject it rather than
    /// strand the trip outside every vehicle filter.
    func testAutomaticAssignmentRequiresExistingVehicle() throws {
        let (store, vehicles) = try makeStores()
        let trip = try makeTrip(store)

        let skipped = try store.applyAutomaticVehicleAssignment(
            tripID: trip.id,
            vehicleID: UUID(),
            source: .bluetooth
        )
        XCTAssertNil(skipped.vehicleID)
        XCTAssertNil(skipped.vehicleAssignmentSource)

        let honda = try vehicles.createVehicle(name: "Honda Odyssey")
        let assigned = try store.applyAutomaticVehicleAssignment(
            tripID: trip.id,
            vehicleID: honda.id,
            source: .bluetooth
        )
        XCTAssertEqual(assigned.vehicleID, honda.id)
        XCTAssertEqual(assigned.vehicleAssignmentSource, .bluetooth)
    }

    func testSaveCompletedTripIgnoresUnknownDraftVehicle() throws {
        let (store, vehicles) = try makeStores()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40.69, longitude: -73.99, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(60), latitude: 40.70, longitude: -73.99, horizontalAccuracy: 10)
        ]
        func draft(id: UUID, vehicleID: UUID?) -> TripDraft {
            TripDraft(
                id: id,
                startDate: start,
                endDate: start.addingTimeInterval(60),
                samples: samples,
                distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples),
                vehicleID: vehicleID,
                vehicleAssignmentSource: vehicleID != nil ? .shortcut : nil
            )
        }

        let stale = try store.saveCompletedTrip(draft(id: UUID(), vehicleID: UUID()))
        XCTAssertNil(stale.vehicleID)
        XCTAssertNil(stale.vehicleAssignmentSource)

        let honda = try vehicles.createVehicle(name: "Honda Odyssey")
        let tagged = try store.saveCompletedTrip(draft(id: UUID(), vehicleID: honda.id))
        XCTAssertEqual(tagged.vehicleID, honda.id)
        XCTAssertEqual(tagged.vehicleAssignmentSource, .shortcut)
    }

    /// Merging must not launder an automatic attribution into `.manual`, which
    /// would permanently exempt the merged trip (and its un-merged children)
    /// from Bluetooth re-attribution corrections.
    func testMergePreservesAutomaticVehicleSource() throws {
        let (store, vehicles) = try makeStores()
        let honda = try vehicles.createVehicle(name: "Honda Odyssey")
        let first = try makeTrip(store, destination: "Leg 1")
        let second = try makeTrip(store, destination: "Leg 2", startOffset: 2_000)
        _ = try store.applyAutomaticVehicleAssignment(tripID: first.id, vehicleID: honda.id, source: .bluetooth)
        _ = try store.applyAutomaticVehicleAssignment(tripID: second.id, vehicleID: honda.id, source: .bluetooth)

        let merged = try store.mergeTrips(ids: [first.id, second.id])
        XCTAssertEqual(merged.vehicleID, honda.id)
        XCTAssertEqual(merged.vehicleAssignmentSource, .bluetooth)
    }

    func testMergeTakesVehicleAndSourceFromLongestLegWithVehicle() throws {
        let (store, vehicles) = try makeStores()
        let honda = try vehicles.createVehicle(name: "Honda Odyssey")
        let toyota = try vehicles.createVehicle(name: "Toyota Sienna")
        let short = try makeTrip(store, destination: "Leg 1", miles: 5)
        let long = try makeTrip(store, destination: "Leg 2", miles: 20, startOffset: 2_000)
        _ = try store.assignVehicle(tripID: short.id, vehicleID: honda.id)
        _ = try store.applyAutomaticVehicleAssignment(tripID: long.id, vehicleID: toyota.id, source: .bluetooth)

        let merged = try store.mergeTrips(ids: [short.id, long.id])
        XCTAssertEqual(merged.vehicleID, toyota.id)
        XCTAssertEqual(merged.vehicleAssignmentSource, .bluetooth)
    }

    func testMergeSkipsLongerLegsWithoutVehicle() throws {
        let (store, vehicles) = try makeStores()
        let honda = try vehicles.createVehicle(name: "Honda Odyssey")
        let longest = try makeTrip(store, destination: "Leg 1", miles: 30)
        let short = try makeTrip(store, destination: "Leg 2", miles: 5, startOffset: 2_000)
        _ = try store.assignVehicle(tripID: short.id, vehicleID: honda.id)

        let merged = try store.mergeTrips(ids: [longest.id, short.id])
        XCTAssertEqual(merged.vehicleID, honda.id)
        XCTAssertEqual(merged.vehicleAssignmentSource, .manual)
    }

    func testReassignOdometerCheckpointsFromDeletedVehicle() throws {
        let store = try makeStore()
        let vehicle = UUID()
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_000_000), odometerMiles: 100, vehicleID: vehicle)
        )
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_100_000), odometerMiles: 200, vehicleID: nil)
        )

        let moved = try store.reassignOdometerCheckpoints(from: vehicle, to: nil)
        XCTAssertEqual(moved, 1)
        let unassigned = try store.fetchOdometerCheckpoints(vehicle: .unassigned)
        XCTAssertEqual(unassigned.map(\.odometerMiles).sorted(), [100, 200])
    }

    func testDeleteOdometerCheckpointsForVehicleLeavesOthersUntouched() throws {
        let store = try makeStore()
        let vehicle = UUID()
        // The deleted car's readings live in a different range than the primary's.
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_000_000), odometerMiles: 50_000, vehicleID: vehicle)
        )
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_100_000), odometerMiles: 60_000, vehicleID: vehicle)
        )
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_050_000), odometerMiles: 200, vehicleID: nil)
        )

        let deleted = try store.deleteOdometerCheckpoints(forVehicle: vehicle)
        XCTAssertEqual(deleted, 2)
        // The deleted car's readings are gone entirely — not folded into the
        // nil/primary bucket where they would corrupt the primary's interpolation.
        let unassigned = try store.fetchOdometerCheckpoints(vehicle: .unassigned)
        XCTAssertEqual(unassigned.map(\.odometerMiles), [200])
        XCTAssertEqual(try store.fetchOdometerCheckpoints().map(\.odometerMiles), [200])
    }

    func testReassignTripsFromDeletedVehicle() throws {
        let store = try makeStore()
        let vehicle = UUID()
        let trip = try makeTrip(store)
        _ = try store.assignVehicle(tripID: trip.id, vehicleID: vehicle)

        let moved = try store.reassignTrips(from: vehicle, to: nil)
        XCTAssertEqual(moved, 1)
        let refreshed = try store.fetchTrip(id: trip.id)
        XCTAssertNil(refreshed.vehicleID)
        XCTAssertNil(refreshed.vehicleAssignmentSource)
    }

    func testOdometerCheckpointVehicleRoundTrip() throws {
        let store = try makeStore()
        let vehicle = UUID()
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_000_000), odometerMiles: 100, vehicleID: vehicle)
        )
        _ = try store.addOdometerCheckpoint(
            OdometerCheckpoint(date: Date(timeIntervalSince1970: 1_700_100_000), odometerMiles: 200, vehicleID: nil)
        )
        let forVehicle = try store.fetchOdometerCheckpoints(vehicle: .vehicle(vehicle, includesUnassigned: false))
        XCTAssertEqual(forVehicle.map(\.odometerMiles), [100])
        let unassigned = try store.fetchOdometerCheckpoints(vehicle: .unassigned)
        XCTAssertEqual(unassigned.map(\.odometerMiles), [200])
    }

    func testDuplicateOdometerIdentityCountsOnceConvergesAndFailsClosedOnConflict() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let checkpoint = OdometerCheckpoint(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            odometerMiles: 10_000,
            note: "Quarter start"
        )
        _ = try store.addOdometerCheckpoint(checkpoint)
        let request = OdometerCheckpointEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", checkpoint.id as CVarArg)
        let stored = try XCTUnwrap(context.fetch(request).first)
        _ = try clone(stored, in: context)
        try context.save()

        XCTAssertEqual(try store.fetchOdometerCheckpoints(), [checkpoint])
        var updated = checkpoint
        updated.odometerMiles = 10_100
        _ = try store.addOdometerCheckpoint(updated)
        XCTAssertEqual(try context.count(for: request), 1)
        XCTAssertEqual(try store.fetchOdometerCheckpoints(), [updated])

        let current = try XCTUnwrap(context.fetch(request).first)
        let conflicting = try clone(current, in: context)
        conflicting.odometerMiles = 99_999
        try context.save()
        XCTAssertThrowsError(try store.fetchOdometerCheckpoints()) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidOdometer)
        }
        XCTAssertThrowsError(try store.addOdometerCheckpoint(updated)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidOdometer)
        }

        try store.deleteOdometerCheckpoint(id: checkpoint.id)
        XCTAssertEqual(try context.count(for: request), 0)
        XCTAssertTrue(try store.fetchOdometerCheckpoints().isEmpty)
    }

    private func clone<T: NSManagedObject>(_ source: T, in context: NSManagedObjectContext) throws -> T {
        let entityName = try XCTUnwrap(source.entity.name)
        let copy = try XCTUnwrap(NSEntityDescription.insertNewObject(
            forEntityName: entityName,
            into: context
        ) as? T)
        for attribute in source.entity.attributesByName.keys {
            copy.setValue(source.value(forKey: attribute), forKey: attribute)
        }
        return copy
    }
}

private final class VehicleTripChangeObserver: TripStoreChangeObserver {
    private(set) var lastChange: TripChangeSet?

    func tripStoreDidChange(_ change: TripChangeSet) {
        lastChange = change
    }
}
