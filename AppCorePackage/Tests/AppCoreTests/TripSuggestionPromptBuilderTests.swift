import XCTest
@testable import AppCore

final class TripSuggestionPromptBuilderTests: XCTestCase {
    private let tripID = UUID()
    private let startDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeTrip(notes: String? = nil) -> TripSummary {
        TripSummary(
            id: tripID,
            createdAt: startDate,
            updatedAt: startDate,
            captureSource: "automatic",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_980),
            startCoordinate: Coordinate(latitude: 40.702, longitude: -73.988),
            endCoordinate: Coordinate(latitude: 40.74844, longitude: -73.98565),
            startAddress: "111 Example St, Brooklyn",
            endAddress: "350 5th Ave, New York",
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "111", streetName: "Example St", city: "Brooklyn"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "350", streetName: "5th Ave", city: "New York"
            ),
            distanceMeters: DistanceConversion.meters(fromMiles: 12.4),
            routePolyline: nil,
            classification: nil,
            reviewStatus: .needsReview,
            businessPurpose: nil,
            notes: notes,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
    }

    private func makeRequest(
        notes: String? = nil,
        presets: [String] = ["Client meeting", "Site visit"],
        calendarEnabled: Bool = false
    ) -> TripSuggestionRequest {
        TripSuggestionRequest(
            trip: makeTrip(notes: notes),
            businessPurposePresets: presets,
            calendarEvidenceEnabled: calendarEnabled,
            localeIdentifier: "en_US"
        )
    }

    // MARK: - Instructions

    func testInstructionsMentionCalendarOnlyWhenIncluded() {
        let without = TripSuggestionPromptBuilder.instructions(localeIdentifier: "en_US", calendarEvidenceIncluded: false)
        let with = TripSuggestionPromptBuilder.instructions(localeIdentifier: "en_US", calendarEvidenceIncluded: true)

        XCTAssertFalse(without.contains("calendar"))
        XCTAssertTrue(with.contains("Events linked to this trip"))
        XCTAssertTrue(with.contains("Only a linked event can justify suggesting business."))
        XCTAssertTrue(with.contains("citedEventID"))
        XCTAssertTrue(with.contains("citedEventNature"))
        // Absence of an event must be framed as neutral: the model treated a
        // "calendar outweighs other evidence" framing as evidence against business.
        XCTAssertTrue(with.contains("The absence of events is not evidence of anything."))
        // The model may only restate app-computed facts, never invent them.
        XCTAssertTrue(with.contains("Never claim an event is at the trip's destination"))
    }

    func testInstructionsRequestRationaleInPromptLanguage() {
        let spanish = TripSuggestionPromptBuilder.instructions(localeIdentifier: "es_ES", calendarEvidenceIncluded: false)
        XCTAssertTrue(spanish.contains("Spanish"), "Rationale language should be named for the model: \(spanish)")
        XCTAssertTrue(spanish.contains("4-8 word evidence phrase"))
    }

    func testCalendarSectionListsEventsOrSaysNone() {
        XCTAssertEqual(
            TripSuggestionPromptBuilder.calendarSection(eventLines: []),
            "Calendar events near the trip: none."
        )
        let section = TripSuggestionPromptBuilder.calendarSection(
            eventLines: ["Portrait Shoot w/ AltaMark (Wed 2:00 PM–Wed 3:00 PM)"]
        )
        XCTAssertTrue(section.contains("- Portrait Shoot w/ AltaMark"))
    }

    // MARK: - Prompt

    func testPromptContainsTripFactsEndpointsAndPresets() {
        let prompt = TripSuggestionPromptBuilder.prompt(for: makeRequest())

        XCTAssertTrue(prompt.contains("12.4 mi"))
        XCTAssertTrue(prompt.contains("From: 111 Example St, Brooklyn"))
        XCTAssertTrue(prompt.contains("To: 350 5th Ave, New York"))
        XCTAssertTrue(prompt.contains("Business purpose presets: Client meeting; Site visit"))
        XCTAssertFalse(prompt.contains("prior"), "The prompt must not mention prior trips: \(prompt)")
    }

    func testPromptDelimitsUserNotes() {
        let prompt = TripSuggestionPromptBuilder.prompt(
            for: makeRequest(notes: "Dropped samples at the Hoboken office")
        )
        XCTAssertTrue(prompt.contains("User notes: \"\"\"Dropped samples at the Hoboken office\"\"\""))
    }

    func testPromptOmitsEmptyNotesAndEmptyPresets() {
        let prompt = TripSuggestionPromptBuilder.prompt(
            for: makeRequest(notes: "   ", presets: [])
        )
        XCTAssertFalse(prompt.contains("User notes"))
        XCTAssertFalse(prompt.contains("presets"))
    }

    func testCalendarInstructionsHighlightDestinationMarkedEvents() {
        let with = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: "en_US", calendarEvidenceIncluded: true
        )
        let without = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: "en_US", calendarEvidenceIncluded: false
        )
        XCTAssertTrue(with.contains("at this trip's destination"))
        XCTAssertFalse(without.contains("at this trip's destination"))
    }

    func testPromptAnnotatesContactNotes() {
        var request = makeRequest()
        request.originContactNote = "the user's home address"
        request.destinationContactNote = "the address of contact “Dana Reyes”"

        let prompt = TripSuggestionPromptBuilder.prompt(for: request)

        XCTAssertTrue(prompt.contains("From: 111 Example St, Brooklyn (the user's home address)"))
        XCTAssertTrue(prompt.contains("To: 350 5th Ave, New York (the address of contact “Dana Reyes”)"))
    }

    func testInstructionsMentionContactsAndCommuteOnlyWhenIncluded() {
        let without = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: "en_US", calendarEvidenceIncluded: false, contactEvidenceIncluded: false
        )
        let with = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: "en_US", calendarEvidenceIncluded: false, contactEvidenceIncluded: true
        )

        XCTAssertFalse(without.contains("contact"))
        XCTAssertTrue(with.contains("contact's address"))
        XCTAssertTrue(with.contains("commute"))
    }

    func testPromptUsesManualDistanceOverrideWhenPresent() {
        var request = makeRequest()
        request.trip.manualDistanceOverrideMeters = DistanceConversion.meters(fromMiles: 20)

        XCTAssertTrue(TripSuggestionPromptBuilder.prompt(for: request).contains("20.0 mi"))
    }

    // Product regression guard: model-facing text must never expose raw prior
    // trips, endpoint history, or frequent places. A reciprocal drive can
    // contribute one derived stop fact to a calendar event line.
    func testModelTextNeverReferencesPriorTripHistory() {
        var request = makeRequest(notes: "Dropped samples at the Hoboken office", calendarEnabled: true)
        request.originContactNote = "the user's home address"
        request.destinationContactNote = "the address of contact “Dana Reyes”"
        let texts = [
            TripSuggestionPromptBuilder.instructions(localeIdentifier: "en_US", calendarEvidenceIncluded: false),
            TripSuggestionPromptBuilder.instructions(
                localeIdentifier: "en_US", calendarEvidenceIncluded: true, contactEvidenceIncluded: true
            ),
            TripSuggestionPromptBuilder.prompt(for: request),
            TripSuggestionPromptBuilder.calendarSection(eventLines: [])
        ]
        for text in texts {
            for marker in ["prior", "history", "frequent"] {
                XCTAssertFalse(
                    text.lowercased().contains(marker),
                    "\"\(marker)\" leaked into model-facing text: \(text)"
                )
            }
        }
    }

    // MARK: - Output mapper

    func testMapperAcceptsBusinessWithPurpose() throws {
        let suggestion = try XCTUnwrap(TripSuggestionOutputMapper.suggestion(
            tripID: tripID,
            classification: "business",
            businessPurpose: " Client meeting ",
            rationale: "  Destination and note indicate\na client meeting.  ",
            confidence: 4,
            evidence: []
        ))
        XCTAssertEqual(suggestion.classification, .business)
        XCTAssertEqual(suggestion.businessPurpose, "Client meeting")
        XCTAssertEqual(suggestion.rationale, "Destination and note indicate a client meeting.")
    }

    func testMapperSnapsUncitedPurposeToCanonicalPreset() throws {
        let presets = ["Client meeting", "Site visit", "Photo shoot"]

        // Drifted phrasing resolves to the canonical preset string.
        let snapped = try XCTUnwrap(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "business", businessPurpose: "meeting", confidence: 4, evidence: [],
            businessPurposePresets: presets
        ))
        XCTAssertEqual(snapped.businessPurpose, "Client meeting")

        // A purpose outside the vocabulary is dropped, not shown.
        let dropped = try XCTUnwrap(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "business", businessPurpose: "Errand run", confidence: 4, evidence: [],
            businessPurposePresets: presets
        ))
        XCTAssertNil(dropped.businessPurpose)

        // Calendar-backed suggestions keep the event-derived purpose verbatim.
        let calendarBacked = try XCTUnwrap(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "business", businessPurpose: "Magazine assignment", confidence: 4,
            evidence: [.calendarEvent(title: "Photograph Boston Globe Magazine")],
            businessPurposePresets: presets
        ))
        XCTAssertEqual(calendarBacked.businessPurpose, "Magazine assignment")
    }

    func testMapperStripsPurposeForPersonal() throws {
        let suggestion = try XCTUnwrap(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "personal", businessPurpose: "Client meeting", confidence: 3, evidence: []
        ))
        XCTAssertNil(suggestion.businessPurpose)
    }

    func testStationaryStopsUseTheGapBetweenLegsAndOmitOverlaps() {
        var request = makeRequest()
        let first = TripLeg(captureSource: "automatic", startDate: startDate,
            endDate: startDate.addingTimeInterval(600), startCoordinate: nil, endCoordinate: nil,
            startAddress: "Home", endAddress: "Client studio", distanceMeters: 1000, routePolyline: nil)
        var second = TripLeg(captureSource: "automatic", startDate: startDate.addingTimeInterval(4200),
            endDate: startDate.addingTimeInterval(4800), startCoordinate: nil, endCoordinate: nil,
            startAddress: "Client studio", endAddress: "Home", distanceMeters: 1000, routePolyline: nil)
        request.trip.legs = [first, second]
        let prompt = TripSuggestionPromptBuilder.prompt(for: request)
        XCTAssertEqual(prompt.components(separatedBy: "Stationary stop:").count - 1, 1)
        XCTAssertTrue(prompt.contains("Stationary stop: Client studio,"))
        XCTAssertFalse(prompt.contains("Stationary stop: Home,"), "Final endpoint is not an intermediate stop")
        second.startDate = first.endDate.addingTimeInterval(-60)
        request.trip.legs = [first, second]
        XCTAssertFalse(TripSuggestionPromptBuilder.prompt(for: request).contains("Stationary stop:"),
            "Overlapping capture legs must not fabricate a dwell window")
    }

    func testMapperRejectsOutOfRangeConfidence() {
        for value in [-1, 0, 6, 100] {
            XCTAssertNil(TripSuggestionOutputMapper.suggestion(
                tripID: tripID, classification: "personal", businessPurpose: nil, confidence: value, evidence: []
            ))
        }
    }

    func testMapperRejectsUnknownClassificationNotADriveAndLowConfidence() {
        XCTAssertNil(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "commute", businessPurpose: nil, confidence: 5, evidence: []
        ))
        XCTAssertNil(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "notADrive", businessPurpose: nil, confidence: 5, evidence: []
        ))
        XCTAssertNil(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "business", businessPurpose: nil, confidence: 2, evidence: []
        ))
        XCTAssertNotNil(TripSuggestionOutputMapper.suggestion(
            tripID: tripID, classification: "business", businessPurpose: nil, confidence: 3, evidence: []
        ))
    }
}
