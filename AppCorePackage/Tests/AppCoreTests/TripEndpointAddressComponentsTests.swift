import XCTest
@testable import AppCore

final class TripEndpointAddressComponentsTests: XCTestCase {
    func testUpdateAddressesPersistsStructuredComponentsAndManualEditClearsThem() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            startAddress: "Origin",
            endAddress: "Destination",
            distanceMeters: DistanceConversion.meters(fromMiles: 3)
        ))
        let origin = TripEndpointAddressComponents(
            streetNumber: "123",
            streetName: "Main St",
            neighborhood: "Mission District",
            city: "San Francisco",
            state: "CA",
            country: "United States",
            countryCode: "US"
        )
        let destination = TripEndpointAddressComponents(
            streetNumber: "9",
            streetName: "Pine St",
            neighborhood: "SoMa",
            city: "San Francisco",
            state: "CA",
            country: "United States",
            countryCode: "US"
        )

        let geocoded = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "123 Main St, Mission District, San Francisco, CA 94103, United States",
            endAddress: "9 Pine St, SoMa, San Francisco, CA 94105, United States",
            startAddressComponents: origin,
            endAddressComponents: destination
        )

        XCTAssertEqual(geocoded.startAddressComponents, origin)
        XCTAssertEqual(geocoded.endAddressComponents, destination)
        let fetched = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(fetched.startAddressComponents, origin)
        XCTAssertEqual(fetched.endAddressComponents, destination)

        let edited = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "Manual origin",
            endAddress: "Manual destination"
        )

        XCTAssertNil(edited.startAddressComponents)
        XCTAssertNil(edited.endAddressComponents)
    }

    func testMergeKeepsFirstStartAndLastEndComponents() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "First origin",
            endAddress: "First destination",
            distanceMeters: DistanceConversion.meters(fromMiles: 2)
        ))
        let second = try store.createManualTrip(ManualTripInput(
            startDate: start.addingTimeInterval(2_400),
            endDate: start.addingTimeInterval(4_200),
            startAddress: "Second origin",
            endAddress: "Second destination",
            distanceMeters: DistanceConversion.meters(fromMiles: 4)
        ))
        let firstOrigin = TripEndpointAddressComponents(
            streetNumber: "1",
            streetName: "Hudson St",
            neighborhood: "Paulus Hook",
            city: "Jersey City",
            state: "NJ"
        )
        let secondDestination = TripEndpointAddressComponents(
            streetNumber: "10",
            streetName: "Broadway",
            neighborhood: "Financial District",
            city: "New York",
            state: "NY"
        )
        _ = try store.updateAddresses(
            tripID: first.id,
            startAddress: "1 Hudson St, Paulus Hook, Jersey City, NJ",
            endAddress: "First destination",
            startAddressComponents: firstOrigin
        )
        _ = try store.updateAddresses(
            tripID: second.id,
            startAddress: "Second origin",
            endAddress: "10 Broadway, Financial District, New York, NY",
            endAddressComponents: secondDestination
        )

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(merged.startAddressComponents, firstOrigin)
        XCTAssertEqual(merged.endAddressComponents, secondDestination)
    }
}
