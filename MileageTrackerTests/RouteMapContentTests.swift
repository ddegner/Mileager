import AppCore
import CoreLocation
import XCTest
@testable import MileageTracker

final class RouteMapContentTests: XCTestCase {
    func testSingleEndpointPreviewShowsOnlyItsPinAndFitsTheMap() throws {
        let place = Coordinate(latitude: 42.355, longitude: -71.066)
        let origin = try XCTUnwrap(RouteMapContent(origin: place, destination: nil))
        XCTAssertEqual(origin.coordinates.count, 1)
        XCTAssertEqual(origin.startMapCoordinate?.latitude, place.latitude)
        XCTAssertNil(origin.endMapCoordinate)
        XCTAssertTrue(origin.segments.isEmpty)
        XCTAssertNotNil(origin.visibleMapRect())

        let destination = try XCTUnwrap(RouteMapContent(origin: nil, destination: place))
        XCTAssertNil(destination.startMapCoordinate)
        XCTAssertEqual(destination.endMapCoordinate?.longitude, place.longitude)
        XCTAssertEqual(destination.coordinates.count, 1)
        XCTAssertNotNil(destination.visibleMapRect())
        XCTAssertNil(RouteMapContent(origin: nil, destination: nil))
    }

    func testEndpointPreviewDoesNotDrawAnUncalculatedRoute() throws {
        let origin = Coordinate(latitude: 40.71, longitude: -74.01)
        let destination = Coordinate(latitude: 40.75, longitude: -73.98)
        let preview = try XCTUnwrap(RouteMapContent(origin: origin, destination: destination))
        XCTAssertEqual(preview.coordinates.count, 2)
        XCTAssertTrue(preview.segments.isEmpty)
        XCTAssertNil(preview.routePolyline)

        let trip = makeTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000), miles: 5,
            startCoordinate: origin, endCoordinate: destination
        )
        let route = try XCTUnwrap(RouteMapContent(trip: trip))
        XCTAssertNotEqual(preview, route)
        XCTAssertNotEqual(preview.mapFingerprint, route.mapFingerprint)
    }

    @MainActor
    func testEndpointPreviewPreservesUntouchedEndpointAndDropsStaleSelection() throws {
        var trip = makeTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000), miles: 5,
            startCoordinate: Coordinate(latitude: 40.71, longitude: -74.01),
            endCoordinate: Coordinate(latitude: 40.75, longitude: -73.98)
        )
        trip.startAddress = "Old origin"
        trip.endAddress = "Stored destination"
        let selection = TripEndpointSearchResult(
            title: "New origin", coordinate: CLLocationCoordinate2D(latitude: 42.355, longitude: -71.066)
        )
        let selected = try XCTUnwrap(TripRouteEditing.endpointMapContent(
            origin: selection.endpointText, destination: "Stored destination",
            originResult: selection, destinationResult: nil, storedTrip: trip
        ))
        XCTAssertEqual(selected.startMapCoordinate?.latitude, selection.coordinate.latitude)
        XCTAssertEqual(selected.endMapCoordinate?.latitude, trip.endCoordinate?.latitude)
        XCTAssertTrue(selected.segments.isEmpty)

        let edited = try XCTUnwrap(TripRouteEditing.endpointMapContent(
            origin: "Typing another origin", destination: "Stored destination",
            originResult: selection, destinationResult: nil, storedTrip: trip
        ))
        XCTAssertNil(edited.startMapCoordinate)
        XCTAssertEqual(edited.coordinates.count, 1)
        XCTAssertNil(TripRouteEditing.endpointMapContent(
            origin: "Typing another origin", destination: "",
            originResult: selection, destinationResult: nil, storedTrip: trip
        ))
    }

    @MainActor
    func testRouteLookupReusesOnlyUnchangedStoredEndpointCoordinates() {
        var trip = makeTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000), miles: 1.35,
            startCoordinate: Coordinate(latitude: 42.355, longitude: -71.066),
            endCoordinate: Coordinate(latitude: 42.367, longitude: -71.071)
        )
        trip.startAddress = "Boston Common, 139 Tremont St, Boston, MA 02111"
        trip.endAddress = "Museum of Science, 1 Science Park, Boston, MA 02114"
        let changedOrigin = TripEndpointSearchResult(
            title: "Boston Public Library - West Roxbury Branch",
            coordinate: CLLocationCoordinate2D(latitude: 42.286, longitude: -71.155)
        )
        let origin = TripRouteEditing.manualRouteEndpoint(
            for: .origin, text: changedOrigin.endpointText,
            originResult: changedOrigin, destinationResult: nil, storedTrip: trip
        )
        let destination = TripRouteEditing.manualRouteEndpoint(
            for: .destination, text: trip.endAddress!,
            originResult: changedOrigin, destinationResult: nil, storedTrip: trip
        )
        XCTAssertEqual(origin.coordinate, Coordinate(changedOrigin.coordinate))
        XCTAssertEqual(destination.coordinate, trip.endCoordinate)
        XCTAssertEqual(TripRouteEditing.manualRouteEndpoint(
            for: .origin, text: trip.startAddress!,
            originResult: nil, destinationResult: nil, storedTrip: trip
        ).coordinate, trip.startCoordinate)
        XCTAssertNil(TripRouteEditing.manualRouteEndpoint(
            for: .destination, text: "Typing a different destination",
            originResult: changedOrigin, destinationResult: nil, storedTrip: trip
        ).coordinate)
    }

    func testLegContentPrependsIncomingConnectorGeometry() throws {
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let connectorStart = Coordinate(latitude: 40.000, longitude: -74.000)
        let legStart = Coordinate(latitude: 40.010, longitude: -73.990)
        let legEnd = Coordinate(latitude: 40.020, longitude: -73.980)
        let legID = UUID()
        let connector = TripLegConnector(
            fromLegID: UUID(),
            toLegID: legID,
            startCoordinate: connectorStart,
            endCoordinate: legStart,
            distanceMeters: 1_000,
            routePolyline: EncodedPolyline.encode([connectorStart, legStart])
        )
        let leg = TripLeg(
            id: legID,
            captureSource: "manual",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_800),
            startCoordinate: legStart,
            endCoordinate: legEnd,
            startAddress: "Leg origin",
            endAddress: "Leg destination",
            distanceMeters: 2_000,
            routePolyline: EncodedPolyline.encode([legStart, legEnd])
        )

        let content = try XCTUnwrap(RouteMapContent(
            leg: TripDisplayLeg(leg: leg, incomingConnector: connector)
        ))

        XCTAssertEqual(content.segments.count, 2)
        XCTAssertEqual(content.segments[0].first?.latitude, connectorStart.latitude)
        XCTAssertEqual(content.segments[0].last?.latitude, legStart.latitude)
        XCTAssertEqual(content.segments[1].first?.latitude, legStart.latitude)
        XCTAssertEqual(content.segments[1].last?.latitude, legEnd.latitude)
        XCTAssertEqual(content.startMapCoordinate?.latitude, connectorStart.latitude)
        XCTAssertEqual(content.endMapCoordinate?.latitude, legEnd.latitude)
    }

    func testMergedTripDoesNotResurrectLegGeometryWhenTopLevelRouteWasCleared() throws {
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let firstStart = Coordinate(latitude: 40.000, longitude: -74.000)
        let firstEnd = Coordinate(latitude: 40.010, longitude: -73.990)
        let secondStart = Coordinate(latitude: 41.000, longitude: -75.000)
        let secondEnd = Coordinate(latitude: 41.010, longitude: -74.990)
        var trip = makeTrip(
            startDate: startDate,
            miles: 10,
            startCoordinate: firstStart,
            endCoordinate: secondEnd
        )
        trip.captureSource = "merged"
        trip.routePolyline = nil
        trip.legs = [
            TripLeg(
                captureSource: "manual",
                startDate: startDate,
                endDate: startDate.addingTimeInterval(1_800),
                startCoordinate: firstStart,
                endCoordinate: firstEnd,
                startAddress: "First origin",
                endAddress: "First destination",
                distanceMeters: 4_000,
                routePolyline: EncodedPolyline.encode([firstStart, firstEnd])
            ),
            TripLeg(
                captureSource: "manual",
                startDate: startDate.addingTimeInterval(3_600),
                endDate: startDate.addingTimeInterval(5_400),
                startCoordinate: secondStart,
                endCoordinate: secondEnd,
                startAddress: "Second origin",
                endAddress: "Second destination",
                distanceMeters: 6_000,
                routePolyline: EncodedPolyline.encode([secondStart, secondEnd])
            )
        ]

        let content = try XCTUnwrap(RouteMapContent(trip: trip))

        XCTAssertNil(content.routePolyline)
        XCTAssertEqual(content.segments.count, 1)
        XCTAssertEqual(content.segments[0].count, 2)
        XCTAssertEqual(content.segments[0][0].latitude, firstStart.latitude)
        XCTAssertEqual(content.segments[0][0].longitude, firstStart.longitude)
        XCTAssertEqual(content.segments[0][1].latitude, secondEnd.latitude)
        XCTAssertEqual(content.segments[0][1].longitude, secondEnd.longitude)

        var incomplete = trip
        incomplete.startCoordinate = nil
        incomplete.legs[0].startCoordinate = nil
        XCTAssertFalse(incomplete.stops.isEmpty)
        XCTAssertNil(RouteMapContent(trip: incomplete))
    }

    func testIncompleteEndpointPairDoesNotRenderOneCoordinateAsAWholeRoute() {
        let trip = makeTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            miles: 5,
            startCoordinate: Coordinate(latitude: 40, longitude: -74)
        )

        XCTAssertNil(RouteMapContent(trip: trip))
    }
}
