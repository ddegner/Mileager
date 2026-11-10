import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class ManualRouteLookupControllerTests: XCTestCase {
    func testScheduleResolvesAndAppliesCurrentRoute() async throws {
        let controller = ManualRouteLookupController(debounceNanoseconds: 0)
        let key = try XCTUnwrap(ManualRouteLookupKey(origin: " Office ", destination: " Client "))
        let route = ResolvedManualRoute(
            startCoordinate: Coordinate(latitude: 40, longitude: -73),
            endCoordinate: Coordinate(latitude: 40.01, longitude: -73),
            routePolyline: "encoded",
            distanceMeters: 1_200
        )
        let resolved = expectation(description: "route resolved")

        controller.schedule(currentKey: key) { receivedKey in
            XCTAssertEqual(receivedKey, key)
            return route
        } onResolved: { resolvedRoute, resolvedKey in
            XCTAssertTrue(controller.apply(resolvedRoute, for: resolvedKey, currentKey: key))
            resolved.fulfill()
        }

        await fulfillment(of: [resolved], timeout: 1)
        XCTAssertEqual(controller.resolvedRoute, route)
        XCTAssertEqual(controller.status, .resolved(hasDrivingDistance: true))
    }

    func testApplyRejectsStaleRouteResult() throws {
        let controller = ManualRouteLookupController(debounceNanoseconds: 0)
        let oldKey = try XCTUnwrap(ManualRouteLookupKey(origin: "Old", destination: "Client"))
        let currentKey = try XCTUnwrap(ManualRouteLookupKey(origin: "New", destination: "Client"))
        let route = ResolvedManualRoute(
            startCoordinate: Coordinate(latitude: 40, longitude: -73),
            endCoordinate: Coordinate(latitude: 40.01, longitude: -73),
            routePolyline: "encoded",
            distanceMeters: 1_200
        )

        XCTAssertFalse(controller.apply(route, for: oldKey, currentKey: currentKey))
        XCTAssertNil(controller.resolvedRoute)
        XCTAssertEqual(controller.status, .idle)
    }

    func testScheduleAndApplyRejectsStaleCurrentKey() async throws {
        let controller = ManualRouteLookupController(debounceNanoseconds: 0)
        let oldKey = try XCTUnwrap(ManualRouteLookupKey(origin: "Old", destination: "Client"))
        let currentKey = try XCTUnwrap(ManualRouteLookupKey(origin: "New", destination: "Client"))
        let route = ResolvedManualRoute(
            startCoordinate: Coordinate(latitude: 40, longitude: -73),
            endCoordinate: Coordinate(latitude: 40.01, longitude: -73),
            routePolyline: "encoded",
            distanceMeters: 1_200
        )
        let resolved = expectation(description: "route resolved")

        controller.scheduleAndApply(
            currentKey: oldKey,
            currentKeyProvider: { currentKey },
            resolve: { _ in route },
            onApplied: { _ in
                XCTFail("Stale route should not be applied")
            }
        )
        controller.schedule(
            currentKey: currentKey,
            resolve: { _ in route },
            onResolved: { _, _ in resolved.fulfill() }
        )

        await fulfillment(of: [resolved], timeout: 1)
        XCTAssertNil(controller.resolvedRoute)
    }

    func testPresentationUsesStoredTripUntilEndpointsChange() throws {
        let controller = ManualRouteLookupController(debounceNanoseconds: 0)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = makeTrip(
            startDate: start,
            miles: 5,
            classification: .business,
            startCoordinate: Coordinate(latitude: 40, longitude: -73),
            endCoordinate: Coordinate(latitude: 40.01, longitude: -73)
        )
        let storedKey = try XCTUnwrap(ManualRouteLookupKey(origin: trip.startAddress ?? "", destination: trip.endAddress ?? ""))

        var presentation = ManualRouteLookupPresentation(
            lookup: controller,
            currentKey: storedKey,
            storedKey: storedKey,
            storedTrip: trip
        )
        XCTAssertNotNil(presentation.mapContent)
        XCTAssertFalse(presentation.endpointsChangedFromStored)
        XCTAssertFalse(presentation.shouldClearRouteOnSave)

        let changedKey = try XCTUnwrap(ManualRouteLookupKey(origin: "Other", destination: "End"))
        presentation = ManualRouteLookupPresentation(
            lookup: controller,
            currentKey: changedKey,
            storedKey: storedKey,
            storedTrip: trip
        )
        XCTAssertNil(presentation.mapContent)
        XCTAssertTrue(presentation.endpointsChangedFromStored)
        XCTAssertTrue(presentation.shouldClearRouteOnSave)
    }
}
