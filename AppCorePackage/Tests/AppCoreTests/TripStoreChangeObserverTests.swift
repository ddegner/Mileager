import CoreData
import XCTest
@testable import AppCore

private final class RecordingObserver: TripStoreChangeObserver {
    private(set) var changes: [TripChangeSet] = []

    func tripStoreDidChange(_ change: TripChangeSet) {
        changes.append(change)
    }

    var lastChange: TripChangeSet? { changes.last }
}

final class TripStoreChangeObserverTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: TripStore!
    private var observer: RecordingObserver!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        persistence = try PersistenceController(inMemory: true)
        store = TripStore(context: persistence.container.viewContext)
        observer = RecordingObserver()
        store.changeObserver = observer
    }

    private func makeTrip(
        classification: TripClassification? = nil,
        offset: TimeInterval = 0
    ) throws -> TripSummary {
        try AppCoreTests.makeTrip(
            store,
            start: start.addingTimeInterval(offset),
            duration: 600,
            distanceMiles: 42,
            classification: classification,
            startAddress: "145 Example St, Brooklyn, NY",
            endAddress: "9 Sample St, Darien, CT"
        )
    }

    func testManualTripCreateEmitsUpsert() throws {
        let trip = try makeTrip()

        XCTAssertEqual(observer.changes.count, 1)
        XCTAssertEqual(observer.lastChange?.upserted.map(\.id), [trip.id])
        XCTAssertEqual(observer.lastChange?.deletedIDs, [])
    }

    func testClassificationUpdateEmitsUpsertWithNewValue() throws {
        let trip = try makeTrip()

        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .business, reviewStatus: .readyToExport)
        )

        XCTAssertEqual(observer.changes.count, 2)
        let upserted = try XCTUnwrap(observer.lastChange?.upserted.first)
        XCTAssertEqual(upserted.id, trip.id)
        XCTAssertEqual(upserted.classification, .business)
    }

    func testDeleteEmitsDeletedID() throws {
        let trip = try makeTrip()

        try store.deleteTrip(id: trip.id)

        XCTAssertEqual(observer.lastChange?.upserted, [])
        XCTAssertEqual(observer.lastChange?.deletedIDs, [trip.id])
    }

    func testMergeEmitsSourceDeletionsAndMergedUpsertInOneChange() throws {
        let first = try makeTrip(classification: .business)
        let second = try makeTrip(classification: .business, offset: 3_600)

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        let change = try XCTUnwrap(observer.lastChange)
        XCTAssertEqual(Set(change.deletedIDs), [first.id, second.id])
        XCTAssertEqual(change.upserted.map(\.id), [merged.id])
    }

    func testUnmergeEmitsMergedDeletionAndRestoredUpserts() throws {
        let first = try makeTrip(classification: .personal)
        let second = try makeTrip(classification: .personal, offset: 3_600)
        let merged = try store.mergeTrips(ids: [first.id, second.id])

        let restored = try store.unmergeTrip(id: merged.id)

        let change = try XCTUnwrap(observer.lastChange)
        XCTAssertTrue(change.deletedIDs.contains(merged.id))
        XCTAssertEqual(Set(change.upserted.map(\.id)), Set(restored.map(\.id)))
    }

    func testFeeChangeEmitsTripUpsert() throws {
        let trip = try makeTrip()

        _ = try store.addFee(TripFee(
            tripID: trip.id,
            category: .toll,
            amount: 6.94,
            occurredAt: start.addingTimeInterval(300)
        ))

        let change = try XCTUnwrap(observer.lastChange)
        XCTAssertEqual(change.upserted.map(\.id), [trip.id])
    }

    func testRejectedUpdateRollsBackWithoutNotifying() throws {
        let trip = try makeTrip()
        let countAfterCreate = observer.changes.count

        XCTAssertThrowsError(try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(
                startDate: start.addingTimeInterval(900),
                endDate: start.addingTimeInterval(300)
            )
        ))

        XCTAssertEqual(observer.changes.count, countAfterCreate)
    }
}
