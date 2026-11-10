import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// The preview line answers one question — "what does this drive still need
/// from me?" — so the most blocking answer must win.
final class DriveRowPreviewLineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    func testInboxOmitsGenericReviewCopyButKeepsMissingPurposeAndSuggestions() {
        let unclassified = makeTrip(startDate: start, miles: 5)
        XCTAssertNil(DriveRowPreviewLine.make(trip: unclassified, suggestion: nil, includesGenericReviewStatus: false))
        XCTAssertNotNil(DriveRowPreviewLine.make(trip: unclassified, suggestion: nil))

        let business = makeTrip(startDate: start, miles: 5, classification: .business)
        XCTAssertEqual(
            DriveRowPreviewLine.make(trip: business, suggestion: nil, includesGenericReviewStatus: false)?.text,
            "Add a purpose"
        )
        let suggestion = TripClassificationSuggestion(
            tripID: unclassified.id,
            classification: .personal,
            businessPurpose: nil,
            evidence: [],
            generatedAt: start
        )
        XCTAssertEqual(
            DriveRowPreviewLine.make(trip: unclassified, suggestion: suggestion, includesGenericReviewStatus: false)?.kind,
            .suggestion
        )
    }

    private func line(
        for trip: TripSummary,
        suggestion: TripClassificationSuggestion? = nil
    ) -> DriveRowPreviewLine? {
        DriveRowPreviewLine.make(
            trip: trip,
            suggestion: suggestion
        )
    }

    func testRoutineSettledStateAndEngineAttentionProduceNoPreview() {
        var trip = makeTrip(startDate: start, miles: 5, classification: .business, purpose: "Client")
        trip.needsAttention = true
        trip.attentionReasons = ["raw.reason"]

        XCTAssertNil(line(for: trip))
    }

    func testMissingBusinessPurposeOutranksUserNote() {
        var trip = makeTrip(startDate: start, miles: 5, classification: .business, purpose: nil)
        trip.notes = "Parking receipt in glovebox"

        let result = line(for: trip)

        XCTAssertEqual(result?.kind, .blocking)
        XCTAssertEqual(result?.text, String(localized: "Add a purpose"))
    }

    func testSuggestionShowsCalendarTitleInsteadOfRationaleWhileUnclassified() {
        let unclassified = makeTrip(startDate: start, miles: 5, classification: nil)
        let suggestion = TripClassificationSuggestion(
            tripID: unclassified.id,
            classification: .business,
            businessPurpose: "Photo shoot",
            rationale: "  Destination and trip note indicate\na photo assignment.  ",
            evidence: [.calendarEvent(title: "  Portrait session\nwith Harper  ")],
            generatedAt: start
        )

        let result = line(for: unclassified, suggestion: suggestion)
        XCTAssertEqual(result?.kind, .suggestion)
        XCTAssertEqual(result?.systemImage, "sparkles")
        XCTAssertEqual(result?.suggestedClassification, .business)
        XCTAssertEqual(result?.text, "Business")
        XCTAssertEqual(result?.detail, "Portrait session with Harper")
        XCTAssertEqual(
            result?.inlineText,
            "Portrait session with Harper"
        )
        XCTAssertFalse(result?.inlineText.contains("\n") == true)
        XCTAssertEqual(
            result?.accessibilityText,
            "Suggested: Business, Portrait session with Harper"
        )

        let classified = makeTrip(startDate: start, miles: 5, classification: .personal, reviewStatus: .readyToExport)
        XCTAssertNil(line(for: classified, suggestion: suggestion))
    }

    func testPersonalSuggestionUsesCalendarTitleWithoutPurposeOrExplanation() {
        let trip = makeTrip(startDate: start, miles: 5, classification: nil)
        let suggestion = TripClassificationSuggestion(
            tripID: trip.id,
            classification: .personal,
            businessPurpose: "Must not appear",
            rationale: "A personal activity near the destination",
            evidence: [.calendarEvent(title: "Yoga class")],
            generatedAt: start
        )

        let result = line(for: trip, suggestion: suggestion)
        XCTAssertEqual(result?.text, "Personal")
        XCTAssertEqual(result?.detail, "Yoga class")
        XCTAssertEqual(result?.inlineText, "Yoga class")
        XCTAssertEqual(result?.systemImage, "sparkles")
        XCTAssertFalse(result?.inlineText.contains("Must not appear") == true)
    }

    func testCalendarFreeSuggestionDoesNotDisplayPurposeOrRationale() {
        let trip = makeTrip(startDate: start, miles: 5, classification: nil)
        let suggestion = TripClassificationSuggestion(
            tripID: trip.id,
            classification: .business,
            businessPurpose: "Photo shoot",
            rationale: "This generated explanation is much too long for the compact single line suggestion capsule.",
            evidence: [],
            generatedAt: start
        )

        let result = line(for: trip, suggestion: suggestion)
        XCTAssertEqual(result?.inlineText, "Business")
        XCTAssertFalse(result?.inlineText.contains("generated explanation") == true)
    }

    func testCalendarFreeSuggestionKeepsClassificationAccessible() {
        let trip = makeTrip(startDate: start, miles: 5, classification: nil)
        let suggestion = TripClassificationSuggestion(
            tripID: trip.id,
            classification: .business,
            businessPurpose: nil,
            evidence: [],
            generatedAt: start
        )

        let result = line(for: trip, suggestion: suggestion)
        XCTAssertEqual(result?.text, "Business")
        XCTAssertNil(result?.detail)
        XCTAssertEqual(result?.inlineText, "Business")
        XCTAssertEqual(result?.systemImage, "sparkles")
        XCTAssertEqual(result?.accessibilityText, "Suggested: Business")
    }

    func testUnclassifiedWithoutSuggestionShowsBlockingReviewMessage() {
        let trip = makeTrip(startDate: start, miles: 5, classification: nil)

        XCTAssertEqual(line(for: trip)?.kind, .blocking)
        XCTAssertEqual(line(for: trip)?.text, String(localized: "Need Review"))
        XCTAssertNil(line(for: trip)?.systemImage)
    }

    func testSharedTimelineKeepsRangeAndDurationOnOneLine() {
        let label = TripHierarchyPresentation.timelineLabel(
            startDate: start,
            endDate: start.addingTimeInterval(11 * 60)
        )

        XCTAssertTrue(label.contains(" – "))
        XCTAssertTrue(label.contains(" · "))
        XCTAssertFalse(label.contains("\n"))
    }

    func testSettledBusinessPurposeIsNotRepeatedInPreview() {
        let business = makeTrip(
            startDate: start,
            miles: 5,
            classification: .business,
            reviewStatus: .readyToExport,
            purpose: "Portrait session"
        )
        let personal = makeTrip(
            startDate: start,
            miles: 5,
            classification: .personal,
            reviewStatus: .readyToExport
        )
        let notADrive = makeTrip(
            startDate: start,
            miles: 0.3,
            classification: .notADrive,
            reviewStatus: .readyToExport
        )

        XCTAssertNil(line(for: business))
        XCTAssertNil(line(for: personal))
        XCTAssertNil(line(for: notADrive))
    }

    func testUserNoteIsTheOnlySettledPreviewText() {
        var trip = makeTrip(startDate: start, miles: 5, classification: .personal, reviewStatus: .readyToExport)
        trip.notes = "  Picked up client prints  \n"

        XCTAssertEqual(line(for: trip)?.kind, .note)
        XCTAssertEqual(line(for: trip)?.text, "Picked up client prints")
    }

    func testAutomaticProvenanceDoesNotCreatePreviewText() {
        var trip = makeTrip(startDate: start, miles: 0.3, classification: .notADrive, reviewStatus: .readyToExport)
        trip.classificationSource = .autoTransit

        XCTAssertNil(line(for: trip))
    }
}
