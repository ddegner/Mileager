import AppCore
import Foundation
import XCTest
@testable import MileageTracker

private final class SpySpotlightIndex: SpotlightIndexing, @unchecked Sendable {
    enum Operation: Equatable {
        case index([UUID])
        case delete([UUID])
        case indexReports([String])
        case deleteReports([String])
        case deleteAll
    }

    private let lock = NSLock()
    private var _operations: [Operation] = []
    var failNextIndex = false

    var operations: [Operation] {
        lock.withLock { _operations }
    }

    /// Trip-only view for the trip tests, which assert exact operation lists
    /// and must not see month traffic.
    var tripOperations: [Operation] {
        operations.filter {
            if case .indexReports = $0 { return false }
            if case .deleteReports = $0 { return false }
            return true
        }
    }

    var donatedReportIDs: [String] {
        operations.flatMap { operation -> [String] in
            if case .indexReports(let ids) = operation { return ids }
            return []
        }
    }

    var deletedReportIDs: [String] {
        operations.flatMap { operation -> [String] in
            if case .deleteReports(let ids) = operation { return ids }
            return []
        }
    }

    func index(_ entities: [TripAppEntity]) async throws {
        let shouldFail = lock.withLock {
            let value = failNextIndex
            failNextIndex = false
            if !value {
                _operations.append(.index(entities.map(\.id)))
            }
            return value
        }
        if shouldFail {
            throw NSError(domain: "SpySpotlightIndex", code: 1)
        }
    }

    func delete(ids: [UUID]) async throws {
        lock.withLock { _operations.append(.delete(ids)) }
    }

    func index(reports: [MonthlyMileageReportEntity]) async throws {
        lock.withLock { _operations.append(.indexReports(reports.map(\.id))) }
    }

    func delete(reportIDs: [String]) async throws {
        lock.withLock { _operations.append(.deleteReports(reportIDs)) }
    }

    func deleteAll() async throws {
        lock.withLock { _operations.append(.deleteAll) }
    }
}

