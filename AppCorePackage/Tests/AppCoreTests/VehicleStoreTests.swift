import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class VehicleStoreTests: XCTestCase {
    private func makeStore() throws -> VehicleStore {
        let persistence = try PersistenceController(inMemory: true)
        return VehicleStore(context: persistence.container.viewContext)
    }

    func testCreateFirstVehicleSetsPrimary() throws {
        let store = try makeStore()
        XCTAssertNil(try store.primaryVehicleID())
        let honda = try store.createVehicle(name: "Honda Odyssey")
        XCTAssertEqual(try store.primaryVehicleID(), honda.id)

        // A second vehicle does not steal primary.
        let ford = try store.createVehicle(name: "Ford F-150")
        XCTAssertEqual(try store.primaryVehicleID(), honda.id)
        XCTAssertNotEqual(ford.id, honda.id)
    }

    func testCreateRejectsBlankName() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.createVehicle(name: "   "))
    }

    func testFetchExcludesArchivedByDefault() throws {
        let store = try makeStore()
        let honda = try store.createVehicle(name: "Honda Odyssey")
        _ = try store.createVehicle(name: "Ford F-150")
        _ = try store.setArchived(id: honda.id, archived: true)

        let active = try store.fetchVehicles()
        XCTAssertEqual(active.map(\.name), ["Ford F-150"])
        XCTAssertEqual(try store.fetchVehicles(includeArchived: true).count, 2)
    }

    func testArchivingPrimaryHandsOffToNextActive() throws {
        let store = try makeStore()
        let honda = try store.createVehicle(name: "Honda Odyssey")
        let ford = try store.createVehicle(name: "Ford F-150")
        _ = try store.setArchived(id: honda.id, archived: true)
        XCTAssertEqual(try store.primaryVehicleID(), ford.id)
    }

    func testPrimaryValidationAfterDelete() throws {
        let store = try makeStore()
        let honda = try store.createVehicle(name: "Honda Odyssey")
        try store.deleteVehicle(id: honda.id)
        XCTAssertNil(try store.primaryVehicleID())
        XCTAssertTrue(try store.fetchVehicles().isEmpty)
    }

    func testRenameAndReorder() throws {
        let store = try makeStore()
        let a = try store.createVehicle(name: "A")
        let b = try store.createVehicle(name: "B")
        _ = try store.renameVehicle(id: a.id, name: "Alpha")
        try store.setSortOrder(ids: [b.id, a.id])
        let names = try store.fetchVehicles().map(\.name)
        XCTAssertEqual(names, ["B", "Alpha"])
    }

    func testDuplicateVehicleIdentityReadsNewestAndMutationsCollapseEveryCopy() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = VehicleStore(context: context)
        let original = try store.createVehicle(name: "Original")
        let duplicate = VehicleEntity.insert(into: context)
        duplicate.id = original.id
        duplicate.name = "Cloud Newer"
        duplicate.createdAt = original.createdAt.addingTimeInterval(1)
        duplicate.updatedAt = original.createdAt.addingTimeInterval(60)
        duplicate.sortOrder = Int64(original.sortOrder)
        duplicate.isArchived = true
        try context.save()

        XCTAssertTrue(try store.fetchVehicles().isEmpty)
        XCTAssertEqual(
            try store.fetchVehicles(includeArchived: true).map(\.name),
            ["Cloud Newer"]
        )
        XCTAssertNil(try store.primaryVehicleID())

        _ = try store.setArchived(id: original.id, archived: false)
        XCTAssertEqual(try countVehicles(in: context), 1)
        XCTAssertEqual(try store.fetchVehicles().map(\.name), ["Cloud Newer"])
        XCTAssertEqual(try store.primaryVehicleID(), original.id)

        let renamed = try store.renameVehicle(id: original.id, name: "Converged")
        XCTAssertEqual(renamed.name, "Converged")
        XCTAssertEqual(try countVehicles(in: context), 1)
        XCTAssertEqual(try store.fetchVehicles().map(\.name), ["Converged"])

        let duplicateAfterRename = VehicleEntity.insert(into: context)
        duplicateAfterRename.id = original.id
        duplicateAfterRename.name = "Older copy"
        duplicateAfterRename.createdAt = original.createdAt
        duplicateAfterRename.updatedAt = original.createdAt
        duplicateAfterRename.sortOrder = 0
        duplicateAfterRename.isArchived = false
        try context.save()

        try store.deleteVehicle(id: original.id)
        XCTAssertEqual(try countVehicles(in: context), 0)
        XCTAssertNil(try store.primaryVehicleID())
    }

    func testAtomicVehicleRemovalUpdatesEveryAssociatedRecordAndPrimary() throws {
        let fixture = try makeRemovalFixture()

        let result = try fixture.vehicles.deleteVehicleAndAssociatedData(id: fixture.removedVehicle.id)

        XCTAssertEqual(result.vehicleID, fixture.removedVehicle.id)
        XCTAssertEqual(result.reassignedTripIDs, [fixture.trip.id])
        XCTAssertEqual(result.deletedOdometerCheckpointCount, 1)
        XCTAssertEqual(result.unlinkedBluetoothHintCount, 1)
        XCTAssertEqual(result.primaryVehicleID, fixture.remainingVehicle.id)
        XCTAssertEqual(try fixture.vehicles.fetchVehicles().map(\.id), [fixture.remainingVehicle.id])
        XCTAssertEqual(try fixture.vehicles.primaryVehicleID(), fixture.remainingVehicle.id)
        XCTAssertNil(try fixture.trips.fetchTrip(id: fixture.trip.id).vehicleID)
        XCTAssertTrue(try fixture.trips.fetchOdometerCheckpoints().isEmpty)
        XCTAssertNil(try XCTUnwrap(fixture.bluetooth.fetchHints().first).vehicleID)
    }

    func testAtomicVehicleRemovalRollsBackEverySideEffectOnFailure() throws {
        let fixture = try makeRemovalFixture()

        XCTAssertThrowsError(try fixture.vehicles.deleteVehicleAndAssociatedData(
            id: fixture.removedVehicle.id,
            beforeSave: { throw VehicleRemovalTestError.expected }
        )) { error in
            XCTAssertEqual(error as? VehicleRemovalTestError, .expected)
        }

        XCTAssertEqual(
            Set(try fixture.vehicles.fetchVehicles().map(\.id)),
            [fixture.removedVehicle.id, fixture.remainingVehicle.id]
        )
        XCTAssertEqual(try fixture.vehicles.primaryVehicleID(), fixture.removedVehicle.id)
        XCTAssertEqual(try fixture.trips.fetchTrip(id: fixture.trip.id).vehicleID, fixture.removedVehicle.id)
        XCTAssertEqual(try fixture.trips.fetchOdometerCheckpoints().map(\.id), [fixture.odometer.id])
        XCTAssertEqual(try XCTUnwrap(fixture.bluetooth.fetchHints().first).vehicleID, fixture.removedVehicle.id)
    }

    private func countVehicles(in context: NSManagedObjectContext) throws -> Int {
        try context.count(for: VehicleEntity.fetchRequest())
    }

    private func makeRemovalFixture() throws -> VehicleRemovalFixture {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let trips = TripStore(context: context)
        let bluetooth = BluetoothDriveHintStore(context: context)
        let removedVehicle = try vehicles.createVehicle(name: "Primary")
        let remainingVehicle = try vehicles.createVehicle(name: "Remaining")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try trips.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_200),
            distanceMeters: 4_000,
            vehicleID: removedVehicle.id
        ))
        let odometer = OdometerCheckpoint(
            date: start,
            odometerMiles: 42_000,
            vehicleID: removedVehicle.id
        )
        _ = try trips.addOdometerCheckpoint(odometer)
        let observation = try bluetooth.recordObservation(
            identifier: "atomic-removal-car",
            displayName: "Primary Car",
            source: .audioRoute,
            observedAt: start
        )
        _ = try bluetooth.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: removedVehicle.id
        )
        return VehicleRemovalFixture(
            vehicles: vehicles,
            trips: trips,
            bluetooth: bluetooth,
            removedVehicle: removedVehicle,
            remainingVehicle: remainingVehicle,
            trip: trip,
            odometer: odometer
        )
    }
}

private struct VehicleRemovalFixture {
    var vehicles: VehicleStore
    var trips: TripStore
    var bluetooth: BluetoothDriveHintStore
    var removedVehicle: Vehicle
    var remainingVehicle: Vehicle
    var trip: TripSummary
    var odometer: OdometerCheckpoint
}

private enum VehicleRemovalTestError: Error, Equatable {
    case expected
}
