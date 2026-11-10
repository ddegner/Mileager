import XCTest
@testable import AppCore

final class CalendarEventEvidenceBuilderTests: XCTestCase {
    // Trip ends at the Empire State Building at 3:00 PM (fixed reference).
    private let tripStart = Date(timeIntervalSince1970: 1_780_000_000)
    private var tripEnd: Date { tripStart.addingTimeInterval(1_800) }
    private let empireState = Coordinate(latitude: 40.74844, longitude: -73.98565)
    private let empireStateComponents = TripEndpointAddressComponents(
        streetNumber: "350", streetName: "5th Ave", city: "New York"
    )

    private func event(
        _ title: String,
        startOffset: TimeInterval,
        duration: TimeInterval = 3_600,
        isAllDay: Bool = false,
        coordinate: Coordinate? = nil,
        locationText: String? = nil
    ) -> CalendarEventCandidate {
        CalendarEventCandidate(
            title: title,
            startDate: tripEnd.addingTimeInterval(startOffset),
            endDate: tripEnd.addingTimeInterval(startOffset + duration),
            isAllDay: isAllDay,
            coordinate: coordinate,
            locationText: locationText
        )
    }

    private func rank(_ candidates: [CalendarEventCandidate], limit: Int = 8) -> [CalendarEventEvidenceBuilder.RankedEvent] {
        CalendarEventEvidenceBuilder.rankedEvents(
            candidates: candidates,
            tripStart: tripStart,
            tripEnd: tripEnd,
            tripEndCoordinate: empireState,
            tripEndComponents: empireStateComponents,
            limit: limit
        )
    }

    // MARK: - Destination matching

    func testCoordinateWithinRadiusMatches() {
        let nearby = Coordinate(latitude: empireState.latitude + 200 / 111_000, longitude: empireState.longitude)
        let ranked = rank([event("Portrait Shoot w/ Example Photo", startOffset: 1_800, coordinate: nearby)])
        XCTAssertTrue(ranked[0].isAtDestination)
    }

    func testCoordinateBeyondRadiusDoesNotMatch() {
        let far = Coordinate(latitude: empireState.latitude + 500 / 111_000, longitude: empireState.longitude)
        let ranked = rank([event("Team offsite", startOffset: 1_800, coordinate: far)])
        XCTAssertFalse(ranked[0].isAtDestination)
    }

    func testTextualFallbackMatchesNormalizedStreetLineContainment() {
        let ranked = rank([event(
            "Portrait Shoot w/ Example Photo", startOffset: 1_800,
            locationText: "Example Photo Studio, 350 5th Avenue, New York"
        )])
        XCTAssertTrue(ranked[0].isAtDestination)
    }

    func testFreeformRoomTextDoesNotMatch() {
        let ranked = rank([event("Standup", startOffset: 1_800, locationText: "Conference Room 4")])
        XCTAssertFalse(ranked[0].isAtDestination)
    }

    func testCoordinateMissBeyondRadiusStillMatchesViaText() {
        // Event geocoded across the campus but text names the same address.
        let far = Coordinate(latitude: empireState.latitude + 500 / 111_000, longitude: empireState.longitude)
        let ranked = rank([event(
            "Client review", startOffset: 1_800,
            coordinate: far, locationText: "350 5th Ave, New York"
        )])
        XCTAssertTrue(ranked[0].isAtDestination)
    }

    func testNoLocationDataListsEventUnmatched() {
        let ranked = rank([event("Dentist", startOffset: 1_800)])
        XCTAssertEqual(ranked.count, 1)
        XCTAssertFalse(ranked[0].isAtDestination)
    }

    // MARK: - Ranking

    func testDestinationMatchOutranksCloserInTimeNonMatch() {
        let ranked = rank([
            event("Dentist", startOffset: 600),
            event("Portrait Shoot w/ Example Photo", startOffset: 7_200, coordinate: empireState)
        ])
        XCTAssertEqual(ranked.map(\.title), ["Portrait Shoot w/ Example Photo", "Dentist"])
    }

    func testTimeProximityOrdersNonMatches() {
        let ranked = rank([
            event("Later meeting", startOffset: 10_800),
            event("Overlapping call", startOffset: -900),
            event("Soon after", startOffset: 3_600)
        ])
        XCTAssertEqual(ranked.map(\.title), ["Overlapping call", "Soon after", "Later meeting"])
    }

    func testAllDaySortsLastWithinGroup() {
        let ranked = rank([
            event("Company holiday", startOffset: -6 * 3_600, duration: 24 * 3_600, isAllDay: true),
            event("Later meeting", startOffset: 10_800)
        ])
        XCTAssertEqual(ranked.map(\.title), ["Later meeting", "Company holiday"])
    }

    func testCapAppliedAfterRankingSoMatchingEventSurvives() {
        var candidates = (1...8).map { event("Filler \($0)", startOffset: TimeInterval($0) * 600) }
        candidates.append(event("Portrait Shoot w/ Example Photo", startOffset: 14_000, coordinate: empireState))
        let ranked = rank(candidates)
        XCTAssertEqual(ranked.count, 8)
        XCTAssertEqual(ranked[0].title, "Portrait Shoot w/ Example Photo")
        XCTAssertFalse(ranked.map(\.title).contains("Filler 8"))
    }

