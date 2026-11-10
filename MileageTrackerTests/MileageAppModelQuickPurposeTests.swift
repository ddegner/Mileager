import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// `updateQuickPurpose` powers the Purpose quick-entry sheet. Assigning a
/// business purpose there must also classify the drive as business (a business
/// purpose only applies to business drives), while clearing the purpose must
/// leave any existing classification untouched.
@MainActor
final class MileageAppModelQuickPurposeTests: XCTestCase {
    func testAssigningQuickPurposeClassifiesUnreviewedTripAsBusiness() throws {
        let model = try makeModel()
        let trip = try makeUnreviewedTrip(model: model)
        XCTAssertNil(trip.classification)
        XCTAssertEqual(trip.reviewStatus, .needsReview)

        model.updateQuickPurpose(trip, purpose: "Client Visit")

        let updated = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(updated.classification, .business)
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertEqual(updated.businessPurpose, "Client Visit")
    }

    func testAssigningQuickPurposeTrimsSurroundingWhitespace() throws {
        let model = try makeModel()
        let trip = try makeUnreviewedTrip(model: model)

        model.updateQuickPurpose(trip, purpose: "  Site Scouting  ")

        let updated = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(updated.classification, .business)
        XCTAssertEqual(updated.businessPurpose, "Site Scouting")
    }

    func testClearingQuickPurposeKeepsBusinessClassification() throws {
        let model = try makeModel()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 5,
            origin: "Start",
            destination: "End",
            classification: .business,
            purpose: "Client Visit",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        model.refresh()
        let business = try XCTUnwrap(model.trip(id: created.id))
        XCTAssertEqual(business.classification, .business)
        XCTAssertEqual(business.businessPurpose, "Client Visit")

        model.updateQuickPurpose(business, purpose: "")

        let cleared = try XCTUnwrap(model.trip(id: created.id))
        XCTAssertEqual(cleared.classification, .business)
        XCTAssertNil(cleared.businessPurpose)
        XCTAssertEqual(cleared.reviewStatus, .needsReview)
        XCTAssertTrue(cleared.isUnresolved)
        XCTAssertFalse(cleared.isExportableBusiness)
    }

    func testClearingQuickPurposeLeavesUnreviewedTripUnclassified() throws {
        let model = try makeModel()
        let trip = try makeUnreviewedTrip(model: model)

        model.updateQuickPurpose(trip, purpose: "")

        let updated = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertNil(updated.classification)
        XCTAssertNil(updated.businessPurpose)
        XCTAssertEqual(updated.reviewStatus, .needsReview)
    }

    func testAssigningQuickPurposeTrainsTrustedVehicleLearning() throws {
        let model = try makeModel()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // An observation within the 10-minute window before the trip's start
        // feeds the learning engine when the drive is confirmed as business.
        _ = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)

        model.updateQuickPurpose(trip, purpose: "Client Visit")

        let hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 0)
    }

    func testBulkPurposeClassifiesEveryTripAndCommitsAsOneDomainMutation() throws {
        let model = try makeModel()
        let first = try makeUnreviewedTrip(model: model)
        let second = try makeUnreviewedTrip(
            model: model,
            start: Date(timeIntervalSince1970: 1_800_100_000)
        )

        model.updatePurpose(tripIDs: [second.id, first.id], purpose: "  Client visits  ")

        for id in [first.id, second.id] {
            let updated = try XCTUnwrap(model.trip(id: id))
            XCTAssertEqual(updated.classification, .business)
            XCTAssertEqual(updated.businessPurpose, "Client visits")
            XCTAssertEqual(updated.reviewStatus, .readyToExport)
            XCTAssertTrue(updated.isExportableBusiness)
        }
    }

    func testBulkPurposeAndDeleteRejectWholeRequestWhenAnyTripIsMissing() throws {
        let model = try makeModel()
        let trip = try makeUnreviewedTrip(model: model)

        model.updatePurpose(tripIDs: [trip.id, UUID()], purpose: "Client visit")

        var preserved = try model.tripStore.fetchTrip(id: trip.id)
        XCTAssertNil(preserved.classification)
        XCTAssertNil(preserved.businessPurpose)

        model.delete(tripIDs: [trip.id, UUID()])

        preserved = try model.tripStore.fetchTrip(id: trip.id)
        XCTAssertEqual(preserved.id, trip.id)
    }

    // MARK: - Helpers

    private func makeModel() throws -> MileageAppModel {
        let defaults = try makeTestDefaults()
        return MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
    }

    @discardableResult
    private func makeUnreviewedTrip(
        model: MileageAppModel,
        start: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> TripSummary {
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 5,
            origin: "Start",
            destination: "End",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        model.refresh()
        return try XCTUnwrap(model.trip(id: created.id))
    }
}
