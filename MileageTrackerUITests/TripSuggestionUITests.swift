import XCTest

/// AI suggestion rows in the To Review section, driven by the canned
/// UI-testing provider (`--seed-trip-suggestions`) — the real Foundation
/// Models path is never exercised in automated runs.
@MainActor
final class TripSuggestionUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        super.launchArguments + ["--seed-trip-suggestions"]
    }

    private var suggestionRows: XCUIElementQuery {
        // The suggestion has its own line between the route and trip details,
        // but remains part of the card's navigation target and never classifies.
        app.descendants(matching: .any).matching(identifier: "tripSuggestionRow")
    }

    func testSuggestionBandIsAdvisoryAndTapDoesNotClassify() {
        waitForTripsScreen()
        openNeedsReview()

        // The seeded unclassified trip gets a canned Business suggestion,
        // rendered as a compact sparkle line between route and details.
        let identity = app.descendants(matching: .any)["driveRowIdentity"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let band = identity.descendants(matching: .any)
            .matching(identifier: "tripSuggestionRow").firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        // VoiceOver must carry both classification and calendar title; a
        // Business↔Personal regression must fail this test.
        XCTAssertTrue(
            band.label.contains("Suggested")
                && band.label.contains("Business")
                && band.label.contains("Planning with Jordan"),
            "Suggestion accessibility label '\(band.label)' should name the advisory Business classification and calendar title"
        )
        XCTAssertFalse(band.label.contains("\n"))
        XCTAssertFalse(band.label.contains("A nearby work appointment"))
        XCTAssertFalse(band.label.contains("Client meeting"))
        XCTAssertFalse(app.buttons["tripSuggestionRow"].exists)
        let destination = identity.descendants(matching: .any)["driveRowRouteDestination"].firstMatch
        let detailsRow = identity.descendants(matching: .any)["driveRowTimelineMileageRow"].firstMatch
        let timeline = identity.descendants(matching: .any)["driveRowTimeline"].firstMatch
        let distance = identity.descendants(matching: .any)["driveRowDistance"].firstMatch
        XCTAssertTrue(destination.exists)
        XCTAssertTrue(detailsRow.exists)
        XCTAssertTrue(timeline.exists)
        XCTAssertTrue(distance.exists)
        XCTAssertTrue(identity.frame.insetBy(dx: -2, dy: -2).contains(band.frame))
        XCTAssertLessThanOrEqual(destination.frame.maxY, band.frame.minY + 2)
        XCTAssertLessThanOrEqual(band.frame.maxY, detailsRow.frame.minY + 2)
        XCTAssertEqual(band.frame.minX, identity.frame.minX, accuracy: 4)
        XCTAssertEqual(band.frame.maxX, identity.frame.maxX, accuracy: 4)
        XCTAssertTrue(detailsRow.frame.insetBy(dx: -2, dy: -2).contains(timeline.frame))
        XCTAssertTrue(detailsRow.frame.insetBy(dx: -2, dy: -2).contains(distance.frame))
        XCTAssertLessThanOrEqual(timeline.frame.maxX, distance.frame.minX)
        XCTAssertEqual(timeline.frame.maxY, distance.frame.maxY, accuracy: 3)
        XCTAssertEqual(timeline.frame.height, distance.frame.height, accuracy: 2)
        XCTAssertEqual(
            detailsRow.frame.maxY,
            identity.frame.maxY,
            accuracy: 3,
            "Suggestion and details should fit within the thumbnail-height summary column"
        )
        let listScreenshot = XCTAttachment(screenshot: app.screenshot())
        listScreenshot.name = "Suggestion line - trip list"
        listScreenshot.lifetime = .keepAlways
        add(listScreenshot)
        let initialCount = suggestionRows.count
        XCTAssertGreaterThan(initialCount, 0)

        // The band is part of the card's tap target: tapping opens the trip
        // detail and must NOT apply the suggested classification.
        band.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 8))
        XCTAssertFalse(app.buttons["tripDetailClassificationMore"].isSelected)
        XCTAssertEqual(app.buttons["tripDetailClassificationMore"].value as? String, "Not Classified")
        XCTAssertFalse(app.buttons["tripDetailClassificationbusiness"].isSelected)
        let detailBand = app.descendants(matching: .any)["tripDetailPreview"].firstMatch
        XCTAssertTrue(detailBand.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(
            detailBand.frame.width,
            app.frame.width * 0.75,
            "Trip Detail should place the same full-width suggestion line between route and details"
        )
        let detailDestination = app.descendants(matching: .any)["tripDetailRouteDestination"].firstMatch
        let detailDetailsRow = app.descendants(matching: .any)["tripDetailTimelineMileageRow"].firstMatch
        let detailTimeline = app.descendants(matching: .any)["tripDetailTimeline"].firstMatch
        let detailDistance = app.descendants(matching: .any)["tripDetailDistanceSummary"].firstMatch
        XCTAssertTrue(detailDestination.exists)
        XCTAssertTrue(detailDetailsRow.exists)
        XCTAssertTrue(detailTimeline.exists)
        XCTAssertTrue(detailDistance.exists)
        XCTAssertLessThanOrEqual(detailDestination.frame.maxY, detailBand.frame.minY + 2)
        XCTAssertLessThanOrEqual(detailBand.frame.maxY, detailDetailsRow.frame.minY + 2)
        XCTAssertTrue(detailDetailsRow.frame.insetBy(dx: -2, dy: -2).contains(detailTimeline.frame))
        XCTAssertTrue(detailDetailsRow.frame.insetBy(dx: -2, dy: -2).contains(detailDistance.frame))
        // The native fitting layout can stack the full timeline above mileage.
        XCTAssertLessThanOrEqual(detailTimeline.frame.minY, detailDistance.frame.maxY)
        XCTAssertEqual(detailTimeline.frame.height, detailDistance.frame.height, accuracy: 2)
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Suggestion line - trip detail"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
        tapBackFromTripDetail()
        assertScopeIsOpen("Need Review")

        XCTAssertTrue(band.waitForExistence(timeout: 8))
        XCTAssertEqual(suggestionRows.count, initialCount)
    }

    func testSettingsSectionVisibleAndTogglesOffClearRows() {
        waitForTripsScreen()
        openNeedsReview()
        XCTAssertTrue(suggestionRows.firstMatch.waitForExistence(timeout: 10))
        tapBack(from: "Need Review")
        waitForTripsScreen()

        openSettingsFromTripsList()
        let suggestionsToggle = app.switches["settingsAISuggestionsToggle"].firstMatch
        XCTAssertTrue(suggestionsToggle.waitForExistence(timeout: 4))

        // Evidence sources live on the drill-in page, visible while enabled.
        let sourcesLink = app.buttons["settingsSuggestionSourcesLink"].firstMatch
        let beforeScrolling = XCTAttachment(screenshot: app.screenshot())
        beforeScrolling.name = "Settings before scrolling to Suggestion Sources"
        beforeScrolling.lifetime = .keepAlways
        add(beforeScrolling)
        scrollUntilVisible(sourcesLink)
        XCTAssertTrue(sourcesLink.exists)
        let afterScrolling = XCTAttachment(screenshot: app.screenshot())
        afterScrolling.name = "Suggestion Sources reachable below Automatic Tracking"
        afterScrolling.lifetime = .keepAlways
        add(afterScrolling)
        sourcesLink.tap()
        XCTAssertTrue(app.switches["settingsCalendarEvidenceToggle"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.switches["settingsContactsEvidenceToggle"].firstMatch.exists)
        XCTAssertTrue(app.buttons["settingsMyCardButton"].firstMatch.exists)
        tapBack(from: "Suggestion Sources")
        XCTAssertTrue(suggestionsToggle.waitForExistence(timeout: 4))
        scrollUntilVisible(suggestionsToggle)

        // Tap the switch itself — tapping the row element lands between the
        // label and the switch and flips nothing.
        let innerSwitch = suggestionsToggle.switches.firstMatch
        (innerSwitch.exists ? innerSwitch : suggestionsToggle).tap()
        expectation(
            for: NSPredicate(format: "value == '0'"),
            evaluatedWith: suggestionsToggle
        )
        waitForExpectations(timeout: 4)

        tapBack(from: "Settings")
        waitForTripsScreen()
        openNeedsReview()

        // Turning the feature off clears every suggestion line immediately.
        XCTAssertFalse(suggestionRows.firstMatch.waitForExistence(timeout: 3))
    }

    func testNoSuggestionRowsWithoutSeededProvider() {
        relaunch(arguments: [
            "--uitesting", "--reset-data", "--reset-preferences",
            "--seed-mileage-data", "--skip-onboarding"
        ])
        waitForTripsScreen()
        openAllTrips()

        XCTAssertFalse(suggestionRows.firstMatch.waitForExistence(timeout: 3))
        tapBack(from: "All Trips")
        waitForTripsScreen()

        // Without an available provider the Settings section is hidden too.
        openSettingsFromTripsList()
        XCTAssertFalse(app.switches["settingsAISuggestionsToggle"].waitForExistence(timeout: 2))
    }
}
