import XCTest

@MainActor
final class LaunchSmokeUITests: MileageTrackerUITestCase {
    func testResolvedSeededInstallInitiallyStaysOnTripsOverview() {
        assertMailboxRootIsShowing()
        if shell == .stack {
            assertNoScopeIsOpen("Need Review")
        } else {
            // The expanded shell already preselects All Trips for a resolved
            // library, rather than leaving its content column blank.
            assertScopeIsOpen("All Trips")
        }
        XCTAssertFalse(app.buttons["mailboxNeedsReview"].exists, "An empty review queue should not occupy a row")
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["mailboxAllTrips"].exists)
    }

    func testUnresolvedSeededInstallInitiallyOpensNeedsReview() {
        relaunch(arguments: [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-unresolved-mix",
            "--skip-onboarding",
            "--test-store-suffix=launch-unresolved"
        ])

        // In the split shell the sidebar always reads "Trips", so a bare
        // absence check would be false by design there. assertScopeIsOpen
        // checks the column that actually shows the scope.
        assertScopeIsOpen("Need Review")
        XCTAssertFalse(
            app.buttons["filterDrivesMenu"].exists,
            "Need Review must not offer impossible classification filters"
        )

        waitForTripsScreen()
        let review = app.buttons["mailboxNeedsReview"]
        XCTAssertTrue(review.exists)
        XCTAssertTrue(review.label.contains("4 need review"), "The outstanding count belongs on the review row")
        XCTAssertFalse(
            navigationBar(in: .sidebar).staticTexts["4 need review"].exists,
            "The directory subtitle must not duplicate the review row's count"
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Trips directory - pending review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLaunchesToMailboxesRoot() {
        waitForTripsScreen()
        // Months are mailbox rows on the root now, not collapsible sections.
        XCTAssertTrue(app.staticTexts["May"].waitForExistence(timeout: 4))
        // Reports is no longer a coequal destination: the root *is* Reports and
        // export lives on the month. Guard against reintroducing either.
        XCTAssertFalse(app.buttons["reportsButton"].exists)
        XCTAssertFalse(app.buttons["monthExportMenu"].exists)
        XCTAssertFalse(app.buttons["mailboxNeedsReview"].exists)
        XCTAssertTrue(app.buttons["mailboxAllTrips"].exists)
    }

    func testDirectorySummaryKeepsUnitHeaderAndSpokenDistanceUnits() {
        waitForTripsScreen()
        let header = app.staticTexts["mailboxBusinessDistanceLabel"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 4))
        XCTAssertEqual(header.label, "Business miles")

        let year = app.buttons["yearSummaryRow-2026"]
        let month = app.buttons["mailboxMonth-2026-05"]
        XCTAssertTrue(year.exists)
        XCTAssertTrue(month.exists)
        XCTAssertEqual(year.staticTexts["mailboxBusinessDistanceValue"].firstMatch.label, "12.3 miles")
        XCTAssertEqual(month.staticTexts["mailboxBusinessDistanceValue"].firstMatch.label, "12.3 miles")
        XCTAssertFalse(month.images["calendar"].exists, "Month names do not need repeated calendar symbols")

        if shell == .stack {
            XCTAssertTrue(app.buttons["settingsButton"].isHittable)
            let addTrip = app.buttons["addTripButton"].firstMatch
            tapRenderedControl(addTrip)
            XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 4))
            app.navigationBars["Add Trip"].buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Add Trip"].waitForNonExistence(timeout: 4))
        } else {
            XCTAssertTrue(app.buttons["sidebarSettingsRow"].isHittable)
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Trips directory - caught up and simplified mileage"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFinishingLastReviewStaysInInboxAndHidesRowAfterLeaving() {
        relaunch(arguments: [
            "--uitesting", "--uitesting-mapkit-fixtures",
            "--reset-data", "--reset-preferences", "--seed-unresolved-mix",
            "--skip-onboarding", "--test-store-suffix=finish-review-directory"
        ])
        assertScopeIsOpen("Need Review")
        XCTAssertTrue(driveCards.element(boundBy: 3).waitForExistence(timeout: 8))
        XCTAssertEqual(driveCards.count, 4)
        attachReviewInteractionState("Before selection")

        app.buttons["listOptionsMenu"].tap()
        app.buttons["selectTripsButton"].tap()
        XCTAssertTrue(app.buttons["selectionDoneButton"].waitForExistence(timeout: 4))
        attachReviewInteractionState("After entering selection")
        for index in 0..<4 {
            tapDriveCard(driveCards.element(boundBy: index))
        }
        let classify = app.buttons["bulkClassifyButton"]
        XCTAssertTrue(classify.isEnabled)
        attachReviewInteractionState("After selecting four trips")
        dismissKeyboardIfNeeded()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4))
        tapRenderedControl(classify, useRenderedTouch: true)
        attachReviewInteractionState("After opening classification menu")
        tapRenderedControl(app.buttons["Personal"].firstMatch, useRenderedTouch: true)

        XCTAssertTrue(app.descendants(matching: .any)["inboxCaughtUpState"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        assertScopeIsOpen("Need Review")
        if shell == .stack {
            tapBack(from: "Need Review")
        } else {
            XCTAssertTrue(app.buttons["mailboxNeedsReview"].exists, "The selected review pane keeps its row until the user leaves")
            openAllTrips()
        }
        XCTAssertTrue(app.buttons["mailboxNeedsReview"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["mailboxAllTrips"].isHittable)
        XCTAssertTrue(app.staticTexts["All caught up"].exists)
    }

    func testMonthRowPushesItsTrips() {
        waitForTripsScreen()
        openNewestMonth()
        assertScopeIsOpen("May 2026")
        XCTAssertTrue(app.staticTexts["Home → Client"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Gym → Home"].exists)

        tapBack(from: "May 2026")
        waitForTripsScreen()
    }

    func testAllTripsScopeListsEveryTrip() {
        waitForTripsScreen()
        openAllTrips()
        XCTAssertTrue(app.staticTexts["Home → Client"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Gym → Home"].exists)
    }

    private func attachReviewInteractionState(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    /// iOS 27's native glass toolbar and menu can publish invalid ancestor hit
    /// bounds while their visible controls have normal frames. Deliver a real
    /// touch at the rendered bounds, then verify the resulting screen/state.
    private func tapRenderedControl(_ button: XCUIElement, useRenderedTouch: Bool = false) {
        XCTAssertTrue(button.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(button.isEnabled)
        let frame = button.frame
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(app.frame.contains(frame), "The control must be fully onscreen")
        if button.isHittable && !useRenderedTouch {
            button.tap()
        } else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Native toolbar or menu before rendered touch"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Native toolbar or menu accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: frame.midX - app.frame.minX,
                dy: frame.midY - app.frame.minY
            )).tap()
        }
    }

}