@MainActor
final class TripSpotlightIndexerTests: XCTestCase {
    private var spy: SpySpotlightIndex!
    private var enabled = true
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        spy = SpySpotlightIndex()
        enabled = true
    }

    private func makeIndexer() -> TripSpotlightIndexer {
        let manifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlight-manifest-\(UUID().uuidString).json")
        return TripSpotlightIndexer(
            index: spy,
            isEnabled: { [weak self] in self?.enabled ?? false },
            manifestURL: manifestURL
        )
    }

    private func trip(
        classification: TripClassification? = nil,
        reviewStatus: ReviewStatus = .needsReview,
        updatedAt: Date? = nil,
        id: UUID = UUID()
    ) -> TripSummary {
        TripSummary(
            id: id,
            createdAt: start,
            updatedAt: updatedAt ?? start,
            captureSource: "automatic",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: "145 Court St, Brooklyn, NY",
            endAddress: "9 Pine St, Darien, CT",
            distanceMeters: DistanceConversion.meters(fromMiles: 12),
            routePolyline: nil,
            classification: classification,
            reviewStatus: reviewStatus,
            businessPurpose: classification == .business ? "Client visit" : nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
    }

    func testShouldIndexExcludesNotADrive() {
        XCTAssertTrue(TripSpotlightIndexer.shouldIndex(trip()))
        XCTAssertTrue(TripSpotlightIndexer.shouldIndex(trip(classification: .business)))
        XCTAssertFalse(TripSpotlightIndexer.shouldIndex(trip(classification: .notADrive)))
    }

    func testUpsertDonatesIndexableTrip() async {
        let indexer = makeIndexer()
        let indexable = trip()

        indexer.noteChange(TripChangeSet(upserted: [indexable]))
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [.index([indexable.id])])
    }

    func testNotADriveUpsertBecomesDeletion() async {
        let indexer = makeIndexer()
        let excluded = trip(classification: .notADrive)

        indexer.noteChange(TripChangeSet(upserted: [excluded]))
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [.delete([excluded.id])])
    }

    func testDeletionsApplyBeforeDonations() async {
        let indexer = makeIndexer()
        let merged = trip(classification: .business)
        let sourceID = UUID()

        indexer.noteChange(TripChangeSet(upserted: [merged], deletedIDs: [sourceID]))
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [.delete([sourceID]), .index([merged.id])])
    }

    func testDisabledIndexerIgnoresChanges() async {
        enabled = false
        let indexer = makeIndexer()

        indexer.noteChange(TripChangeSet(upserted: [trip()]))
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [])
    }

    func testSetEnabledOffErasesIndex() async {
        let indexer = makeIndexer()

        indexer.setEnabled(false) { [] }
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [.deleteAll])
    }

    func testReconcileDonatesNewAndStaleAndDeletesRemoved() async {
        let indexer = makeIndexer()
        let unchanged = trip()
        let stale = trip()
        indexer.noteChange(TripChangeSet(upserted: [unchanged, stale]))
        await indexer.drainForTesting()

        let fresh = trip()
        let updatedStale = trip(updatedAt: start.addingTimeInterval(60), id: stale.id)
        // One new trip and one updated trip arrive (e.g. via CloudKit import);
        // the reconcile must donate both but skip the unchanged trip.
        indexer.setEnabled(true) { [unchanged, updatedStale, fresh] }
        await indexer.drainForTesting()

        let donated = spy.operations.compactMap { operation -> [UUID]? in
            if case .index(let ids) = operation { return ids }
            return nil
        }.flatMap { $0 }
        XCTAssertTrue(donated.contains(fresh.id))
        XCTAssertEqual(donated.filter { $0 == updatedStale.id }.count, 2, "stale trip re-donated after update")
        XCTAssertEqual(donated.filter { $0 == unchanged.id }.count, 1, "unchanged trip not re-donated")
    }

    /// Donated snippets bake formatted distances in, so a mi↔km switch makes
    /// every entry stale even though no trip's updatedAt moved. The manifest's
    /// format stamp must force a full re-donation on the next reconcile.
    func testUnitChangeMarksAllDonationsStale() async {
        let preferences = Preferences()
        let originalUnit = preferences.displayDistanceUnitRaw
        defer { preferences.displayDistanceUnitRaw = originalUnit }
        preferences.displayDistanceUnitRaw = DistanceUnit.miles.rawValue

        let indexer = makeIndexer()
        let unchanged = trip()
        indexer.noteChange(TripChangeSet(upserted: [unchanged]))
        await indexer.drainForTesting()

        // Same trip, same updatedAt — only the display unit changed.
        preferences.displayDistanceUnitRaw = DistanceUnit.kilometers.rawValue
        indexer.setEnabled(true) { [unchanged] }
        await indexer.drainForTesting()

        let donated = spy.operations.compactMap { operation -> [UUID]? in
            if case .index(let ids) = operation { return ids }
            return nil
        }.flatMap { $0 }
        XCTAssertEqual(donated.filter { $0 == unchanged.id }.count, 2, "unit switch re-donates unchanged trips")
    }

    func testReconcileDeletesManifestEntriesMissingFromStore() async {
        let indexer = makeIndexer()
        let kept = trip()
        let vanished = trip()
        indexer.noteChange(TripChangeSet(upserted: [kept, vanished]))
        await indexer.drainForTesting()

        indexer.setEnabled(true) { [kept] }
        await indexer.drainForTesting()

        let deleted = spy.operations.compactMap { operation -> [UUID]? in
            if case .delete(let ids) = operation { return ids }
            return nil
        }.flatMap { $0 }
        XCTAssertEqual(deleted, [vanished.id])
    }

    func testReconcileLeavesIndexAloneWhenFetchThrows() async {
        let indexer = makeIndexer()
        let donated = trip()
        indexer.noteChange(TripChangeSet(upserted: [donated]))
        await indexer.drainForTesting()
        let countBefore = spy.operations.count

        struct Unavailable: Error {}
        indexer.setEnabled(true) { throw Unavailable() }
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations.count, countBefore)
    }

    func testFailedDonationRetriesOnNextReconcile() async {
        let indexer = makeIndexer()
        let unlucky = trip()
        spy.failNextIndex = true
        indexer.noteChange(TripChangeSet(upserted: [unlucky]))
        await indexer.drainForTesting()
        XCTAssertEqual(spy.operations, [])

        indexer.setEnabled(true) { [unlucky] }
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [.index([unlucky.id])])
    }

    func testReindexIDsDonatesIndexableAndDeletesExcludedOrMissing() async {
        let indexer = makeIndexer()
        let indexable = trip(classification: .business)
        let excluded = trip(classification: .notADrive)
        let missingID = UUID()
        let byID = [indexable.id: indexable, excluded.id: excluded]

        indexer.reindex(ids: [indexable.id, excluded.id, missingID]) { id in byID[id] }
        await indexer.drain()

        XCTAssertEqual(spy.tripOperations, [
            .delete([excluded.id, missingID]),
            .index([indexable.id])
        ])
    }

    func testReindexIDsNoOpsWhenDisabled() async {
        enabled = false
        let indexer = makeIndexer()
        let indexable = trip()

        indexer.reindex(ids: [indexable.id]) { _ in indexable }
        await indexer.drain()

        XCTAssertEqual(spy.tripOperations, [])
    }

    func testReindexAllForceDonatesManifestCurrentTrips() async {
        let indexer = makeIndexer()
        let donated = trip()
        indexer.noteChange(TripChangeSet(upserted: [donated]))
        await indexer.drain()
        XCTAssertEqual(spy.tripOperations, [.index([donated.id])])

        // A plain reconcile would skip this manifest-current trip; a system
        // reindex request must re-donate it anyway.
        indexer.reindexAll { [donated] }
        await indexer.drain()

        XCTAssertEqual(spy.tripOperations, [.index([donated.id]), .index([donated.id])])
    }

    func testReindexAllLeavesIndexAloneWhenFetchThrows() async {
        let indexer = makeIndexer()
        struct Unavailable: Error {}

        indexer.reindexAll { throw Unavailable() }
        await indexer.drain()

        XCTAssertEqual(spy.tripOperations, [])
    }

    func testReindexFetchErrorDoesNotDeletePreviouslyDonatedTrip() async {
        let indexer = makeIndexer()
        let donated = trip()
        indexer.noteChange(TripChangeSet(upserted: [donated]))
        await indexer.drain()
        let before = spy.tripOperations
        struct Unavailable: Error {}
        indexer.reindex(ids: [donated.id]) { _ in throw Unavailable() }
        await indexer.drain()
        XCTAssertEqual(spy.tripOperations, before)
    }

    func testReindexQueuedBeforeOptOutDoesNotDonate() async {
        let indexer = makeIndexer()
        let donated = trip()
        indexer.reindex(ids: [donated.id]) { _ in donated }
        enabled = false
        await indexer.drain()
        XCTAssertEqual(spy.tripOperations, [])
    }

    func testReindexAllDeletesTripsMissingFromStore() async {
        let indexer = makeIndexer()
        let vanished = trip()
        indexer.noteChange(TripChangeSet(upserted: [vanished]))
        await indexer.drain()
        indexer.reindexAll { [] }
        await indexer.drain()
        XCTAssertEqual(spy.tripOperations, [.index([vanished.id]), .delete([vanished.id])])
    }

    func testDonationsBatchAtTwoHundred() async {
        let indexer = makeIndexer()
        let many = (0 ..< 250).map { _ in trip() }

        indexer.noteChange(TripChangeSet(upserted: many))
        await indexer.drainForTesting()

        let batchSizes = spy.operations.compactMap { operation -> Int? in
            if case .index(let ids) = operation { return ids.count }
            return nil
        }
        XCTAssertEqual(batchSizes, [200, 50])
    }

    // MARK: - Month reports

    private var monthTrips: [TripSummary] = []
    private var monthRate = MileageRate.default

    private func makeMonthAwareIndexer() -> TripSpotlightIndexer {
        let indexer = makeIndexer()
        indexer.monthRefreshDebounce = .zero
        indexer.monthReportSource = TripSpotlightIndexer.MonthReportSource(
            fetchAll: { [weak self] in self?.monthTrips ?? [] },
            project: { [weak self] trips in
                MonthlyMileageReportEntity.entities(
                    for: trips,
                    distanceUnit: .miles,
                    rate: self?.monthRate ?? .default,
                    currencyCode: "USD"
                )
            }
        )
        return indexer
    }

    private var expectedMonthID: String {
        MonthlyMileageReportEntity.monthID(
            for: DriveMonthSummary.monthInterval(containing: start).start
        )
    }

    func testReconcileDonatesMonthReport() async {
        let indexer = makeMonthAwareIndexer()
        let business = trip(classification: .business, reviewStatus: .readyToExport)

        indexer.setEnabled(true) { [business] }
        await indexer.drainForTesting()

        XCTAssertEqual(spy.donatedReportIDs, [expectedMonthID])
    }

    func testNoteChangeRefreshesMonthReport() async {
        let indexer = makeMonthAwareIndexer()
        let upserted = trip()
        monthTrips = [upserted]

        indexer.noteChange(TripChangeSet(upserted: [upserted]))
        await indexer.drainForTesting()

        XCTAssertEqual(spy.donatedReportIDs, [expectedMonthID])
        XCTAssertEqual(spy.tripOperations, [.index([upserted.id])])
    }

    func testMonthReportRedonatedOnlyWhenContentChanges() async {
        let indexer = makeMonthAwareIndexer()
        let business = trip(classification: .business, reviewStatus: .readyToExport)

        indexer.setEnabled(true) { [business] }
        await indexer.drainForTesting()
        // Identical content: the digest matches the manifest, no re-donation.
        indexer.setEnabled(true) { [business] }
        await indexer.drainForTesting()
        XCTAssertEqual(spy.donatedReportIDs.count, 1)

        // A rate change moves the baked reimbursement text, so the digest
        // shifts and the month re-donates without any trip row changing.
        monthRate = MileageRate(amountPerUnit: 1.5, unit: .miles)
        indexer.setEnabled(true) { [business] }
        await indexer.drainForTesting()
        XCTAssertEqual(spy.donatedReportIDs.count, 2)
    }

    func testMonthReportDeletedWhenMonthEmpties() async {
        let indexer = makeMonthAwareIndexer()
        let only = trip()
        indexer.setEnabled(true) { [only] }
        await indexer.drainForTesting()

        indexer.setEnabled(true) { [] }
        await indexer.drainForTesting()

        XCTAssertEqual(spy.deletedReportIDs, [expectedMonthID])
    }

    func testDisabledIndexerSkipsMonthRefresh() async {
        enabled = false
        let indexer = makeMonthAwareIndexer()
        monthTrips = [trip()]

        indexer.noteChange(TripChangeSet(upserted: monthTrips))
        await indexer.drainForTesting()

        XCTAssertEqual(spy.operations, [])
    }

    func testMonthEntitiesExcludeNotADriveOnlyMonths() {
        let notADrive = trip(classification: .notADrive)

        let entities = MonthlyMileageReportEntity.entities(
            for: [notADrive],
            distanceUnit: .miles,
            rate: .default,
            currencyCode: "USD"
        )

        XCTAssertTrue(entities.isEmpty, "months with no countable drives are not donated")
    }
}
