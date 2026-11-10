import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class TripVehicleFilterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testAllMatchesEverything() {
        let filter = TripVehicleFilter.all
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: UUID()), primaryVehicleID: nil))
        XCTAssertTrue(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: nil), primaryVehicleID: nil))
    }

    func testVehicleMatchesExactID() {
        let vehicle = UUID()
        let other = UUID()
        let filter = TripVehicleFilter.vehicle(vehicle)
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: vehicle), primaryVehicleID: nil))
        XCTAssertFalse(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: other), primaryVehicleID: nil))
    }

    func testPrimaryVehicleAbsorbsUnassignedTrips() {
        let primary = UUID()
        let filter = TripVehicleFilter.vehicle(primary)
        // A nil-vehicle (implicit default) trip passes when the primary is selected.
        XCTAssertTrue(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: nil), primaryVehicleID: primary))
        // But not when a non-primary vehicle is selected.
        let nonPrimary = TripVehicleFilter.vehicle(UUID())
        XCTAssertFalse(nonPrimary.matches(makeTrip(startDate: start, miles: 1, vehicleID: nil), primaryVehicleID: primary))
    }

    func testUnassignedMatchesOnlyNilVehicleWithoutPrimary() {
        let filter = TripVehicleFilter.unassigned
        XCTAssertTrue(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: nil), primaryVehicleID: nil))
        // When a primary exists, nil-vehicle trips belong to it, not "No Vehicle".
        XCTAssertFalse(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: nil), primaryVehicleID: UUID()))
        XCTAssertFalse(filter.matches(makeTrip(startDate: start, miles: 1, vehicleID: UUID()), primaryVehicleID: nil))
    }

    func testTitlesResolveFromVehicleList() {
        let vehicle = Vehicle(name: "Honda Odyssey")
        XCTAssertEqual(TripVehicleFilter.all.title(vehicles: [vehicle]), "All Vehicles")
        XCTAssertEqual(TripVehicleFilter.unassigned.title(vehicles: [vehicle]), "No Vehicle")
        XCTAssertEqual(TripVehicleFilter.vehicle(vehicle.id).title(vehicles: [vehicle]), "Honda Odyssey")
    }
}
