import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

/// `isArchived` remains in the deployed CloudKit schema only so maintenance
/// can permanently remove rows written by the retired "Exclude from reports"
/// feature.
@MainActor
final class RetiredTripMaintenanceTests: XCTestCase {
    func testRunDeletesArchivedTripsAndLeavesActiveTripsAlone() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = try makeTrip(store, start: start)
        let archived = try makeTrip(store, start: start.addingTimeInterval(7_200))
        try setArchived(true, tripID: archived.id, in: persistence.container.viewContext)

        let result = try await RetiredTripMaintenance(persistence: persistence).run()

        XCTAssertEqual(result.deletedArchivedTripRows, 1)
        XCTAssertEqual(result.clearedRetiredAttentionRows, 0)
        persistence.container.viewContext.reset()
        XCTAssertEqual(
            try TripStore(context: persistence.container.viewContext).fetchTrips().map(\.id),
            [kept.id]
        )
    }

    func testArchivedPhysicalRevisionPreservesUUIDDependentsWhenActiveRevisionSurvives() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let active = try makeTrip(store, start: start)
        let fee = try store.addFee(TripFee(
            tripID: active.id,
            category: .parking,
            amount: 9,
            occurredAt: start,
            label: "Garage"
        ))
        insertRawSample(tripID: active.id, date: start, in: context)
        insertEnrichmentAttempt(tripID: active.id, date: start, in: context)
        _ = try clone(active.id, archived: true, in: context)
        try context.save()

        let result = try await RetiredTripMaintenance(persistence: persistence).run()

        XCTAssertEqual(result.deletedArchivedTripRows, 1)
        context.reset()
        let physicalRows = try fetchPhysicalTrips(active.id, in: context)
        XCTAssertEqual(physicalRows.count, 1)
        XCTAssertFalse(try XCTUnwrap(physicalRows.first).isArchived)
        XCTAssertEqual(try TripStore(context: context).fetchFees(tripID: active.id).map(\.id), [fee.id])
        XCTAssertEqual(try count(RawSampleEntity.fetchRequest(), tripID: active.id, in: context), 1)
        XCTAssertEqual(
            try count(TripEnrichmentAttemptEntity.fetchRequest(), tripID: active.id, in: context),
            1
        )
    }

    func testAllArchivedPhysicalRevisionsCascadeDeleteUUIDDependents() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start)
        let fee = try store.addFee(TripFee(
            tripID: trip.id,
            category: .parking,
            amount: 9,
            occurredAt: start,
            label: "Garage"
        ))
        insertRawSample(tripID: trip.id, date: start, in: context)
        insertEnrichmentAttempt(tripID: trip.id, date: start, in: context)
        _ = try clone(trip.id, archived: true, in: context)
        try setArchived(true, tripID: trip.id, in: context)

        let result = try await RetiredTripMaintenance(persistence: persistence).run()

        XCTAssertEqual(result.deletedArchivedTripRows, 2)
        context.reset()
        XCTAssertTrue(try fetchPhysicalTrips(trip.id, in: context).isEmpty)
        let feeRequest = TripFeeEntity.fetchRequest()
        feeRequest.predicate = NSPredicate(format: "id == %@", fee.id as CVarArg)
        XCTAssertTrue(try context.fetch(feeRequest).isEmpty)
        XCTAssertEqual(try count(RawSampleEntity.fetchRequest(), tripID: trip.id, in: context), 0)
        XCTAssertEqual(
            try count(TripEnrichmentAttemptEntity.fetchRequest(), tripID: trip.id, in: context),
            0
        )
    }

    func testRunClearsOnlyRetiredAttentionReasonAndRecomputesReviewState() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = try makeTrip(
            store,
            start: start,
            classification: .business,
            businessPurpose: "Client meeting"
        )
        let stillFlagged = try makeTrip(
            store,
            start: start.addingTimeInterval(7_200),
            classification: .personal
        )
        try setAttentionReasons(
            [RetiredTripMaintenance.retiredPossibleDuplicateAttentionReason],
            tripID: ready.id,
            in: context
        )
        try setAttentionReasons(
            [
                RetiredTripMaintenance.retiredPossibleDuplicateAttentionReason,
                TransitTripClassifier.impossibleJumpReason
            ],
            tripID: stillFlagged.id,
            in: context
        )

        let result = try await RetiredTripMaintenance(persistence: persistence).run()

        XCTAssertEqual(result.clearedRetiredAttentionRows, 2)
        context.reset()
        let refreshed = TripStore(context: context)
        let readyTrip = try refreshed.fetchTrip(id: ready.id)
        XCTAssertEqual(readyTrip.attentionReasons, [])
        XCTAssertFalse(readyTrip.needsAttention)
        XCTAssertEqual(readyTrip.reviewStatus, .readyToExport)
        let flaggedTrip = try refreshed.fetchTrip(id: stillFlagged.id)
        XCTAssertEqual(flaggedTrip.attentionReasons, [TransitTripClassifier.impossibleJumpReason])
        XCTAssertTrue(flaggedTrip.needsAttention)
        XCTAssertEqual(flaggedTrip.reviewStatus, .needsAttention)
    }

    func testRunIsIdempotent() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let trip = try makeTrip(store, start: Date(timeIntervalSince1970: 1_800_000_000))
        try setArchived(true, tripID: trip.id, in: context)

        let first = try await RetiredTripMaintenance(persistence: persistence).run()
        let second = try await RetiredTripMaintenance(persistence: persistence).run()

        XCTAssertEqual(first.deletedArchivedTripRows, 1)
        XCTAssertEqual(second, .init(deletedArchivedTripRows: 0, clearedRetiredAttentionRows: 0))
    }

    private func makeTrip(
        _ store: TripStore,
        start: Date,
        classification: TripClassification = .personal,
        businessPurpose: String? = nil
    ) throws -> TripSummary {
        try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_200),
            startAddress: "Origin",
            endAddress: "Destination",
            distanceMeters: 4_000,
            classification: classification,
            businessPurpose: businessPurpose
        ))
    }

    private func fetchPhysicalTrips(
        _ tripID: UUID,
        in context: NSManagedObjectContext
    ) throws -> [TripEntity] {
        let request = TripEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", tripID as CVarArg)
        return try context.fetch(request)
    }

    @discardableResult
    private func clone(
        _ tripID: UUID,
        archived: Bool,
        in context: NSManagedObjectContext
    ) throws -> TripEntity {
        let source = try XCTUnwrap(fetchPhysicalTrips(tripID, in: context).first)
        let copy = TripEntity.insert(into: context)
        for attribute in source.entity.attributesByName.keys {
            copy.setValue(source.value(forKey: attribute), forKey: attribute)
        }
        copy.isArchived = archived
        return copy
    }

    private func setArchived(
        _ archived: Bool,
        tripID: UUID,
        in context: NSManagedObjectContext
    ) throws {
        for trip in try fetchPhysicalTrips(tripID, in: context) {
            trip.isArchived = archived
        }
        try context.save()
    }

    private func setAttentionReasons(
        _ reasons: [String],
        tripID: UUID,
        in context: NSManagedObjectContext
    ) throws {
        for trip in try fetchPhysicalTrips(tripID, in: context) {
            trip.setAttentionReasons(reasons, encoder: JSONEncoder())
            trip.needsAttention = true
            trip.reviewStatus = .needsAttention
        }
        try context.save()
    }

    private func insertRawSample(
        tripID: UUID,
        date: Date,
        in context: NSManagedObjectContext
    ) {
        let sample = RawSampleEntity.insert(into: context)
        sample.id = UUID()
        sample.tripID = tripID
        sample.timestamp = date
        sample.latitude = 42
        sample.longitude = -71
        sample.horizontalAccuracy = 8
        sample.motionHintRaw = MotionHint.automotive.rawValue
        sample.expiresAt = date.addingTimeInterval(30 * 24 * 60 * 60)
    }

    private func insertEnrichmentAttempt(
        tripID: UUID,
        date: Date,
        in context: NSManagedObjectContext
    ) {
        let attempt = TripEnrichmentAttemptEntity.insert(into: context)
        attempt.id = UUID()
        attempt.tripID = tripID
        attempt.component = .startAddress
        attempt.lastAttemptAt = date
        attempt.consecutiveFailures = 1
        attempt.failureCategory = .networkUnavailable
    }

    private func count<T: NSManagedObject>(
        _ request: NSFetchRequest<T>,
        tripID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Int {
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        return try context.count(for: request)
    }
}
