import XCTest
@testable import AppCore

final class ReportOdometerPolicyTests: XCTestCase {
    func testAllVehiclesFilterUsesOnlyTheSoleActiveVehicleAndLegacyReadings() {
        let activeID = UUID()

        XCTAssertEqual(
            ReportOdometerPolicy.allVehiclesFilter(activeVehicleIDs: [activeID]),
            .vehicle(activeID, includesUnassigned: true)
        )
    }

    func testAllVehiclesFilterExcludesDanglingReadingsAndSuppressesMixedVehicles() {
        XCTAssertEqual(
            ReportOdometerPolicy.allVehiclesFilter(activeVehicleIDs: []),
            .unassigned
        )
        XCTAssertNil(ReportOdometerPolicy.allVehiclesFilter(
            activeVehicleIDs: [UUID(), UUID()]
        ))
    }

    @MainActor
    func testSoleActiveVehicleFilterExcludesArchivedVehicleReadings() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let trips = TripStore(context: context)
        let active = try vehicles.createVehicle(name: "Active")
        let archived = try vehicles.createVehicle(name: "Archived")
        _ = try vehicles.setArchived(id: archived.id, archived: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let activeReading = OdometerCheckpoint(
            date: date,
            odometerMiles: 10_000,
            vehicleID: active.id
        )
        let legacyReading = OdometerCheckpoint(
            date: date.addingTimeInterval(1),
            odometerMiles: 10_001,
            vehicleID: nil
        )
        let archivedReading = OdometerCheckpoint(
            date: date.addingTimeInterval(2),
            odometerMiles: 50_000,
            vehicleID: archived.id
        )
        _ = try trips.addOdometerCheckpoint(activeReading)
        _ = try trips.addOdometerCheckpoint(legacyReading)
        _ = try trips.addOdometerCheckpoint(archivedReading)
        let activeVehicles = try vehicles.fetchVehicles()
        let filter = try XCTUnwrap(ReportOdometerPolicy.allVehiclesFilter(
            activeVehicleIDs: activeVehicles.map(\.id)
        ))

        XCTAssertEqual(
            Set(try trips.fetchOdometerCheckpoints(vehicle: filter).map(\.id)),
            [activeReading.id, legacyReading.id]
        )
    }
}
