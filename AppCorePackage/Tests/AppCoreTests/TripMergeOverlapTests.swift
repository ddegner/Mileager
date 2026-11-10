import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class TripMergeOverlapTests: XCTestCase {
    func testOverlapsKeepFullSpanEndpointsMileageAndSourceLegsAfterReloadAndUnmerge() throws {
        // Contained, equal-start, and partial overlaps, in both input orders.
        for (offset, duration) in [(600.0, 600.0), (0, 9_000), (3_600, 6_000)] {
            for reverse in [false, true] {
                let persistence = try PersistenceController(inMemory: true)
                let context = persistence.container.viewContext
                let store = TripStore(context: context)
                let start = Date(timeIntervalSince1970: 1_800_000_000)
                let first = try capture(store, start: start, duration: 7_200, miles: 4, latitude: 40)
                let second = try capture(
                    store, start: start.addingTimeInterval(offset), duration: duration, miles: 3, latitude: 43
                )
                let terminal = first.endDate > second.endDate ? first : second
                let ids = reverse ? [second.id, first.id] : [first.id, second.id]
                let merged = try store.mergeTrips(ids: ids)
                context.reset()
                let reloaded = try store.fetchTrip(id: merged.id)
                let decoded = try JSONDecoder().decode(TripSummary.self, from: JSONEncoder().encode(reloaded))
                for result in [merged, reloaded, decoded] {
                    XCTAssertEqual(result.startDate, start)
                    XCTAssertEqual(result.endDate, terminal.endDate)
                    XCTAssertEqual(result.durationSeconds, terminal.endDate.timeIntervalSince(start))
                    XCTAssertEqual(result.endCoordinate, terminal.endCoordinate)
                    XCTAssertEqual(result.endAddress, terminal.endAddress)
                    XCTAssertEqual(result.endAddressComponents, terminal.endAddressComponents)
                    XCTAssertEqual(result.routeSummary.endCoordinate, terminal.endCoordinate)
                    XCTAssertEqual(result.miles, 7, accuracy: 0.0001)
                    XCTAssertEqual(result.tollsAmount, 2)
                    XCTAssertEqual(result.parkingAmount, 4)
                    XCTAssertEqual(result.legs.count, 2)
                    XCTAssertTrue(result.connectors.isEmpty)
                }
                let unchanged = try store.updateTripWithSnapshots(
                    id: merged.id, update: TripEditorUpdate(trip: reloaded, fees: store.fetchFees(tripID: merged.id))
                )
                XCTAssertEqual(unchanged.before, unchanged.after)
                let restored = try store.unmergeTrip(id: merged.id)
                for original in [first, second] {
                    let legTrip = try XCTUnwrap(restored.first { $0.id == original.id })
                    XCTAssertEqual(legTrip.startDate, original.startDate)
                    XCTAssertEqual(legTrip.endDate, original.endDate)
                    XCTAssertEqual(legTrip.startCoordinate, original.startCoordinate)
                    XCTAssertEqual(legTrip.endCoordinate, original.endCoordinate)
                    XCTAssertEqual(legTrip.routePolyline, original.routePolyline)
                    XCTAssertEqual(legTrip.distanceMeters, original.distanceMeters)
                }
                XCTAssertEqual(restored.reduce(0) { $0 + $1.tollsAmount }, 2)
                XCTAssertEqual(restored.reduce(0) { $0 + $1.parkingAmount }, 4)
            }
        }
    }

    func testEditingContainedMergeUpdatesTheBoundaryLegAndItsRouteOnly() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let outer = try capture(store, start: start, duration: 7_200, miles: 4, latitude: 40)
        let inner = try capture(store, start: start.addingTimeInterval(600), duration: 600, miles: 3, latitude: 43)
        let merged = try store.mergeTrips(ids: [inner.id, outer.id])
        let beforeInner = try XCTUnwrap(merged.legs.first { $0.sourceTripID == inner.id })
        var edit = TripEditorUpdate(trip: merged, fees: try store.fetchFees(tripID: merged.id))
        edit.startDate = start.addingTimeInterval(-60)
        edit.endDate = outer.endDate.addingTimeInterval(300)
        edit.endCoordinate = Coordinate(latitude: 41.5, longitude: -74)
        edit.endAddress = "New ending"
        edit.endAddressComponents = TripEndpointAddressComponents(city: "New ending city")
        edit.routePolyline = nil
        let updated = try store.updateTripWithSnapshots(id: merged.id, update: edit).trip
        let updatedOuter = try XCTUnwrap(updated.legs.first { $0.sourceTripID == outer.id })
        XCTAssertEqual(updated.startDate, edit.startDate)
        XCTAssertEqual(updated.endDate, edit.endDate)
        XCTAssertEqual(updated.endCoordinate, edit.endCoordinate)
        XCTAssertEqual(updated.endAddressComponents, edit.endAddressComponents)
        XCTAssertEqual(updated.routeSummary.endCoordinate, edit.endCoordinate)
        XCTAssertEqual(updatedOuter.startDate, edit.startDate)
        XCTAssertEqual(updatedOuter.endDate, edit.endDate)
        XCTAssertEqual(updatedOuter.endCoordinate, edit.endCoordinate)
        XCTAssertEqual(updatedOuter.endAddressComponents, edit.endAddressComponents)
        XCTAssertNil(updatedOuter.routePolyline)
        XCTAssertEqual(updated.legs.first { $0.sourceTripID == inner.id }, beforeInner)
        XCTAssertEqual(updated.distanceMeters, merged.distanceMeters)
        XCTAssertEqual(try store.fetchTrip(id: merged.id), updated)
    }

    func testLegacyContainedMergeDoesNotBorrowTheInnerLegsEndpointWhenTheActualEndIsUnknown() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let outer = try capture(store, start: start, duration: 7_200, miles: 4, latitude: 40)
        let inner = try capture(store, start: start.addingTimeInterval(600), duration: 600, miles: 3, latitude: 43)
        var legacy = try store.mergeTrips(ids: [outer.id, inner.id])
        let outerIndex = try XCTUnwrap(legacy.legs.firstIndex { $0.sourceTripID == outer.id })
        legacy.legs[outerIndex].endCoordinate = nil
        legacy.legs[outerIndex].endAddress = nil
        legacy.legs[outerIndex].endAddressComponents = nil
        // Prior versions stored the last-starting capture's end at the top level.
        legacy.endDate = inner.endDate
        legacy.endCoordinate = inner.endCoordinate
        legacy.endAddress = inner.endAddress
        legacy.endAddressComponents = inner.endAddressComponents
        let reloaded = try JSONDecoder().decode(TripSummary.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(reloaded.endDate, outer.endDate)
        XCTAssertNil(reloaded.endCoordinate)
        XCTAssertNil(reloaded.endAddress)
        XCTAssertNil(reloaded.endAddressComponents)
        XCTAssertNil(reloaded.routeSummary.endCoordinate)
    }

    func testDateEditCannotSilentlyLeaveOtherLegsOutsideRequestedSpan() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let outer = try capture(store, start: start, duration: 7_200, miles: 4, latitude: 40)
        let inner = try capture(store, start: start.addingTimeInterval(600), duration: 600, miles: 3, latitude: 43)
        let merged = try store.mergeTrips(ids: [outer.id, inner.id])
        let before = try store.editableSnapshot(tripID: merged.id)
        var edit = TripEditorUpdate(trip: merged, fees: try store.fetchFees(tripID: merged.id))
        edit.endDate = start.addingTimeInterval(900)
        XCTAssertThrowsError(try store.updateTripWithSnapshots(id: merged.id, update: edit))
        XCTAssertEqual(try store.editableSnapshot(tripID: merged.id), before)
    }

    func testDuplicateAndMissingMergeIDsLeaveAllSourcesAndFeesUntouched() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try capture(store, start: start, duration: 600, miles: 4, latitude: 40)
        let second = try capture(store, start: start.addingTimeInterval(300), duration: 600, miles: 3, latitude: 43)
        let before = try store.fetchTrips()
        let firstSnapshot = try store.editableSnapshot(tripID: first.id)
        let secondSnapshot = try store.editableSnapshot(tripID: second.id)
        for ids in [[first.id, first.id], [first.id, UUID()], [first.id, second.id, first.id]] {
            XCTAssertThrowsError(try store.mergeTrips(ids: ids))
            XCTAssertEqual(try store.fetchTrips(), before)
            XCTAssertEqual(try store.editableSnapshot(tripID: first.id), firstSnapshot)
            XCTAssertEqual(try store.editableSnapshot(tripID: second.id), secondSnapshot)
        }
    }

    private func capture(
        _ store: TripStore,
        start: Date,
        duration: TimeInterval,
        miles: Double,
        latitude: Double
    ) throws -> TripSummary {
        let trip = try makeTrip(
            store, start: start, duration: duration, distanceMiles: miles, classification: .business,
            route: [Coordinate(latitude: latitude, longitude: -74), Coordinate(latitude: latitude + 0.1, longitude: -74)],
            tolls: 1, parking: 2
        )
        var edit = TripEditorUpdate(trip: trip, fees: try store.fetchFees(tripID: trip.id))
        edit.startAddressComponents = TripEndpointAddressComponents(city: "Start \(latitude)")
        edit.endAddressComponents = TripEndpointAddressComponents(city: "End \(latitude)")
        return try store.updateTripWithSnapshots(id: trip.id, update: edit).trip
    }
}
