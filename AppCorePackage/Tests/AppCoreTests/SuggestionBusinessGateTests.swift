import AppCoreModels
import XCTest
@testable import AppCoreEnrichment
@testable import AppCoreSuggestions

final class SuggestionBusinessGateTests: XCTestCase {
    func testBusinessWithoutCalendarCitationRequiresNotesOrWorkplace() {
        XCTAssertNil(adjusted(hasNotes: false, destinationIsWorkplace: false))
        XCTAssertEqual(adjusted(hasNotes: true, destinationIsWorkplace: false), 5)
        XCTAssertEqual(adjusted(hasNotes: false, destinationIsWorkplace: true), 5)
    }

    func testDirectHomeWorkTripCannotSuggestBusinessEvenWithWorkEvent() {
        XCTAssertNil(SuggestionBusinessGate.adjustedConfidence(
            classification: "business", cited: event(isLinked: true),
            citedEventNature: "work-engagement", confidence: 5,
            hasNotes: true, destinationIsWorkplace: true, isDirectHomeWorkTrip: true
        ))
    }

    func testPersonalContactDoesNotStandInForWorkplace() {
        // Prompt-facing contact prose is deliberately absent from the gate's
        // inputs. A home or arbitrary-person match carries a false typed bit.
        XCTAssertNil(adjusted(hasNotes: false, destinationIsWorkplace: false))
    }

    func testContextAndPersonalNatureCannotAuthorizeBusiness() {
        XCTAssertNil(adjusted(cited: event(isLinked: false)))
        XCTAssertNil(adjusted(cited: event(isLinked: true), citedEventNature: "personal"))
    }

    func testAmbiguousOrAbsentNatureCannotAuthorizeBusiness() {
        XCTAssertNil(adjusted(cited: event(isLinked: true), citedEventNature: "ambiguous"))
        XCTAssertNil(adjusted(cited: event(isLinked: true), citedEventNature: "none"))
        XCTAssertEqual(
            adjusted(cited: event(isLinked: true), citedEventNature: "work-engagement"),
            5
        )
    }

    func testTentativeLinkedEventStaysBelowDisplayThreshold() {
        XCTAssertEqual(adjusted(cited: event(isLinked: true, isTentative: true)), 2)
    }

    func testPersonalClassificationDoesNotNeedBusinessAuthority() {
        XCTAssertEqual(
            SuggestionBusinessGate.adjustedConfidence(
                classification: TripClassification.personal.rawValue,
                cited: nil,
                citedEventNature: "none",
                confidence: 4,
                hasNotes: false,
                destinationIsWorkplace: false
            ),
            4
        )
    }

    func testLinkedTimedWorkEventDoesNotRequireLocation() {
        var timingOnly = event(isLinked: true)
        timingOnly.hasPlaceOrStopMatch = false
        XCTAssertEqual(adjusted(cited: timingOnly), 4)
        timingOnly.hasPlaceOrStopMatch = true
        XCTAssertEqual(adjusted(cited: timingOnly), 5)
    }

    func testUnlocatedWorkEventAroundDriveSuggestsBusinessButUnrelatedEventDoesNot() throws {
        let tripStart = Date(timeIntervalSince1970: 1_780_000_000)
        let tripEnd = tripStart.addingTimeInterval(90 * 60)
        let shoot = CalendarEventCandidate(
            title: "NovoCure Photography in Portsmouth NH",
            startDate: tripEnd.addingTimeInterval(40 * 60),
            endDate: tripEnd.addingTimeInterval(100 * 60)
        )
        let linked = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [shoot], tripStart: tripStart, tripEnd: tripEnd,
            tripEndCoordinate: nil, tripEndComponents: nil
        )
        let cited = try XCTUnwrap(linked.linked.first)
        XCTAssertFalse(cited.hasPlaceOrStopMatch)
        XCTAssertEqual(adjusted(cited: cited), 4)

        let laterStart = tripEnd.addingTimeInterval(8 * 3_600)
        let unrelated = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [shoot], tripStart: laterStart,
            tripEnd: laterStart.addingTimeInterval(45 * 60),
            tripEndCoordinate: nil, tripEndComponents: nil
        )
        XCTAssertTrue(unrelated.linked.isEmpty)
        XCTAssertNil(adjusted(cited: unrelated.context.first))
    }

    func testAllDayAssignmentWithReciprocalDriveIsAdvisoryAtConfidenceThree() {
        var paired = event(isLinked: true)
        paired.hasPlaceOrStopMatch = false
        paired.hasPairedDriveStop = true
        XCTAssertEqual(adjusted(cited: paired), 3)
        XCTAssertNil(adjusted(cited: paired, citedEventNature: "ambiguous"))
        paired.isTentative = true
        XCTAssertEqual(adjusted(cited: paired), 2, "Tentative evidence must be capped below display threshold")
    }

    func testKnownTravelConflictWithholdsEitherClassification() {
        var conflict = event(isLinked: true)
        conflict.hasTravelConflict = true
        for classification in ["business", "personal"] {
            XCTAssertNil(SuggestionBusinessGate.adjustedConfidence(
                classification: classification, cited: conflict,
                citedEventNature: classification == "business" ? "work-engagement" : "personal",
                confidence: 5, hasNotes: false, destinationIsWorkplace: false
            ))
        }
    }

    private func adjusted(
        cited: CalendarEventEvidenceBuilder.BucketedEvent? = nil,
        citedEventNature: String = "work-engagement",
        hasNotes: Bool = false,
        destinationIsWorkplace: Bool = false
    ) -> Int? {
        SuggestionBusinessGate.adjustedConfidence(
            classification: TripClassification.business.rawValue,
            cited: cited,
            citedEventNature: citedEventNature,
            confidence: 5,
            hasNotes: hasNotes,
            destinationIsWorkplace: destinationIsWorkplace
        )
    }

    private func event(
        isLinked: Bool,
        isTentative: Bool = false
    ) -> CalendarEventEvidenceBuilder.BucketedEvent {
        CalendarEventEvidenceBuilder.BucketedEvent(
            id: isLinked ? "L1" : "C1",
            title: "Client shoot",
            line: "Client shoot",
            isLinked: isLinked,
            isTentative: isTentative,
            hasPlaceOrStopMatch: isLinked
        )
    }
}
