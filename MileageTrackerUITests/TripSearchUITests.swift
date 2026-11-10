import XCTest

@MainActor
final class TripSearchUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting", "--uitesting-mapkit-fixtures",
            "--reset-data", "--reset-preferences", "--seed-unresolved-mix",
            "--skip-onboarding", "--test-store-suffix=trip-search"
        ] + Self.englishLocaleArguments
    }

    func testSearchExpandsBeyondInboxAndCancelRestoresReviewQueue() {
        waitForTripsScreen()
        openNeedsReview()
        XCTAssertEqual(driveCards.count, 4)
        search(for: "Portrait")
        XCTAssertTrue(app.segmentedControls["tripSearchScopePicker"].buttons["Need Review"].isSelected)
        XCTAssertTrue(app.segmentedControls["tripSearchScopePicker"].buttons["All Trips"].isHittable)
        let searchAll = app.buttons["searchAllTripsButton"]
        XCTAssertTrue(searchAll.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tripSearchEmptyState"].firstMatch.exists)
        searchAll.tap()
        XCTAssertTrue(app.segmentedControls["tripSearchScopePicker"].buttons["All Trips"].isSelected)
        XCTAssertTrue(app.staticTexts["Home → Ohio Theatre"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 1)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Portrait")
        app.segmentedControls["tripSearchScopePicker"].buttons["Need Review"].tap()
        XCTAssertTrue(searchAll.waitForExistence(timeout: 5))
        app.segmentedControls["tripSearchScopePicker"].buttons["All Trips"].tap()
        XCTAssertTrue(app.staticTexts["Home → Ohio Theatre"].waitForExistence(timeout: 5))
        capture("Search All Trips from the review inbox")

        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetail(timeout: 5))
        tapBackFromTripDetail()
        XCTAssertTrue(app.staticTexts["Home → Ohio Theatre"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Portrait")
        capture("Search preserved after returning from a trip")
        // Pushing a trip ends search focus; the query and results stay intact.
        // Reopen the system field to expose its Cancel control.
        app.searchFields.firstMatch.tap()
        let cancel = app.buttons["close"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        assertScopeIsOpen("Need Review")
        XCTAssertEqual(driveCards.count, 4)
    }

    func testSearchingAMonthFiltersTripsWithoutAReimbursementDisclosure() {
        waitForTripsScreen()
        openNewestMonth()
        XCTAssertFalse(app.descendants(matching: .any)["periodRollup"].firstMatch.exists)
        search(for: "COSI")
        XCTAssertTrue(app.staticTexts["COSI → North Market"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["periodRollup"].firstMatch.exists)
        XCTAssertFalse(app.buttons["periodExportMenu"].exists)
        capture("Search within a month")
    }

    func testSearchMatchesPunctuationAndPhrasesAcrossTripFields() {
        waitForTripsScreen()
        openNeedsReview()
        search(for: "“north-market” COSI")
        XCTAssertTrue(app.staticTexts["COSI → North Market"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 1)
        capture("Place phrase with punctuation and a separate origin word")

        app.searchFields.firstMatch.buttons["Clear text"].tap()
        search(for: "\"COSI North\"")
        XCTAssertTrue(app.staticTexts["No Matching Trips"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 0)

        app.searchFields.firstMatch.buttons["Clear text"].tap()
        search(for: "market, COSI")
        XCTAssertTrue(app.staticTexts["COSI → North Market"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 1)
    }

    func testReviewControlsAndCompactDetailKeepUnclassifiedStateClear() {
        waitForTripsScreen()
        openNeedsReview()
        XCTAssertFalse(app.staticTexts.matching(identifier: "driveRowPreview")
            .matching(NSPredicate(format: "label == %@", "Need Review")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Add a purpose"].exists)
        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetail(timeout: 5))
        let more = app.buttons["tripDetailClassificationMore"]
        XCTAssertFalse(more.isSelected)
        XCTAssertEqual(more.value as? String, "Not Classified")
        let business = app.buttons["tripDetailClassificationbusiness"]
        XCTAssertTrue(business.isHittable)
        XCTAssertLessThan(business.frame.maxY, app.frame.height * 0.7)
        XCTAssertFalse(app.buttons["routeMapDeleteButton"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["tripDetailStops"].firstMatch.exists)
        capture("Compact unclassified trip detail")

        more.tap()
        app.buttons["tripDetailClassificationnotADrive"].tap()
        XCTAssertTrue(more.isSelected)
        XCTAssertEqual(more.label, "Not a Drive")
        XCTAssertEqual(more.value as? String, "Not a Drive")
    }

    func testSearchFindsAnEditedAddressUsingItsFullStreetSuffix() {
        waitForTripsScreen()
        openNeedsReview()
        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetail(timeout: 5))
        replaceText(in: app.textFields["tripDetailDestination"], with: "59 Spruce St, Columbus, OH")
        dismissKeyboardIfNeeded()
        // Editing scrolls the detail header out of the lazy form. Use the
        // visible toolbar without requiring that offscreen header to exist.
        let back = navigationBar(in: .detail).buttons.element(boundBy: 0)
        XCTAssertTrue(back.isHittable)
        back.tap()

        search(for: "\"59 spruce street\"")
        XCTAssertTrue(driveCards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 1)
        capture("Full street name finds the saved abbreviated address")
        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetail(timeout: 5))
        let destination = app.textFields["tripDetailDestination"]
        scrollUntilVisible(destination)
        XCTAssertEqual(destination.value as? String, "59 Spruce St, Columbus, OH")
    }

    private func search(for text: String) {
        let field = app.searchFields.firstMatch
        if !field.exists || !field.isHittable {
            let search = app.buttons["Search"].firstMatch
            if search.exists { search.tap() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(text)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Exercises search against the root-owned Mac selection and reading pane.
/// The actual Designed-for-iPad host still needs a manual window check.
@MainActor
final class TripSearchSelectionUITests: MileageTrackerUITestCase {
    override var requiresExpandedSplitShell: Bool { true }

    override var launchArguments: [String] {
        [
            "--uitesting", "--uitesting-mapkit-fixtures", "--reset-data",
            "--reset-preferences", "--seed-unresolved-mix", "--skip-onboarding",
            "--mac-mode=on", "--test-store-suffix=trip-search-selection"
        ] + Self.englishLocaleArguments
    }

    func testSearchResultsDriveSelectionAndPruneTheReadingPane() throws {
        try XCTSkipUnless(shell == .split, "Run the reading-pane search check on an iPad.")
        openNeedsReview()
        XCTAssertEqual(driveCards.count, 4)
        let field = app.searchFields.firstMatch
        if !field.exists || !field.isHittable {
            app.buttons["Search"].firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Portrait")
        let scopePicker = app.segmentedControls["tripSearchScopePicker"]
        XCTAssertTrue(scopePicker.buttons["Need Review"].isSelected)
        XCTAssertTrue(scopePicker.buttons["All Trips"].isHittable)
        let searchAll = app.buttons["searchAllTripsButton"]
        XCTAssertTrue(searchAll.waitForExistence(timeout: 5))
        searchAll.tap()
        XCTAssertTrue(scopePicker.buttons["All Trips"].isSelected)
        XCTAssertTrue(app.staticTexts["Home → Ohio Theatre"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 1)
        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetailDestination("Ohio Theatre"))
        XCTAssertTrue(driveCards.firstMatch.isSelected)
        XCTAssertTrue(app.buttons["bulkClassifyButton"].isEnabled)
        XCTAssertEqual(field.value as? String, "Portrait")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Search results with the iPad reading pane"
        attachment.lifetime = .keepAlways
        add(attachment)

        field.tap()
        let clear = field.buttons["Clear text"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        if !field.exists {
            app.buttons["Search"].firstMatch.tap()
        }
        field.typeText("No matching trip")
        XCTAssertTrue(app.staticTexts["No Matching Trips"].waitForExistence(timeout: 5))
        XCTAssertEqual(driveCards.count, 0)
        XCTAssertTrue(app.descendants(matching: .any)["noTripSelectedPane"].firstMatch.exists)
        XCTAssertFalse(app.buttons["bulkClassifyButton"].isEnabled)
        // iPad's toolbar search uses its clear button and collapses when focus
        // leaves the field. Clearing must restore the original mailbox.
        field.buttons["Clear text"].tap()
        assertScopeIsOpen("Need Review")
        XCTAssertEqual(driveCards.count, 4)
    }
}

@MainActor
final class TripAccessibleLayoutUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting", "--uitesting-mapkit-fixtures", "--reset-data",
            "--reset-preferences", "--seed-unresolved-mix", "--skip-onboarding",
            "--test-store-suffix=trip-accessible-layout",
            "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
    }

    func testLargeTextAndGermanTripLayout() {
        XCTAssertTrue(driveCards.firstMatch.waitForExistence(timeout: 10))
        capture("German inbox at largest accessibility text size")
        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetail(timeout: 5))
        let hero = app.descendants(matching: .any)["tripDetailHero"].firstMatch
        let route = app.staticTexts["tripDetailRouteDestination"]
        XCTAssertTrue(route.exists)
        XCTAssertLessThanOrEqual(route.frame.maxX, app.frame.maxX)
        XCTAssertTrue(hero.frame.insetBy(dx: -1, dy: -1).contains(route.frame))
        XCTAssertLessThanOrEqual(app.buttons["routeMapExpandButton"].frame.width, 64)
        capture("German trip detail at largest accessibility text size")
        for suffix in ["business", "personal", "More"] {
            let button = app.buttons["tripDetailClassification\(suffix)"]
            scrollUntilVisible(button)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThan(button.frame.width, app.frame.width * 0.7)
            if suffix == "More" { XCTAssertFalse(button.isSelected) }
            capture("German classification \(suffix) at largest accessibility text size")
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
