import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class PersistenceControllerScopeTests: XCTestCase {
    func testDefaultScopeLoadsCloudAndLocalStores() throws {
        let persistence = try PersistenceController(inMemory: true)

        XCTAssertEqual(
            Set(persistence.container.persistentStoreCoordinator.persistentStores.map(\.configurationName)),
            [PersistenceController.cloudConfigurationName, PersistenceController.localConfigurationName]
        )
        XCTAssertTrue(persistence.hasLoadedStore(configurationName: PersistenceController.cloudConfigurationName))
        XCTAssertTrue(persistence.hasLoadedStore(configurationName: PersistenceController.localConfigurationName))
    }

    func testCloudOnlyScopeLoadsOnlyCloudStore() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)

        XCTAssertEqual(
            persistence.container.persistentStoreCoordinator.persistentStores.map(\.configurationName),
            [PersistenceController.cloudConfigurationName]
        )
        XCTAssertTrue(persistence.hasLoadedStore(configurationName: PersistenceController.cloudConfigurationName))
        XCTAssertFalse(persistence.hasLoadedStore(configurationName: PersistenceController.localConfigurationName))
    }

    func testCloudOnlyStoreSupportsCloudWorkflowsAndDeleteAllData() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(manualTrip(start: start))

        let reviewed = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .business, businessPurpose: "Client visit")
        )
        _ = try store.addFee(TripFee(
            tripID: trip.id,
            category: .parking,
            amount: 12,
            occurredAt: start.addingTimeInterval(300),
            label: "Garage"
        ))
        // Imported-source fee written directly: the E-ZPass CSV importer was
        // retired with the native Mac app, but fees already carrying
        // `.ezPassImport` still live in synced stores and must round-trip.
        _ = try store.addFee(TripFee(
            tripID: trip.id,
            category: .toll,
            amount: 4.50,
            occurredAt: start.addingTimeInterval(600),
            source: .ezPassImport,
            sourceTransactionID: "cloud-only-toll",
            tagOrPlate: "TEST",
            agency: "Test Toll",
            importedAt: start
        ))
        _ = try store.addOdometerCheckpoint(OdometerCheckpoint(date: start, odometerMiles: 10_000))

        let report = try ReportGenerator().makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: try store.fetchOdometerCheckpoints(),
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(86_400),
            rate: .default,
            formatting: ReportFormattingContext(
                locale: Locale(identifier: "en_US"),
                distanceUnit: .miles,
                currencyCode: "USD"
            )
        )

        XCTAssertEqual(reviewed.classification, .business)
        XCTAssertEqual(try store.fetchFees(tripID: trip.id).count, 2)
        XCTAssertEqual(try store.rawSampleCount(), 0)
        XCTAssertEqual(try store.purgeExpiredRawSamples(), 0)
        XCTAssertFalse(report.pdfData.isEmpty)

        try persistence.deleteAllData()

        XCTAssertTrue(try store.fetchTrips().isEmpty)
        XCTAssertTrue(try store.fetchFees(includeUnlinked: true).isEmpty)
        XCTAssertTrue(try store.fetchOdometerCheckpoints().isEmpty)
    }

    func testCloudOnlyMergeUnmergeDuplicateAndDeleteSkipRawStore() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.createManualTrip(manualTrip(start: start, origin: "Home", destination: "Client"))
        let second = try store.createManualTrip(manualTrip(
            start: start.addingTimeInterval(3_600),
            origin: "Client",
            destination: "Office"
        ))

        let duplicate = try store.duplicateTrip(id: first.id)
        try store.deleteTrip(id: duplicate.id)
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        let restored = try store.unmergeTrip(id: merged.id)

        XCTAssertEqual(Set(restored.map(\.id)), [first.id, second.id])
        XCTAssertEqual(try store.rawSampleCount(), 0)
        XCTAssertEqual(try store.fetchTrips().count, 2)
    }

    func testCloudOnlyCaptureWithSamplesThrowsAndRollsBack() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: [
                LocationSample(timestamp: start, latitude: 42.3601, longitude: -71.0589, horizontalAccuracy: 8),
                LocationSample(
                    timestamp: start.addingTimeInterval(120),
                    latitude: 42.3701,
                    longitude: -71.0489,
                    horizontalAccuracy: 8
                )
            ],
            distanceMeters: 1_500
        )

        XCTAssertThrowsError(try store.saveCompletedTrip(draft)) { error in
            guard case TripStoreError.rawSampleStoreUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(try store.fetchTripIfExists(id: draft.id))
        XCTAssertEqual(try store.rawSampleCount(), 0)
    }

    func testTripRowProjectionMatchesScalarTripFields() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let created = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Home",
            endAddress: "Client",
            distanceMeters: 9_000,
            classification: .business,
            businessPurpose: "Site visit",
            notes: "Bring plans"
        ))
        _ = try store.updateReview(
            tripID: created.id,
            update: ReviewUpdate(manualDistanceOverrideMeters: 10_000)
        )
        _ = try store.addFee(TripFee(
            tripID: created.id,
            category: .parking,
            amount: 8,
            occurredAt: start.addingTimeInterval(300)
        ))

        let summary = try store.fetchTrip(id: created.id)
        let row = try XCTUnwrap(store.fetchTripRows().first)

        XCTAssertEqual(row.id, summary.id)
        XCTAssertEqual(row.startDate, summary.startDate)
        XCTAssertEqual(row.endDate, summary.endDate)
        XCTAssertEqual(row.startAddress, summary.startAddress)
        XCTAssertEqual(row.endAddress, summary.endAddress)
        XCTAssertEqual(row.distanceMeters, summary.reportableDistanceMeters)
        XCTAssertEqual(row.classification, summary.classification)
        XCTAssertEqual(row.reviewStatus, summary.reviewStatus)
        XCTAssertEqual(row.businessPurpose, summary.businessPurpose)
        XCTAssertEqual(row.notes, summary.notes)
        XCTAssertEqual(row.hasNotes, true)
        XCTAssertEqual(row.tollsAmount, summary.tollsAmount)
        XCTAssertEqual(row.parkingAmount, summary.parkingAmount)
        XCTAssertEqual(row.needsAttention, summary.needsAttention)
        XCTAssertEqual(row.captureSource, summary.captureSource)
        XCTAssertEqual(row.updatedAt, summary.updatedAt)
        XCTAssertEqual(row, TripRowProjection(trip: summary))
    }

    func testTripIndexProjectionMatchesAllowlistedTripFields() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let created = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(2_400),
            startCoordinate: Coordinate(latitude: 42.3601, longitude: -71.0589),
            endCoordinate: Coordinate(latitude: 42.3736, longitude: -71.1097),
            startAddress: "1 Main St, Boston, MA",
            endAddress: "2 Client Ave, Cambridge, MA",
            distanceMeters: 8_000,
            routePolyline: EncodedPolyline.encode([
                Coordinate(latitude: 42.3601, longitude: -71.0589),
                Coordinate(latitude: 42.3736, longitude: -71.1097)
            ]),
            classification: .business,
            businessPurpose: "Client meeting",
            notes: "Discuss the signed estimate"
        ))
        _ = try store.updateReview(
            tripID: created.id,
            update: ReviewUpdate(manualDistanceOverrideMeters: 9_000)
        )
        _ = try store.appendAttentionReason(tripID: created.id, reason: "Verify destination")
        _ = try store.addFee(TripFee(
            tripID: created.id,
            category: .toll,
            amount: 7.50,
            occurredAt: start
        ))
        _ = try store.addFee(TripFee(
            tripID: created.id,
            category: .parking,
            amount: 12,
            occurredAt: start
        ))

        let summary = try store.fetchTrip(id: created.id)
        let projection = try XCTUnwrap(store.fetchTripIndexProjections().first)

        XCTAssertEqual(projection, TripIndexProjection(trip: summary))
        XCTAssertEqual(projection.distanceMeters, 9_000)
        XCTAssertEqual(projection.attentionReasons, ["Verify destination"])
        XCTAssertEqual(projection.notes, "Discuss the signed estimate")
        XCTAssertEqual(projection.tollsAmount, 7.50)
        XCTAssertEqual(projection.parkingAmount, 12)
        let rate = MileageRate(amountPerUnit: 0.725, unit: .miles)
        XCTAssertEqual(
            projection.mileageValue(at: rate),
            CurrencyRounding.cents(9_000 * rate.amountPerMeter)
        )
    }

    func testTripIndexProjectionFetchExcludesPrivateRouteAndCaptureFields() {
        let fetched = Set(TripStore.tripIndexProjectionPropertyNames)
        let forbidden: Set<String> = [
            "startLatitude",
            "startLongitude",
            "endLatitude",
            "endLongitude",
            "startAddressComponentsData",
            "endAddressComponentsData",
            "routePolyline",
            "legsData",
            "connectorsData",
            "startBluetoothHintHashesData",
            "lastEditedAt",
            "lastEditedDeviceName"
        ]

        XCTAssertTrue(fetched.isDisjoint(with: forbidden))
        XCTAssertEqual(
            fetched,
            [
                "id", "createdAt", "updatedAt", "startDate", "endDate",
                "startAddress", "endAddress", "distanceMeters", "durationSeconds",
                "manualDistanceOverrideMeters", "classificationRaw",
                "classificationSourceRaw", "reviewStatusRaw", "businessPurpose",
                "notes", "tollsAmount", "parkingAmount", "needsAttention",
                "attentionReasonsData", "vehicleID", "captureSource"
            ]
        )
    }

    func testTripIndexProjectionIdentifierFetchPreservesRequestedOrder() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let first = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            distanceMeters: 1_000
        ))
        let second = try store.createManualTrip(ManualTripInput(
            startDate: start.addingTimeInterval(3_600),
            endDate: start.addingTimeInterval(4_200),
            distanceMeters: 2_000
        ))

        XCTAssertEqual(
            try store.fetchTripIndexProjections(ids: [first.id, second.id, UUID()]).map(\.id),
            [first.id, second.id]
        )
        XCTAssertTrue(try store.fetchTripIndexProjections(ids: []).isEmpty)
    }

    func testTripProjectionsChooseNewestDuplicateBeforeApplyingFilters() throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_400_000)
        let id = UUID()
        _ = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            startAddress: "Older revision",
            endAddress: "Destination",
            distanceMeters: 1_000
        ), id: id)
        let originalRequest = TripEntity.fetchRequest()
        originalRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let original = try XCTUnwrap(context.fetch(originalRequest).first)
        let tiedUpdateDate = start.addingTimeInterval(60)
        original.createdAt = start
        original.updatedAt = tiedUpdateDate

        let newest = TripEntity.insert(into: context)
        newest.id = id
        newest.createdAt = start.addingTimeInterval(1)
        newest.updatedAt = tiedUpdateDate
        newest.captureSource = "manual"
        newest.startDate = start.addingTimeInterval(3_600)
        newest.endDate = start.addingTimeInterval(4_200)
        newest.startAddress = "Newest revision"
        newest.endAddress = "Destination"
        newest.distanceMeters = 2_000
        newest.durationSeconds = 600
        newest.reviewStatus = .needsReview
        newest.tollsAmount = 0
        newest.parkingAmount = 0
        newest.needsAttention = false
        try context.save()

        // The window covers the older revision and excludes the newer one.
        // Deduplicating first picks the newest revision, which then fails the
        // window and yields nothing; filtering first would let the older
        // revision survive and report a trip that no longer exists.
        let windowEnd = start.addingTimeInterval(600)
        XCTAssertTrue(try store.fetchTripRows(from: start, to: windowEnd).isEmpty)
        XCTAssertTrue(try store.fetchTripIndexProjections(from: start, to: windowEnd).isEmpty)
        XCTAssertTrue(try store.fetchTrips(from: start, to: windowEnd).isEmpty)

        let rows = try store.fetchTripRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.startAddress, "Newest revision")
        XCTAssertEqual(rows.first?.distanceMeters, 2_000)

        let indexed = try store.fetchTripIndexProjections(
            ids: [id, id]
        )
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.startAddress, "Newest revision")
        XCTAssertEqual(indexed.first?.distanceMeters, 2_000)

        let summaries = try store.fetchTrips()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.startAddress, "Newest revision")
        XCTAssertEqual(try store.fetchTrip(id: id).startAddress, "Newest revision")

        try store.deleteTrip(id: id)
        XCTAssertTrue(try store.fetchTrips().isEmpty)
    }

    private func manualTrip(
        start: Date,
        origin: String = "Home",
        destination: String = "Client"
    ) -> ManualTripInput {
        ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: origin,
            endAddress: destination,
            distanceMeters: DistanceConversion.meters(fromMiles: 10)
        )
    }
}
