import AppCore
import XCTest
@testable import MileageTracker

final class DriveRouteLabelFormatterTests: XCTestCase {
    func testSameCityUsesStreetAndNeighborhood() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "123",
                streetName: "Main St",
                neighborhood: "Mission District",
                city: "San Francisco",
                state: "CA",
                country: "United States"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "9",
                streetName: "Pine St",
                neighborhood: "SoMa",
                city: "San Francisco",
                state: "CA",
                country: "United States"
            )
        )

        XCTAssertEqual(
            DriveRouteLabelFormatter.label(for: trip),
            "123 Main St, Mission District → 9 Pine St, SoMa"
        )
    }

    func testDifferentCitiesInSameStateUseNeighborhoodAndCity() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Mission District",
                city: "San Francisco",
                state: "CA"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Downtown",
                city: "Oakland",
                state: "CA"
            )
        )

        XCTAssertEqual(
            DriveRouteLabelFormatter.label(for: trip),
            "Mission District, San Francisco → Downtown, Oakland"
        )
    }

    func testCrossStateUsesCityAndState() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Paulus Hook",
                city: "Jersey City",
                state: "NJ"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Financial District",
                city: "New York",
                state: "NY"
            )
        )

        XCTAssertEqual(
            DriveRouteLabelFormatter.label(for: trip),
            "Jersey City, NJ → New York, NY"
        )
    }

    func testCardLabelsNeverShowZipCodesOrTrailingCountry() {
        let trip = makeRouteTrip(
            startAddress: "123 Main St, Mission District, San Francisco, CA 94103, United States",
            endAddress: "9 Pine St, SoMa, San Francisco, CA 94105, United States"
        )

        let label = DriveRouteLabelFormatter.label(for: trip)

        XCTAssertEqual(label, "123 Main St, Mission District → 9 Pine St, SoMa")
        XCTAssertFalse(label.contains("94103"))
        XCTAssertFalse(label.contains("94105"))
        XCTAssertFalse(label.contains("United States"))
    }

    func testMissingNeighborhoodFallsBackToCity() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "123",
                streetName: "Main St",
                city: "San Francisco",
                state: "CA"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "9",
                streetName: "Pine St",
                city: "San Francisco",
                state: "CA"
            )
        )

        XCTAssertEqual(
            DriveRouteLabelFormatter.label(for: trip),
            "123 Main St, San Francisco → 9 Pine St, San Francisco"
        )
    }

    func testMissingStreetFallsBackToNeighborhoodAndCity() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Mission District",
                city: "San Francisco",
                state: "CA"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                neighborhood: "SoMa",
                city: "San Francisco",
                state: "CA"
            )
        )

        XCTAssertEqual(
            DriveRouteLabelFormatter.label(for: trip),
            "Mission District, San Francisco → SoMa, San Francisco"
        )
    }

    func testIdenticalEndpointLabelsExpandOnlyWhenNeeded() {
        let trip = makeRouteTrip(
            startAddress: "Gate A, Terminal, Queens, NY 11371, United States",
            endAddress: "Gate B, Terminal, Queens, NY 11371, United States",
            startAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Terminal",
                city: "Queens",
                state: "NY"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Terminal",
                city: "Queens",
                state: "NY"
            )
        )

        XCTAssertEqual(
            DriveRouteLabelFormatter.label(for: trip),
            "Gate A, Terminal, Queens, NY → Gate B, Terminal, Queens, NY"
        )
    }

    // MARK: Compact labels (archive rows)

    func testCompactSameCityUsesLeadingComponentOnly() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "123",
                streetName: "Main St",
                neighborhood: "Mission District",
                city: "San Francisco",
                state: "CA",
                country: "United States"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "9",
                streetName: "Pine St",
                neighborhood: "SoMa",
                city: "San Francisco",
                state: "CA",
                country: "United States"
            )
        )

        let endpoints = DriveRouteLabelFormatter.compactEndpoints(for: trip)
        XCTAssertEqual(endpoints.origin, "123 Main St")
        XCTAssertEqual(endpoints.destination, "9 Pine St")
    }

    func testCompactCrossStateUsesCityOnly() {
        let trip = makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Paulus Hook",
                city: "Jersey City",
                state: "NJ"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Financial District",
                city: "New York",
                state: "NY"
            )
        )

        let endpoints = DriveRouteLabelFormatter.compactEndpoints(for: trip)
        XCTAssertEqual(endpoints.origin, "Jersey City")
        XCTAssertEqual(endpoints.destination, "New York")
    }

    func testCompactCollidingLeadingComponentsEscalateToStandardLabels() {
        // Both endpoints lead with "Terminal": the one-part forms collide, so
        // the compact call must fall back to the standard chain (which itself
        // escalates to the raw-address disambiguation here).
        let trip = makeRouteTrip(
            startAddress: "Gate A, Terminal, Queens, NY 11371, United States",
            endAddress: "Gate B, Terminal, Queens, NY 11371, United States",
            startAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Terminal",
                city: "Queens",
                state: "NY"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                neighborhood: "Terminal",
                city: "Queens",
                state: "NY"
            )
        )

        let endpoints = DriveRouteLabelFormatter.compactEndpoints(for: trip)
        XCTAssertEqual(endpoints.origin, "Gate A, Terminal, Queens, NY")
        XCTAssertEqual(endpoints.destination, "Gate B, Terminal, Queens, NY")
    }

    func testCompactFallsBackToRawAddressWhenUnstructured() {
        let trip = makeRouteTrip(
            startAddress: "Home, Columbus, OH 43215, United States",
            endAddress: "Client, Columbus, OH 43215, United States"
        )

        let endpoints = DriveRouteLabelFormatter.compactEndpoints(for: trip)
        XCTAssertEqual(endpoints.origin, "Home")
        XCTAssertEqual(endpoints.destination, "Client")
    }

    /// The same saved place has to render the same way whichever city the
    /// other end of the drive is in. Before `placeName`, the leading component
    /// only led for same-city drives: a drive out to the arboretum rendered
    /// "7770 Jacksontown Rd SE" while a drive across town to the same address
    /// rendered "The Dawes Arboretum".
    func testCompactLeadsWithThePlaceNameAcrossACityLine() {
        let sameCity = DriveRouteLabelFormatter.compactEndpoints(for: makeRouteTrip(
            startAddress: "400 W Rich St, Columbus, OH 43215, United States",
            endAddress: "North Market, 59 Spruce St, Columbus, OH 43215, United States"
        ))
        XCTAssertEqual(sameCity.origin, "400 W Rich St")
        XCTAssertEqual(sameCity.destination, "North Market")

        let acrossCityLine = DriveRouteLabelFormatter.compactEndpoints(for: makeRouteTrip(
            startAddress: "400 W Rich St, Columbus, OH 43215, United States",
            endAddress: "The Dawes Arboretum, 7770 Jacksontown Rd SE, Newark, OH 43056, United States"
        ))
        XCTAssertEqual(acrossCityLine.origin, "400 W Rich St")
        XCTAssertEqual(acrossCityLine.destination, "The Dawes Arboretum")
    }

    /// Structured components have no place name in them, so they must keep the
    /// style-driven neighborhood/city labels this type has always produced.
    func testStructuredComponentsAreUnaffectedByThePlaceName() {
        let endpoints = DriveRouteLabelFormatter.compactEndpoints(for: makeRouteTrip(
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "400",
                streetName: "W Rich St",
                neighborhood: "Franklinton",
                city: "Columbus",
                state: "OH"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "7770",
                streetName: "Jacksontown Rd SE",
                neighborhood: "Jacksontown",
                city: "Newark",
                state: "OH"
            )
        ))
        XCTAssertEqual(endpoints.origin, "Franklinton")
        XCTAssertEqual(endpoints.destination, "Jacksontown")
    }

    private func makeRouteTrip(
        startAddress: String? = "Origin",
        endAddress: String? = "Destination",
        startAddressComponents: TripEndpointAddressComponents? = nil,
        endAddressComponents: TripEndpointAddressComponents? = nil
    ) -> TripSummary {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return TripSummary(
            id: UUID(),
            createdAt: start,
            updatedAt: start,
            captureSource: "manual",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: Coordinate(latitude: 37.7599, longitude: -122.4148),
            endCoordinate: Coordinate(latitude: 37.7816, longitude: -122.4043),
            startAddress: startAddress,
            endAddress: endAddress,
            startAddressComponents: startAddressComponents,
            endAddressComponents: endAddressComponents,
            distanceMeters: DistanceConversion.meters(fromMiles: 3),
            routePolyline: nil,
            classification: nil,
            reviewStatus: .needsReview,
            businessPurpose: nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
    }
}
