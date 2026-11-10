import CoreData
import XCTest
@testable import AppCore

@MainActor
final class TripEditableSnapshotTests: XCTestCase {
    func testRestoreEditableSnapshotRestoresAllEditableFieldsAndFees() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let startCoordinate = Coordinate(latitude: 40.741, longitude: -73.989)
        let endCoordinate = Coordinate(latitude: 40.752, longitude: -73.977)
        let polyline = EncodedPolyline.encode([startCoordinate, endCoordinate])
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: startCoordinate,
            endCoordinate: endCoordinate,
            startAddress: "Studio",
            endAddress: "Client",
            distanceMeters: 4_200,
            routePolyline: polyline,
            notes: "Bring lighting kit"
        ))
        _ = try store.applyAutomaticClassification(
            tripID: trip.id,
            classification: .notADrive,
            source: .autoTransit
        )
        _ = try store.appendAttentionReason(tripID: trip.id, reason: "Verify route")
        let fee = try store.addFee(TripFee(
            tripID: trip.id,
            category: .parking,
            amount: 18,
            occurredAt: start.addingTimeInterval(600),
            label: "Client garage"
        ))
        let before = try store.editableSnapshot(tripID: trip.id)

        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(
                classification: .business,
                businessPurpose: "Client meeting",
                notes: "Changed"
            )
        )
        _ = try store.updateRoute(
            tripID: trip.id,
            startCoordinate: Coordinate(latitude: 42, longitude: -71),
            endCoordinate: Coordinate(latitude: 42.1, longitude: -71.1),
            routePolyline: nil,
            distanceMeters: 9_000
        )
        try store.deleteFee(id: fee.id)

        _ = try store.restoreEditableSnapshot(before)

        XCTAssertEqual(try store.editableSnapshot(tripID: trip.id), before)
        let restored = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(restored.classificationSource, .autoTransit)
        XCTAssertEqual(restored.attentionReasons, [])
        XCTAssertFalse(restored.needsAttention)
        XCTAssertEqual(restored.reviewStatus, .readyToExport)
        XCTAssertEqual(restored.notes, "Bring lighting kit")
        XCTAssertEqual(restored.routePolyline, polyline)
        XCTAssertEqual(try store.fetchFees(tripID: trip.id), before.fees)
    }

    func testDuplicateCanBeDeletedAndRecreatedWithExactIdentityAndDraft() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let original = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_200),
            startCoordinate: Coordinate(latitude: 40.71, longitude: -74.01),
            endCoordinate: Coordinate(latitude: 40.75, longitude: -73.98),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: 5_000,
            routePolyline: EncodedPolyline.encode([
                Coordinate(latitude: 40.71, longitude: -74.01),
                Coordinate(latitude: 40.75, longitude: -73.98)
            ]),
            classification: .business,
            businessPurpose: "Client meeting",
            notes: "Bring proposal"
        ))
        let duplicateID = UUID()
        let result = try store.duplicateTripWithSnapshot(
            id: original.id,
            newID: duplicateID,
            startDate: start.addingTimeInterval(86_400)
        )
        let duplicate = result.trip
        XCTAssertEqual(duplicate.id, duplicateID)
        let snapshot = result.snapshot
        XCTAssertEqual(snapshot, try store.editableSnapshot(tripID: duplicateID))

        try store.deleteTrip(id: duplicateID)
        XCTAssertNil(try store.fetchTripIfExists(id: duplicateID))

        let recreated = try store.recreateTrip(from: snapshot)
        XCTAssertEqual(recreated.id, duplicateID)
        XCTAssertEqual(try store.editableSnapshot(tripID: duplicateID), snapshot)
    }
}
