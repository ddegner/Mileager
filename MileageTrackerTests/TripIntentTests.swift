import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class TripIntentTests: XCTestCase {
    private var model: MileageAppModel!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        TripIntentDataProvider.isReady = { _ in true }
        let defaults = try makeTestDefaults()
        model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )
        TripIntentDataProvider.modelProvider = { [weak model] in model }
    }

    override func tearDown() async throws {
        TripIntentDataProvider.resetForTesting()
        model = nil
        try await super.tearDown()
    }

    @discardableResult
    private func seedTrip(
        classification: TripClassification? = nil,
        offset: TimeInterval = 0,
        duration: TimeInterval = 1_800,
        startAddress: String = "145 Court St, Brooklyn, NY",
        endAddress: String = "9 Pine St, Darien, CT",
        notes: String? = nil
    ) throws -> TripSummary {
        let trip = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: start.addingTimeInterval(offset),
            endDate: start.addingTimeInterval(offset + duration),
            startAddress: startAddress,
            endAddress: endAddress,
            distanceMeters: DistanceConversion.meters(fromMiles: 18),
            classification: classification,
            notes: notes
        ))
        model.refresh()
        return trip
    }

    private func useSeededCurrentDriveModel() async throws {
        let defaults = try makeTestDefaults()
        model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--skip-onboarding",
                "--seed-current-drive"
            ]),
            preferences: Preferences(defaults: defaults)
        )
        TripIntentDataProvider.modelProvider = { [weak model] in model }
        await model.startup()
        XCTAssertNotNil(model.currentDrive)
    }

    // MARK: - Query

    func testEntitiesForIdentifiersResolvesSeededTrips() async throws {
        let trip = try seedTrip()

        let entities = try await TripAppEntityQuery().entities(for: [trip.id, UUID()])

        XCTAssertEqual(entities.map(\.id), [trip.id])
        XCTAssertEqual(entities.first?.originLabel.isEmpty, false)
    }

    func testSuggestedEntitiesPutUnclassifiedFirst() async throws {
        let classified = try seedTrip(classification: .business)
        let unclassified = try seedTrip(offset: 3_600)

        let suggested = try await TripAppEntityQuery().suggestedEntities()

        XCTAssertEqual(suggested.first?.id, unclassified.id)
        XCTAssertTrue(suggested.map(\.id).contains(classified.id))
    }

    func testStringQueryMatchesAddressAndNotes() async throws {
        let darien = try seedTrip()
        let boston = try seedTrip(
            offset: 3_600,
            startAddress: "1 City Hall Square, Boston, MA",
            endAddress: "465 Huntington Ave, Boston, MA",
            notes: "MFA member event"
        )

        let byAddress = try await TripAppEntityQuery().entities(matching: "darien")
        let byNotes = try await TripAppEntityQuery().entities(matching: "MFA member")

        XCTAssertEqual(byAddress.map(\.id), [darien.id])
        XCTAssertEqual(byNotes.map(\.id), [boston.id])
    }

    func testStringQueryResolvesRecentDriveAndTripReferencesToNewestCompletedTrip() async throws {
        _ = try seedTrip(offset: -3_600)
        let newest = try seedTrip(offset: 3_600)
        let query = TripAppEntityQuery()

        for reference in [
            "last drive",
            "my previous drive",
            "latest drive",
            "most recent completed drive",
            "the drive I just finished",
            "last trip",
            "my previous trip",
            "latest trip",
            "most recent completed trip",
            "the trip I just finished"
        ] {
            let matches = try await query.entities(matching: reference)
            XCTAssertEqual(matches.map(\.id), [newest.id], "Failed reference: \(reference)")
            XCTAssertEqual(matches.first?.isMostRecentReference, true)
            XCTAssertEqual(matches.first?.displayRepresentation.synonyms.count, 10)
        }
    }

    func testMostRecentCompletedTripUsesEndDateForOverlappingCaptures() async throws {
        let finishesLast = try seedTrip(offset: 0, duration: 3_600)
        _ = try seedTrip(offset: 1_800, duration: 300)

        let selected = try TripIntentDataProvider.mostRecentTrip(
            in: model,
            excludingNotADrive: true
        )
        let matches = try await TripAppEntityQuery()
            .entities(matching: "most recent completed drive")

        XCTAssertEqual(selected.id, finishesLast.id)
        XCTAssertEqual(matches.map(\.id), [finishesLast.id])
    }

    func testQueriesReturnEmptyWhenStoreUnavailable() async throws {
        try seedTrip()
        TripIntentDataProvider.modelProvider = { nil }

        let entities = try await TripAppEntityQuery().entities(for: [UUID()])
        let suggested = try await TripAppEntityQuery().suggestedEntities()
        let matched = try await TripAppEntityQuery().entities(matching: "Darien")

        XCTAssertTrue(entities.isEmpty)
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertTrue(matched.isEmpty)
    }

    func testCurrentDriveEntityQueryResolvesCurrentAndContextNames() async throws {
        try await useSeededCurrentDriveModel()
        let current = try XCTUnwrap(model.currentDrive)
        let query = CurrentDriveAppEntityQuery()

        let suggested = try await query.suggestedEntities()
        let byID = try await query.entities(for: [current.pendingTripID])
        let byCurrentDrive = try await query.entities(matching: "current drive")
        let byThisDrive = try await query.entities(matching: "this drive")
        let byMyCurrentDrive = try await query.entities(matching: "my current drive")
        let byCurrentTrip = try await query.entities(matching: "current trip")
        let byThisTrip = try await query.entities(matching: "this trip")
        let byOngoingDrive = try await query.entities(matching: "ongoing drive")
        let byDriveImOn = try await query.entities(matching: "drive I'm on")
        let unrelated = try await query.entities(matching: "last report")

        XCTAssertEqual(suggested.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byID.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byCurrentDrive.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byThisDrive.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byMyCurrentDrive.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byCurrentTrip.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byThisTrip.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byOngoingDrive.map(\.id), [current.pendingTripID])
        XCTAssertEqual(byDriveImOn.map(\.id), [current.pendingTripID])
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertEqual(suggested.first?.displayRepresentation.synonyms.count, 13)
    }

    func testCurrentDriveEntityQueryHasNoSuggestionsAndRejectsMissingExplicitID() async throws {
        let query = CurrentDriveAppEntityQuery()

        let suggested = try await query.suggestedEntities()
        let matched = try await query.entities(matching: "current drive")

        XCTAssertTrue(suggested.isEmpty)
        XCTAssertTrue(matched.isEmpty)
        do {
            _ = try await query.entities(for: [UUID()])
            XCTFail("An explicit missing drive must not become an omitted parameter")
        } catch TripIntentError.currentDriveNotFound { }
    }

    func testCurrentDriveEntityQueryRejectsAnyExpiredExplicitID() async throws {
        try await useSeededCurrentDriveModel()
        let current = try XCTUnwrap(model.currentDrive)
        let query = CurrentDriveAppEntityQuery()
        for ids in [[UUID()], [current.pendingTripID, UUID()]] {
            do {
                _ = try await query.entities(for: ids)
                XCTFail("An expired ID must not be silently dropped during resolution")
            } catch TripIntentError.currentDriveNotFound { }
        }
        let empty = try await query.entities(for: [])
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Classify intent

    func testClassifyIntentSetsClassificationAndDefaultsPurpose() async throws {
        let trip = try seedTrip()
        let intent = SetTripClassificationIntent()
        intent.trip = TripAppEntity(trip)
        intent.classification = .business

        _ = try await intent.perform()

        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(updated.classification, .business)
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertTrue(model.trips.contains { $0.id == trip.id && $0.classification == .business })
    }

    func testClassifyIntentUsesProvidedPurpose() async throws {
        let trip = try seedTrip()
        let intent = SetTripClassificationIntent()
        intent.trip = TripAppEntity(trip)
        intent.classification = .business
        intent.businessPurpose = "Site survey"

        _ = try await intent.perform()

        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(updated.businessPurpose, "Site survey")
    }

    func testClassifyMostRecentTripIntentOnlyUpdatesNewestCompletedTrip() async throws {
        let older = try seedTrip(offset: -3_600)
        let newest = try seedTrip(offset: 3_600)
        let intent = ClassifyMostRecentTripIntent(classification: .personal)

        _ = try await intent.perform()

        let unchanged = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: older.id))
        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: newest.id))
        XCTAssertNil(unchanged.classification)
        XCTAssertEqual(updated.classification, .personal)
    }

    func testLastDriveDurationIntentLeavesTripUnchanged() async throws {
        let newest = try seedTrip(offset: 3_600)
        let before = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: newest.id))
        let intent = LastDriveDurationIntent()

        _ = try await intent.perform()

        let unchanged = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: newest.id))
        XCTAssertNil(unchanged.classification)
        XCTAssertEqual(unchanged.durationSeconds, 1_800, accuracy: 0.001)
        XCTAssertEqual(unchanged.updatedAt, before.updatedAt)
    }

    func testClassifyMostRecentTripIntentStillUpdatesOnlyNewestTrip() async throws {
        let older = try seedTrip(offset: -3_600)
        let newest = try seedTrip(offset: 3_600)
        let intent = ClassifyMostRecentTripIntent(classification: .personal)

        _ = try await intent.perform()

        let unchanged = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: older.id))
        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: newest.id))
        XCTAssertNil(unchanged.classification)
        XCTAssertEqual(updated.classification, .personal)
    }

    func testLastDriveDurationIntentThrowsWhenThereAreNoCompletedDrives() async throws {
        let intent = LastDriveDurationIntent()

        do {
            _ = try await intent.perform()
            XCTFail("Expected noCompletedTrips")
        } catch let error as TripIntentError {
            guard case .noCompletedTrips = error else {
                return XCTFail("Expected noCompletedTrips, got \(error)")
            }
        }
    }

    func testClassifyIntentThrowsWhenStoreUnavailable() async throws {
        let trip = try seedTrip()
        TripIntentDataProvider.modelProvider = { nil }
        let intent = SetTripClassificationIntent()
        intent.trip = TripAppEntity(trip)
        intent.classification = .personal

        do {
            _ = try await intent.perform()
            XCTFail("Expected startupUnavailable")
        } catch let error as TripIntentError {
            guard case .startupUnavailable = error else {
                return XCTFail("Expected startupUnavailable, got \(error)")
            }
        }
    }

    func testClassifyIntentThrowsForDeletedTrip() async throws {
        let trip = try seedTrip()
        try model.tripStore.deleteTrip(id: trip.id)
        let intent = SetTripClassificationIntent()
        intent.trip = TripAppEntity(trip)
        intent.classification = .business

        do {
            _ = try await intent.perform()
            XCTFail("Expected tripNotFound")
        } catch let error as TripIntentError {
            guard case .tripNotFound = error else {
                return XCTFail("Expected tripNotFound, got \(error)")
            }
        }
    }

    // MARK: - Fee intents

    func testAddTripFeeIntentAddsCompletedTripFee() async throws {
        let trip = try seedTrip()
        let intent = AddTripFeeIntent()
        intent.trip = TripAppEntity(trip)
        intent.category = .toll
        intent.amount = 7.25
        intent.label = "Bridge"
        intent.occurredAt = start.addingTimeInterval(300)

        _ = try await intent.perform()

        let fees = try model.tripStore.fetchFees(tripID: trip.id)
        XCTAssertEqual(fees.count, 1)
        XCTAssertEqual(fees.first?.category, .toll)
        XCTAssertEqual(fees.first?.amount, 7.25)
        XCTAssertEqual(fees.first?.label, "Bridge")
        XCTAssertEqual(fees.first?.source, .manual)
        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(updated.tollsAmount, 7.25)
    }

    func testAddTripFeeIntentRejectsInvalidAmount() async throws {
        let trip = try seedTrip()
        let intent = AddTripFeeIntent()
        intent.trip = TripAppEntity(trip)
        intent.category = .parking
        intent.amount = 0

        do {
            _ = try await intent.perform()
            XCTFail("Expected invalidAmount")
        } catch let error as TripIntentError {
            guard case .invalidAmount = error else {
                return XCTFail("Expected invalidAmount, got \(error)")
            }
        }
    }

    // MARK: - Current drive intents

    func testAddCurrentDriveFeeIntentAddsPendingFee() async throws {
        try await useSeededCurrentDriveModel()
        let intent = AddCurrentDriveFeeIntent()
        intent.category = .parking
        intent.amount = 12
        intent.label = "Garage"
        intent.occurredAt = start

        _ = try await intent.perform()

        XCTAssertEqual(model.currentDrive?.feeCount, 1)
    }

    func testAddCurrentDriveFeeIntentThrowsWithoutCurrentDrive() async throws {
        let intent = AddCurrentDriveFeeIntent()
        intent.category = .toll
        intent.amount = 5

        do {
            _ = try await intent.perform()
            XCTFail("Expected currentDriveNotFound")
        } catch let error as TripIntentError {
            guard case .currentDriveNotFound = error else {
                return XCTFail("Expected currentDriveNotFound, got \(error)")
            }
        }
    }

    func testClassifyCurrentDriveIntentSetsCategoryAndPurpose() async throws {
        try await useSeededCurrentDriveModel()
        let current = try XCTUnwrap(model.currentDrive)
        let intent = ClassifyCurrentDriveIntent()
        intent.drive = CurrentDriveAppEntity(current)
        intent.classification = .business
        intent.businessPurpose = "Client visit"

        _ = try await intent.perform()

        XCTAssertEqual(model.currentDrive?.classification, .business)
        XCTAssertEqual(model.currentDrive?.businessPurpose, "Client visit")
    }

    func testCurrentDriveIntentRejectsStaleEntityReference() async throws {
        try await useSeededCurrentDriveModel()
        var stale = try XCTUnwrap(model.currentDrive)
        stale.pendingTripID = UUID()
        let intent = ClassifyCurrentDriveIntent()
        intent.drive = CurrentDriveAppEntity(stale)
        intent.classification = .personal

        do {
            _ = try await intent.perform()
            XCTFail("Expected currentDriveNotFound")
        } catch let error as TripIntentError {
            guard case .currentDriveNotFound = error else {
                return XCTFail("Expected currentDriveNotFound, got \(error)")
            }
        }
        XCTAssertNil(model.currentDrive?.classification)
    }

    func testSetCurrentDrivePurposeMarksDriveBusiness() async throws {
        try await useSeededCurrentDriveModel()
        let intent = SetCurrentDrivePurposeIntent()
        intent.purpose = "Site survey"

        _ = try await intent.perform()

        XCTAssertEqual(model.currentDrive?.classification, .business)
        XCTAssertEqual(model.currentDrive?.businessPurpose, "Site survey")
    }

    func testAddCurrentDriveNoteIntentAppendsNotes() async throws {
        try await useSeededCurrentDriveModel()
        let first = AddCurrentDriveNoteIntent()
        first.note = "Met client"
        _ = try await first.perform()

        let second = AddCurrentDriveNoteIntent()
        second.note = "Garage level 2"
        _ = try await second.perform()

        XCTAssertEqual(model.currentDrive?.note, "Met client\nGarage level 2")
    }

    // MARK: - Open intent

    func testOpenIntentRequestsTripDetail() async throws {
        let trip = try seedTrip()
        let intent = OpenTripIntent()
        intent.target = TripAppEntity(trip)

        _ = try await intent.perform()

        XCTAssertEqual(model.requestedTripDetailID, trip.id)
    }

    func testOpenIntentThrowsForDeletedTrip() async throws {
        let trip = try seedTrip()
        try model.tripStore.deleteTrip(id: trip.id)
        let intent = OpenTripIntent()
        intent.target = TripAppEntity(trip)

        do {
            _ = try await intent.perform()
            XCTFail("Expected tripNotFound")
        } catch let error as TripIntentError {
            guard case .tripNotFound = error else {
                return XCTFail("Expected tripNotFound, got \(error)")
            }
        }
        XCTAssertNil(model.requestedTripDetailID)
    }
}
