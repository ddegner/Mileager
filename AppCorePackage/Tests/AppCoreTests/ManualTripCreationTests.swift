import CoreData
import XCTest
@testable import AppCore

@MainActor
final class ManualTripCreationTests: XCTestCase {
    func testCreatesTripRouteVehicleAndFeesInOneChange() throws {
        let (store, context) = try makeStore()
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Work Van")
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_500_000)
        let origin = Coordinate(latitude: 40.7127, longitude: -74.0134)
        let destination = Coordinate(latitude: 40.7527, longitude: -73.9772)
        let route = EncodedPolyline.encode([origin, destination])
        let fees = [
            TripFee(
                tripID: nil,
                category: .toll,
                amount: 8.25,
                occurredAt: start.addingTimeInterval(600),
                label: "Tunnel"
            ),
            TripFee(
                tripID: id,
                category: .parking,
                amount: 22,
                occurredAt: start.addingTimeInterval(1_200),
                label: "Client garage",
                source: .preset
            )
        ]
        let observer = ManualTripCreationObserver()
        store.changeObserver = observer

        let result = try store.createManualTripWithSnapshot(
            ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                startCoordinate: origin,
                endCoordinate: destination,
                startAddress: "World Trade Center",
                endAddress: "Grand Central Terminal",
                distanceMeters: 7_250,
                routePolyline: route,
                manualDistanceOverrideMeters: 7_500,
                classification: .business,
                businessPurpose: "Client meeting",
                notes: "Bring contract",
                vehicleID: vehicle.id
            ),
            fees: fees,
            id: id
        )
        let trip = result.trip

        XCTAssertEqual(trip.id, id)
        XCTAssertEqual(trip.routePolyline, route)
        XCTAssertEqual(trip.manualDistanceOverrideMeters, 7_500)
        XCTAssertEqual(trip.vehicleID, vehicle.id)
        XCTAssertEqual(trip.tollsAmount, 8.25, accuracy: 0.001)
        XCTAssertEqual(trip.parkingAmount, 22, accuracy: 0.001)
        XCTAssertEqual(try store.fetchFees(tripID: id).map(\.tripID), [id, id])
        XCTAssertEqual(result.snapshot, try store.editableSnapshot(tripID: id))
        XCTAssertEqual(observer.changes.count, 1)
        XCTAssertEqual(observer.changes[0].upserted.map(\.id), [id])
    }

    func testInvalidFeeRollsBackTripAndAllFees() throws {
        let (store, _) = try makeStore()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_600_000)
        let observer = ManualTripCreationObserver()
        store.changeObserver = observer

        XCTAssertThrowsError(try store.createManualTrip(
            ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                startAddress: "Origin",
                endAddress: "Destination",
                distanceMeters: 5_000
            ),
            fees: [TripFee(
                tripID: id,
                category: .parking,
                amount: -1,
                occurredAt: start
            )],
            id: id
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidAmount)
        }

        XCTAssertNil(try store.fetchTripIfExists(id: id))
        XCTAssertTrue(try store.fetchFees(includeUnlinked: true).isEmpty)
        XCTAssertTrue(observer.changes.isEmpty)
    }

    func testRejectsInvalidVehiclePurposeRouteAndCrossTripFee() throws {
        let (store, _) = try makeStore()
        let existing = try store.createManualTrip(baseInput())
        let existingFee = try store.addFee(TripFee(
            tripID: existing.id,
            category: .toll,
            amount: 4,
            occurredAt: existing.startDate
        ))
        let start = existing.startDate.addingTimeInterval(86_400)

        XCTAssertThrowsError(try store.createManualTrip(
            ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                distanceMeters: 5_000,
                classification: .personal,
                businessPurpose: "Client meeting"
            ),
            fees: []
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidBusinessPurpose)
        }

        XCTAssertThrowsError(try store.createManualTrip(
            ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                distanceMeters: 5_000,
                vehicleID: UUID()
            ),
            fees: []
        )) { error in
            XCTAssertEqual(error as? VehicleStoreError, .vehicleNotFound)
        }

        XCTAssertThrowsError(try store.createManualTrip(
            ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                distanceMeters: 5_000,
                routePolyline: EncodedPolyline.encode([
                    Coordinate(latitude: 40.7, longitude: -74),
                    Coordinate(latitude: 40.8, longitude: -73.9)
                ])
            ),
            fees: []
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidRoute)
        }

        XCTAssertThrowsError(try store.createManualTrip(
            ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                distanceMeters: 5_000
            ),
            fees: [existingFee]
        )) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }
    }

    private func makeStore() throws -> (TripStore, NSManagedObjectContext) {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        return (TripStore(context: context), context)
    }

    private func baseInput() -> ManualTripInput {
        let start = Date(timeIntervalSince1970: 1_800_700_000)
        return ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMeters: 5_000
        )
    }
}

private final class ManualTripCreationObserver: TripStoreChangeObserver {
    private(set) var changes: [TripChangeSet] = []

    func tripStoreDidChange(_ change: TripChangeSet) {
        changes.append(change)
    }
}