    // MARK: - Line text

    func testLineTextForMatchedTimedEvent() {
        let ranked = rank([event("Portrait Shoot w/ Example Photo", startOffset: 1_800, coordinate: empireState)])
        XCTAssertTrue(ranked[0].line.hasPrefix("Portrait Shoot w/ Example Photo ("))
        XCTAssertTrue(ranked[0].line.hasSuffix("; at this trip's destination)"))
        XCTAssertFalse(ranked[0].line.contains("350 5th"), "raw location must never reach the prompt")
    }

    func testLineTextForUnmatchedAndAllDayEvents() {
        let ranked = rank([
            event("Dentist", startOffset: 1_800),
            event("Open house", startOffset: 0, duration: 24 * 3_600, isAllDay: true, coordinate: empireState)
        ])
        XCTAssertFalse(ranked.first { $0.title == "Dentist" }!.line.contains("at this trip's destination"))
        XCTAssertEqual(ranked.first { $0.title == "Open house" }!.line, "Open house (all day; at this trip's destination)")
    }

    // MARK: - Bucketed evidence (linked vs context)

    private func bucket(
        _ candidates: [CalendarEventCandidate],
        stopCoordinates: [Coordinate?] = [],
        stopComponents: [TripEndpointAddressComponents?] = []
    ) -> CalendarEventEvidenceBuilder.BucketedEvents {
        CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: candidates,
            tripStart: tripStart,
            tripEnd: tripEnd,
            tripEndCoordinate: empireState,
            tripEndComponents: empireStateComponents,
            stopCoordinates: stopCoordinates,
            stopComponents: stopComponents
        )
    }

    /// Event relative to the TRIP (the plain `event` helper offsets from trip
    /// end, which reads backwards for overlap cases).
    private func tripRelativeEvent(
        _ title: String,
        start: TimeInterval,
        end: TimeInterval,
        isAllDay: Bool = false,
        coordinate: Coordinate? = nil,
        locationText: String? = nil,
        calendarName: String? = nil
    ) -> CalendarEventCandidate {
        CalendarEventCandidate(
            title: title,
            startDate: tripStart.addingTimeInterval(start),
            endDate: tripStart.addingTimeInterval(end),
            isAllDay: isAllDay,
            coordinate: coordinate,
            locationText: locationText,
            calendarName: calendarName
        )
    }

    func testShortOverlappingEventLinks() {
        let buckets = bucket([tripRelativeEvent("Portrait session", start: -600, end: 2_400)])
        XCTAssertEqual(buckets.linked.map(\.title), ["Portrait session"])
        XCTAssertEqual(buckets.linked[0].id, "L1")
    }

    func testEventContainingTripWithMarginStaysContext() {
        // A summit that spans a midday trip with at least 45 minutes on each
        // side stays context because the overlap does not establish a link.
        let buckets = bucket([tripRelativeEvent("Small business workshop", start: -3 * 3_600, end: 3 * 3_600)])
        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertEqual(buckets.context.map(\.title), ["Small business workshop"])
    }

    func testMultiDayTimedSpanOverlappingTripEndStaysContext() {
        // A multi-day timed event overlaps only the end of the trip.
        // Long spans link only when fully inside the trip.
        let buckets = bucket([tripRelativeEvent("Family visit", start: -72 * 3_600, end: 2_000)])
        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertEqual(buckets.context.map(\.title), ["Family visit"])
    }

    func testLongTimedEventsNearEitherBoundaryStayContextWithoutPlaceMatch() {
        for duration: TimeInterval in [4 * 3_600 + 1, 72 * 3_600] {
            for gap: TimeInterval in [0, 1, 2_700] {
                let arrival = tripEnd.addingTimeInterval(gap)
                let departure = tripStart.addingTimeInterval(-gap)
                for (start, end) in [
                    (arrival, arrival.addingTimeInterval(duration)),
                    (departure.addingTimeInterval(-duration), departure)
                ] {
                    let buckets = bucket([CalendarEventCandidate(
                        title: "Family visiting", startDate: start, endDate: end
                    )])
                    XCTAssertTrue(buckets.linked.isEmpty, "duration=\(duration), gap=\(gap)")
                    XCTAssertEqual(buckets.context.map(\.title), ["Family visiting"])
                    XCTAssertFalse(buckets.context[0].isLinked)
                }
            }
        }
    }

    func testFourHourEventsStillLinkNearEitherBoundary() {
        let duration: TimeInterval = 4 * 3_600
        for gap: TimeInterval in [0, 1, 2_700] {
            let arrival = tripEnd.addingTimeInterval(gap)
            let departure = tripStart.addingTimeInterval(-gap)
            for (start, end) in [
                (arrival, arrival.addingTimeInterval(duration)),
                (departure.addingTimeInterval(-duration), departure)
            ] {
                let buckets = bucket([CalendarEventCandidate(
                    title: "Client shoot", startDate: start, endDate: end
                )])
                XCTAssertEqual(buckets.linked.map(\.title), ["Client shoot"], "gap=\(gap)")
                XCTAssertTrue(buckets.context.isEmpty)
            }
        }
    }

    func testLongEventsNearEitherBoundaryKeepDestinationAndStopMatches() throws {
        let stop = Coordinate(latitude: 40.761, longitude: -73.967)
        let arrival = tripEnd.addingTimeInterval(1_200)
        let departure = tripStart.addingTimeInterval(-1_200)
        let duration: TimeInterval = 72 * 3_600
        for (coordinate, placePhrase) in [
            (empireState, "at this trip's destination"),
            (stop, "at a stop on this trip")
        ] {
            for (start, end) in [
                (arrival, arrival.addingTimeInterval(duration)),
                (departure.addingTimeInterval(-duration), departure)
            ] {
                let buckets = bucket([CalendarEventCandidate(
                    title: "Multi-day assignment", startDate: start, endDate: end,
                    coordinate: coordinate
                )], stopCoordinates: [stop], stopComponents: [nil])
                let linked = try XCTUnwrap(buckets.linked.first)
                XCTAssertEqual(linked.title, "Multi-day assignment")
                XCTAssertTrue(linked.line.contains(placePhrase))
                XCTAssertTrue(buckets.context.isEmpty)
            }
        }
    }

    func testLongEventFullyInsideTripLinks() {
        // Round trip wrapped around an all-day shoot: home 8 AM, shoot 9-5,
        // home 6:45 PM. The engagement sits inside the trip and must link.
        let longTripEnd = tripStart.addingTimeInterval(10 * 3_600)
        let buckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [tripRelativeEvent("Portrait shoot with client", start: 3_600, end: 9 * 3_600)],
            tripStart: tripStart,
            tripEnd: longTripEnd,
            tripEndCoordinate: nil,
            tripEndComponents: nil
        )
        XCTAssertEqual(buckets.linked.map(\.title), ["Portrait shoot with client"])
    }

    func testArriveAsEventStartsLinks() {
        // Trip ends 20 minutes before the event begins — the drive there.
        let buckets = bucket([event("Gowanus Darkroom Photo Critique", startOffset: 1_200)])
        XCTAssertEqual(buckets.linked.map(\.title), ["Gowanus Darkroom Photo Critique"])
    }

    func testEventHoursAwayStaysContext() {
        // An unrelated evening event can otherwise turn every trip that day
        // business under the flat list. Hours of gap is context, not a link.
        let buckets = bucket([event("Gowanus Darkroom Photo Critique", startOffset: 3 * 3_600)])
        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertTrue(buckets.context[0].line.contains("after this trip"))
    }

    func testTentativeTitleLinksOnlyViaDestinationMatch() {
        let unplaced = bucket([tripRelativeEvent("Possible shop portrait shoot", start: -600, end: 2_400)])
        XCTAssertTrue(unplaced.linked.isEmpty)
        XCTAssertTrue(unplaced.context[0].isTentative)
        XCTAssertTrue(unplaced.context[0].line.contains("tentative"))

        let placed = bucket([tripRelativeEvent("Possible shop portrait shoot", start: -600, end: 2_400, coordinate: empireState)])
        XCTAssertEqual(placed.linked.count, 1)
        XCTAssertTrue(placed.linked[0].isTentative)
    }

    func testVideoCallAndAllDayEventsNeverLink() {
        let buckets = bucket([
            tripRelativeEvent("Zoom call about the project", start: -600, end: 2_400, locationText: "https://zoom.example/j/123"),
            tripRelativeEvent("Travel day", start: -12 * 3_600, end: 36 * 3_600, isAllDay: true)
        ])
        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertTrue(buckets.context.first { $0.title.hasPrefix("Zoom") }!.line.contains("video or phone call"))
        XCTAssertTrue(buckets.context.first { $0.title.hasPrefix("Travel") }!.line.contains("all day"))
    }

    func testSingleAllDayAssignmentLinksOnlyWithReciprocalDriveStop() throws {
        // Replay the structure of a 10:33 outbound drive, 12:05 return, and
        // one location-free all-day editorial assignment. No client name or
        // real address is needed to exercise the production evidence gate.
        let outboundStart = Date(timeIntervalSince1970: 1_801_228_400)
        let outboundEnd = outboundStart.addingTimeInterval(19 * 60)
        let returnStart = outboundEnd.addingTimeInterval(73 * 60)
        let assignment = CalendarEventCandidate(
            title: "Editorial portrait assignment",
            startDate: outboundStart.addingTimeInterval(-10 * 3_600),
            endDate: outboundStart.addingTimeInterval(14 * 3_600),
            isAllDay: true,
            calendarName: "Potential Jobs"
        )
        let stop = DateInterval(start: outboundEnd, end: returnStart)

        let withoutPair = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [assignment], tripStart: outboundStart, tripEnd: outboundEnd,
            tripEndCoordinate: nil, tripEndComponents: nil
        )
        XCTAssertTrue(withoutPair.linked.isEmpty)

        let withPair = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [assignment], tripStart: outboundStart, tripEnd: outboundEnd,
            tripEndCoordinate: nil, tripEndComponents: nil, pairedDriveStop: stop
        )
        let linked = try XCTUnwrap(withPair.linked.first)
        XCTAssertEqual(linked.title, assignment.title)
        XCTAssertTrue(linked.hasPairedDriveStop)
        XCTAssertFalse(linked.hasPlaceOrStopMatch)
        XCTAssertFalse(linked.hasTravelConflict)
        XCTAssertTrue(linked.line.contains("event venue unverified"))

        let returnBuckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [assignment], tripStart: returnStart,
            tripEnd: returnStart.addingTimeInterval(24 * 60),
            tripEndCoordinate: nil, tripEndComponents: nil, pairedDriveStop: stop
        )
        XCTAssertEqual(returnBuckets.linked.map(\.title), [assignment.title])
    }

    func testAllDayPairedStopDoesNotOverrideCompetingOrUncertainEvents() {
        let allDay = tripRelativeEvent(
            "Client shoot", start: -12 * 3_600, end: 12 * 3_600, isAllDay: true
        )
        let stop = DateInterval(start: tripEnd, end: tripEnd.addingTimeInterval(73 * 60))
        func buckets(_ candidates: [CalendarEventCandidate]) -> CalendarEventEvidenceBuilder.BucketedEvents {
            CalendarEventEvidenceBuilder.bucketedEvents(
                candidates: candidates, tripStart: tripStart, tripEnd: tripEnd,
                tripEndCoordinate: nil, tripEndComponents: nil, pairedDriveStop: stop
            )
        }
        XCTAssertTrue(buckets([allDay, tripRelativeEvent(
            "Dentist", start: 40 * 60, end: 70 * 60
        )]).linked.allSatisfy { $0.title != allDay.title })
        XCTAssertTrue(buckets([allDay, tripRelativeEvent(
            "Other all-day work", start: -12 * 3_600, end: 12 * 3_600, isAllDay: true
        )]).linked.isEmpty)
        XCTAssertTrue(buckets([tripRelativeEvent(
            "Possible client shoot", start: -12 * 3_600, end: 12 * 3_600, isAllDay: true
        )]).linked.isEmpty)
        XCTAssertTrue(buckets([tripRelativeEvent(
            "Client shoot", start: -12 * 3_600, end: 12 * 3_600,
            isAllDay: true, locationText: "Different city"
        )]).linked.isEmpty)
    }

    func testExplicitRemoteTitlesWithoutLocationsStayContextOnly() throws {
        for title in [
            "Call with Dana Reyes", "Phone call about assignment",
            "Video-call with editor", "Conference call", "Zoom meeting with client",
            "Teams call", "Meeting via Google Meet", "Televisit", "Telehealth appointment",
            "Llamada con Ana", "Llamada telefónica con cliente", "Videollamada de producción",
            "Videoconferencia con cliente", "Appel avec Camille", "Appel téléphonique client",
            "Appel vidéo", "Visioconférence de production", "Telefonat mit Weber",
            "Telefonkonferenz", "Videokonferenz mit Kunde", "Videoanruf", "Anruf bei Müller"
        ] {
            let buckets = bucket([tripRelativeEvent(title, start: -600, end: 2_400)])
            XCTAssertTrue(buckets.linked.isEmpty, title)
            let context = try XCTUnwrap(buckets.context.first, title)
            XCTAssertEqual(context.title, title)
            XCTAssertFalse(context.isLinked, title)
            XCTAssertTrue(context.line.contains("video or phone call"), title)
        }
    }

    func testZoomColonTitlesStayContextWithOrWithoutMatchingLocation() throws {
        for title in ["Zoom: Client Research Follow-up", "  zoom : Client briefing", "ZOOM:Portfolio review"] {
            for coordinate: Coordinate? in [nil, empireState] {
                let buckets = bucket([
                    tripRelativeEvent(title, start: -600, end: 2_400, coordinate: coordinate)
                ])
                XCTAssertTrue(buckets.linked.isEmpty, title)
                let context = try XCTUnwrap(buckets.context.first, title)
                XCTAssertFalse(context.isLinked, title)
                XCTAssertTrue(context.line.contains("video or phone call"), title)
                XCTAssertFalse(context.line.contains("at this trip's destination"), title)
            }
        }
    }

    func testZoomLensAndUnprefixedColonTitlesRemainLinkable() {
        for title in [
            "Zoom lens workshop", "Zoom lens: hands-on portrait session",
            "Trying a new zoom: outdoor portraits"
        ] {
            let buckets = bucket([tripRelativeEvent(title, start: -600, end: 2_400)])
            XCTAssertEqual(buckets.linked.map(\.title), [title], title)
            XCTAssertTrue(buckets.context.isEmpty, title)
        }
    }

    func testRemoteTitleOverridesDestinationAndStopMatches() throws {
        let stop = TripEndpointAddressComponents(streetNumber: "90", streetName: "Main St", city: "Boston")
        for location in ["350 5th Ave, New York", "90 Main St, Boston"] {
            let buckets = bucket([
                tripRelativeEvent("Call with client", start: -600, end: 2_400,
                                  locationText: location)
            ], stopCoordinates: [nil], stopComponents: [stop])
            XCTAssertTrue(buckets.linked.isEmpty, location)
            let context = try XCTUnwrap(buckets.context.first)
            XCTAssertTrue(context.line.contains("video or phone call"))
            XCTAssertFalse(context.line.contains("at this trip's destination"))
            XCTAssertFalse(context.line.contains("at a stop on this trip"))
        }
        let coordinateMatch = bucket([
            tripRelativeEvent("Video call with client", start: -600, end: 2_400,
                              coordinate: empireState)
        ])
        XCTAssertTrue(coordinateMatch.linked.isEmpty)
        XCTAssertTrue(try XCTUnwrap(coordinateMatch.context.first).line.contains("video or phone call"))

        let localityMatch = cityStopBuckets(title: "Call with client")
        XCTAssertTrue(localityMatch.linked.isEmpty)
        XCTAssertTrue(try XCTUnwrap(localityMatch.context.first).line.contains("video or phone call"))
    }

    func testCallRelatedInPersonTitlesRemainLinkable() {
        for title in [
            "Photo call with cast", "Casting call with producer", "On-call shift",
            "Calligraphy workshop", "Call time for photo shoot", "Client video shoot",
            "Zoom lens workshop", "Appel à projets", "Llamada a escena", "Call to action workshop"
        ] {
            let buckets = bucket([tripRelativeEvent(title, start: -600, end: 2_400)])
            XCTAssertEqual(buckets.linked.map(\.title), [title], title)
            XCTAssertTrue(buckets.context.isEmpty, title)
        }
    }

    func testLocatedAllDayEventsAtDestinationAndStopNeverLink() {
        let stopComponents = TripEndpointAddressComponents(
            streetNumber: "430", streetName: "Example St", city: "New York"
        )
        let buckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [
                tripRelativeEvent(
                    "Destination holiday", start: -12 * 3_600, end: 36 * 3_600,
                    isAllDay: true, coordinate: empireState
                ),
                tripRelativeEvent(
                    "Stop reminder", start: -12 * 3_600, end: 36 * 3_600,
                    isAllDay: true, locationText: "430 Example Street, New York"
                ),
            ],
            tripStart: tripStart,
            tripEnd: tripEnd,
            tripEndCoordinate: empireState,
            tripEndComponents: empireStateComponents,
            stopCoordinates: [nil],
            stopComponents: [stopComponents]
        )

        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertEqual(Set(buckets.context.map(\.title)), ["Destination holiday", "Stop reminder"])
        XCTAssertTrue(buckets.context.allSatisfy { !$0.isLinked })
        XCTAssertTrue(buckets.context.first { $0.title == "Destination holiday" }!.line.contains("at this trip's destination"))
        XCTAssertTrue(buckets.context.first { $0.title == "Stop reminder" }!.line.contains("at a stop on this trip"))
    }

    func testLinkedOverflowIsDroppedInsteadOfReceivingContextAuthority() {
        let buckets = bucket([
            tripRelativeEvent("Linked 1", start: -400, end: 2_400),
            tripRelativeEvent("Linked 2", start: -300, end: 2_500),
            tripRelativeEvent("Linked 3", start: -200, end: 2_600),
            tripRelativeEvent("Linked overflow", start: -100, end: 2_700),
            event("Nearby context", startOffset: 3 * 3_600),
        ])

        XCTAssertEqual(buckets.linked.map(\.title), ["Linked 1", "Linked 2", "Linked 3"])
        XCTAssertEqual(buckets.context.map(\.title), ["Nearby context"])
        XCTAssertFalse(buckets.all.contains { $0.title == "Linked overflow" })
        XCTAssertEqual(buckets.event(withID: "C1")?.title, "Nearby context")
        XCTAssertEqual(buckets.event(withID: "C1")?.isLinked, false)
    }

    func testInvitePlusOwnCopyCollapsesKeepingLocatedCopy() {
        // A manually copied invitation can duplicate the original.
        let buckets = bucket([
            tripRelativeEvent("Client Photo Shoot", start: -600, end: 2_400),
            tripRelativeEvent("client photo shoot", start: 0, end: 3_000, locationText: "350 5th Ave, New York")
        ])
        XCTAssertEqual(buckets.all.count, 1)
        XCTAssertTrue(buckets.linked[0].line.contains("at this trip's destination"))
    }

    func testStopMatchLinksMultiLegRoundTrip() {
        // Round trips end at home; the stop is where the drive was for.
        let stopComponents = TripEndpointAddressComponents(streetNumber: "430", streetName: "Example St", city: "New York")
        let buckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [tripRelativeEvent("Portrait shoot with client", start: -600, end: 2_400, locationText: "430 Example Street, New York")],
            tripStart: tripStart,
            tripEnd: tripEnd,
            tripEndCoordinate: nil,
            tripEndComponents: TripEndpointAddressComponents(streetNumber: "24", streetName: "Example St", city: "Cambridge"),
            stopCoordinates: [nil],
            stopComponents: [stopComponents]
        )
        XCTAssertEqual(buckets.linked.map(\.title), ["Portrait shoot with client"])
        XCTAssertTrue(buckets.linked[0].line.contains("at a stop on this trip"))
    }

    func testNamedVenueLinksWhenCityAndWholeEventMatchAStationaryStop() throws {
        let buckets = cityStopBuckets()
        let linked = try XCTUnwrap(buckets.linked.first)
        XCTAssertEqual(linked.id, "L1")
        XCTAssertEqual(linked.title, "Client video shoot")
        XCTAssertTrue(linked.line.contains("same city as a stop that spans this event"))
        XCTAssertTrue(linked.line.contains("exact venue unverified"))
        XCTAssertFalse(linked.line.contains("at a stop on this trip"))
        XCTAssertFalse(linked.line.contains("East Meadow Office"))
        XCTAssertTrue(buckets.context.isEmpty)
    }

    func testNamedVenueRequiresTheFullEventWithinOneKnownStop() {
        let good = DateInterval(start: tripStart.addingTimeInterval(3_600),
                                end: tripStart.addingTimeInterval(5 * 3_600))
        for intervals: [DateInterval?] in [
            [], [nil],
            [DateInterval(start: tripStart.addingTimeInterval(3 * 3_600), end: good.end)],
            [DateInterval(start: good.start, end: tripStart.addingTimeInterval(3 * 3_600))],
            [DateInterval(start: tripStart.addingTimeInterval(6 * 3_600),
                          end: tripStart.addingTimeInterval(8 * 3_600))]
        ] {
            let buckets = cityStopBuckets(intervals: intervals)
            XCTAssertTrue(buckets.linked.isEmpty)
            XCTAssertEqual(buckets.context.count, 1)
        }
    }

    func testNamedVenueDoesNotOverrideConflictingLocationOrUncertainEvents() {
        for location in [
            "West Meadow Office", "East Meadowbrook Office", "Office",
            "123 Different Street, East Meadow", "Different Avenue, East Meadow",
            "https://example.com/East-Meadow", "East Meadow Zoom meeting"
        ] {
            XCTAssertTrue(cityStopBuckets(location: location).linked.isEmpty, location)
        }
        XCTAssertTrue(cityStopBuckets(coordinate: empireState).linked.isEmpty)
        XCTAssertTrue(cityStopBuckets(isAllDay: true).linked.isEmpty)
        XCTAssertTrue(cityStopBuckets(title: "Possible client shoot").linked.isEmpty)
        XCTAssertTrue(cityStopBuckets(city: nil).linked.isEmpty)
    }

    private func cityStopBuckets(
        title: String = "Client video shoot",
        location: String = "East Meadow Office",
        city: String? = "East Meadow",
        coordinate: Coordinate? = nil,
        isAllDay: Bool = false,
        intervals: [DateInterval?]? = nil
    ) -> CalendarEventEvidenceBuilder.BucketedEvents {
        CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [tripRelativeEvent(title, start: 2 * 3_600, end: 4 * 3_600,
                                            isAllDay: isAllDay, coordinate: coordinate,
                                            locationText: location)],
            tripStart: tripStart,
            tripEnd: tripStart.addingTimeInterval(9 * 3_600),
            tripEndCoordinate: nil,
            tripEndComponents: nil,
            stopCoordinates: [nil],
            stopComponents: [TripEndpointAddressComponents(streetNumber: "90", streetName: "Merrick Ave", city: city)],
            stopIntervals: intervals ?? [DateInterval(start: tripStart.addingTimeInterval(3_600),
                                                      end: tripStart.addingTimeInterval(5 * 3_600))]
        )
    }

    func testReliabilityDistinguishesPlaceCorroborationFromTimingAlone() throws {
        let timeOnly = try reliabilityEvidence(
            tripRelativeEvent("Client appointment", start: 3_600, end: 7_200)
        )
        XCTAssertTrue(timeOnly.isLinked)
        XCTAssertFalse(timeOnly.hasPlaceOrStopMatch)
        XCTAssertFalse(timeOnly.hasTravelConflict)

        let destination = try reliabilityEvidence(
            tripRelativeEvent("Client appointment", start: 3_600, end: 7_200, coordinate: empireState)
        )
        XCTAssertTrue(destination.hasPlaceOrStopMatch)
        XCTAssertFalse(destination.hasTravelConflict)
        XCTAssertTrue(try XCTUnwrap(cityStopBuckets().linked.first).hasPlaceOrStopMatch)
    }

    func testPositiveStationaryOverlapCorroboratesEvenPartOfEvent() throws {
        let event = tripRelativeEvent("Client appointment", start: 3_600, end: 7_200)
        for (start, end): (TimeInterval, TimeInterval) in [
            (0, 3_601), (7_199, 10_800), (3_600, 7_200)
        ] {
            let evidence = try reliabilityEvidence(event, stopIntervals: [DateInterval(
                start: tripStart.addingTimeInterval(start), end: tripStart.addingTimeInterval(end)
            )])
            XCTAssertTrue(evidence.hasPlaceOrStopMatch, "stop=\(start)...\(end)")
            XCTAssertFalse(evidence.hasTravelConflict)
        }
    }

    func testTouchingMissingAndEmptyStationaryIntervalsDoNotCorroborate() throws {
        let event = tripRelativeEvent("Client appointment", start: 3_600, end: 7_200)
        let intervals: [DateInterval?] = [
            nil,
            DateInterval(start: tripStart, end: tripStart.addingTimeInterval(3_600)),
            DateInterval(start: tripStart.addingTimeInterval(7_200), end: tripStart.addingTimeInterval(10_800)),
            DateInterval(start: tripStart.addingTimeInterval(5_400), duration: 0)
        ]
        for interval in intervals {
            let evidence = try reliabilityEvidence(event, stopIntervals: [interval])
            XCTAssertFalse(evidence.hasPlaceOrStopMatch)
            XCTAssertFalse(evidence.hasTravelConflict)
        }
    }

    func testExplicitRemoteAndDifferentPlaceConflictDespiteStationaryOverlap() throws {
        let stop = DateInterval(start: tripStart, end: tripStart.addingTimeInterval(10 * 3_600))
        for event in [
            tripRelativeEvent("Zoom: Client briefing", start: 3_600, end: 7_200),
            tripRelativeEvent("Client appointment", start: 3_600, end: 7_200,
                              locationText: "123 Other Road, Boston")
        ] {
            let evidence = try reliabilityEvidence(event, stopIntervals: [stop])
            XCTAssertTrue(evidence.hasPlaceOrStopMatch, "A stop overlaps, but cannot override contrary location")
            XCTAssertTrue(evidence.hasTravelConflict)
            XCTAssertFalse(evidence.isLinked)
        }
    }

    func testBroadVisitConflictStartsAtTwentyFourHoursWithoutKnownPlace() throws {
        for duration: TimeInterval in [24 * 3_600 - 1, 24 * 3_600, 72 * 3_600] {
            let evidence = try reliabilityEvidence(
                tripRelativeEvent("Family visiting", start: 0, end: duration)
            )
            XCTAssertEqual(evidence.hasTravelConflict, duration >= 24 * 3_600)
            XCTAssertFalse(evidence.hasPlaceOrStopMatch)
        }
        let broadVisitAtStop = try reliabilityEvidence(
            tripRelativeEvent("Family visiting", start: 0, end: 72 * 3_600),
            stopIntervals: [DateInterval(start: tripStart.addingTimeInterval(3_600), duration: 3_600)]
        )
        XCTAssertTrue(broadVisitAtStop.hasPlaceOrStopMatch)
        XCTAssertTrue(broadVisitAtStop.hasTravelConflict, "A brief stop does not make a multi-day visit specific")
    }

    func testUnknownPlaceEventInsideOneTravelIntervalHasTimingConflict() throws {
        let event = tripRelativeEvent("Client appointment", start: 3_600, end: 7_200)
        for interval in [
            DateInterval(start: tripStart, end: tripStart.addingTimeInterval(10_800)),
            DateInterval(start: event.startDate, end: event.endDate)
        ] {
            let evidence = try reliabilityEvidence(event, travelIntervals: [interval])
            XCTAssertTrue(evidence.hasTravelConflict)
            XCTAssertFalse(evidence.hasPlaceOrStopMatch)
        }
        for interval in [
            DateInterval(start: tripStart, end: event.startDate),
            DateInterval(start: event.endDate, end: tripStart.addingTimeInterval(10_800)),
            DateInterval(start: event.startDate, end: event.endDate.addingTimeInterval(-1))
        ] {
            XCTAssertFalse(try reliabilityEvidence(event, travelIntervals: [interval]).hasTravelConflict)
        }
        let instant = tripRelativeEvent("Reminder", start: 5_400, end: 5_400)
        XCTAssertFalse(try reliabilityEvidence(instant, travelIntervals: [
            DateInterval(start: tripStart, end: tripStart.addingTimeInterval(10_800))
        ]).hasTravelConflict)
    }

    func testEightHourWorkEventAtStationaryStopRetainsUsefulEvidence() throws {
        let event = tripRelativeEvent("Full-day client shoot", start: 3_600, end: 9 * 3_600)
        let evidence = try reliabilityEvidence(event,
            stopIntervals: [DateInterval(start: event.startDate, end: event.endDate)],
            travelIntervals: [
                DateInterval(start: tripStart, end: event.startDate),
                DateInterval(start: event.endDate, end: tripStart.addingTimeInterval(10 * 3_600))
            ])
        XCTAssertTrue(evidence.isLinked)
        XCTAssertTrue(evidence.hasPlaceOrStopMatch)
        XCTAssertFalse(evidence.hasTravelConflict)
    }

    func testKnownPlacePreservesLongVisitsAndUnsegmentedTravelEvidence() throws {
        let broadVisit = try reliabilityEvidence(
            tripRelativeEvent("Multi-day assignment", start: 0, end: 72 * 3_600, coordinate: empireState)
        )
        XCTAssertTrue(broadVisit.hasPlaceOrStopMatch)
        XCTAssertFalse(broadVisit.hasTravelConflict)

        // A captured leg may contain an unsegmented stop. An explicit venue
        // match remains stronger evidence than assuming continuous driving.
        let knownVenue = try reliabilityEvidence(
            tripRelativeEvent("Client appointment", start: 3_600, end: 7_200, coordinate: empireState),
            travelIntervals: [DateInterval(start: tripStart, duration: 10 * 3_600)]
        )
        XCTAssertTrue(knownVenue.hasPlaceOrStopMatch)
        XCTAssertFalse(knownVenue.hasTravelConflict)
    }

    private func reliabilityEvidence(
        _ candidate: CalendarEventCandidate,
        stopIntervals: [DateInterval?] = [],
        travelIntervals: [DateInterval] = []
    ) throws -> CalendarEventEvidenceBuilder.BucketedEvent {
        let buckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [candidate], tripStart: tripStart,
            tripEnd: tripStart.addingTimeInterval(10 * 3_600),
            tripEndCoordinate: empireState, tripEndComponents: empireStateComponents,
            stopIntervals: stopIntervals, travelIntervals: travelIntervals
        )
        return try XCTUnwrap(buckets.all.first)
    }

    func testBucketLineShowsCalendarNameAndNeverRawLocation() {
        let buckets = bucket([tripRelativeEvent(
            "Climb with a friend", start: -600, end: 2_400,
            locationText: "242 Sample St, Brooklyn", calendarName: "Work"
        )])
        let line = buckets.all[0].line
        XCTAssertTrue(line.contains("Work calendar"))
        XCTAssertTrue(line.contains("at a different location"))
        XCTAssertFalse(line.contains("Sample"), "raw location must never reach the prompt")
    }

    func testTentativeMarkersDetectedAcrossShippedLanguages() {
        // A missed marker fails open (tentative gig backs a full-confidence
        // business suggestion), so every shipped language needs coverage.
        for title in [
            "Vielleicht Shooting mit Müller", "Evtl. Kundentermin", "Termin unter Vorbehalt",
            "Möglicher Auftrag Siemens",
            "Posible sesión con Marta", "Rodaje por confirmar", "Quizá rodaje en Toledo",
            "Séance photo à confirmer", "Tournage éventuel"
        ] {
            let buckets = bucket([tripRelativeEvent(title, start: -600, end: 2_400)])
            XCTAssertTrue(buckets.linked.isEmpty, "\(title) should not link without a place match")
            XCTAssertTrue(buckets.context[0].isTentative, "\(title) should be tentative")
        }
        // Negative control: a confirmed title links (overlap channel) and is
        // not tentative.
        let confirmed = bucket([tripRelativeEvent("Sesión con Marta", start: -600, end: 2_400)])
        XCTAssertEqual(confirmed.linked.count, 1)
        XCTAssertFalse(confirmed.linked[0].isTentative)
    }

    func testEuropeanPhoneFormatsReadAsCalls() {
        for location in ["01.42.68.53.00", "030/1234567", "+49 30 12345678"] {
            let buckets = bucket([tripRelativeEvent("Appel client", start: -600, end: 2_400, locationText: location)])
            XCTAssertTrue(buckets.linked.isEmpty, "\(location) is a call, never a drive destination")
            XCTAssertTrue(buckets.context[0].line.contains("video or phone call"), location)
        }
    }

    func testNumberLastAddressOrderingMatchesDestination() {
        // The geocoder street line is number-first; German-style location
        // text is number-last. Token-set containment bridges the two.
        let buckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [tripRelativeEvent("Porträt bei Weber", start: -600, end: 2_400, locationText: "Hauptstraße 123, 10115 Berlin")],
            tripStart: tripStart,
            tripEnd: tripEnd,
            tripEndCoordinate: nil,
            tripEndComponents: TripEndpointAddressComponents(streetNumber: "123", streetName: "Hauptstraße", city: "Berlin")
        )
        XCTAssertEqual(buckets.linked.map(\.title), ["Porträt bei Weber"])
        XCTAssertTrue(buckets.linked[0].line.contains("at this trip's destination"))
    }

    func testUnmatchedNumberLastAddressCannotLinkFromTimingAlone() {
        let buckets = bucket([tripRelativeEvent(
            "Client shoot", start: -600, end: 2_400,
            locationText: "Hauptstraße 123, Berlin"
        )])

        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertEqual(buckets.context.map(\.title), ["Client shoot"])
        XCTAssertTrue(buckets.context[0].line.contains("at a different location"))
    }

    func testBareVenueTextIsElsewhereAndCannotLinkFromTimingAlone() {
        // Unmatched venue text is anti-evidence rather than an authority gap:
        // `.none` could otherwise link from a coherent overlap.
        let buckets = bucket([tripRelativeEvent("Standup", start: -600, end: 2_400, locationText: "Conference Room 4")])
        XCTAssertTrue(buckets.linked.isEmpty)
        XCTAssertTrue(buckets.context[0].line.contains("at a different location"))
    }
}
