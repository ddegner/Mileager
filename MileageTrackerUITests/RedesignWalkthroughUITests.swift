import XCTest

/// Development harness for the Mail-metaphor redesign: walks every new surface
/// and writes one raw PNG per screen into the test runner's tmp directory, the
/// same mechanism `AppStoreScreenshotUITests` uses. Not part of the validation
/// gate — run it with `scripts/capture-redesign-walkthrough.sh`.
///
/// Every step here exists to capture one screen or to prove one interaction.
/// There is no exploratory scrolling: where a capture needs content that starts
/// below the fold, `scroll(until:)` stops as soon as that element is on screen
/// rather than swiping a fixed number of times.
@MainActor
final class RedesignWalkthroughUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting",
            "--uitesting-mapkit-fixtures",
            "--reset-data",
            "--reset-preferences",
            "--seed-unresolved-mix",
            "--skip-onboarding",
            "--test-store-suffix=redesign-walkthrough"
        ] + Self.englishLocaleArguments
    }

    private var shots: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        // Capture every screen even after a step fails, so one broken
        // interaction does not cost the whole visual pass.
        continueAfterFailure = true
    }

    func testWalkthrough() throws {
        // The app opens on the inbox, so capture it first and step back for
        // the root rather than the other way round.
        assertScopeIsOpen("Need Review")
        capture("walk-02-needsreview")

        captureSwipeRail()
        captureSelectMode()
        captureTripDetail()

        tapBack(from: "Need Review")
        assertMailboxRootIsShowing()
        capture("walk-01-root")
        captureMonth()
        captureAddTripWithResolvedRoute()
    }

    // MARK: - Steps

    /// The leading purpose rail, held mid-gesture.
    ///
    /// Deliberately not `swipeRight()`: a full-width swipe from the row's
    /// leading edge is the interactive back gesture and pops the screen.
    private func captureSwipeRail() {
        let row = driveRow
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("The Need Review drive row must exist for the swipe-rail capture")
            return
        }
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        capture("walk-03-swipe")
        // Close the rail by tapping the title, which is inert.
        app.staticTexts["Need Review"].firstMatch.tap()
        // The swipe demo must not navigate away.
        assertScopeIsOpen("Need Review")
    }

    private func captureSelectMode() {
        let options = app.buttons["listOptionsMenu"]
        guard options.waitForExistence(timeout: 5) else {
            XCTFail("The list options menu must exist for the Select-mode capture")
            return
        }
        options.tap()
        let select = app.buttons["selectTripsButton"]
        guard select.waitForExistence(timeout: 5) else {
            XCTFail("The Select Trips command must exist for the Select-mode capture")
            return
        }
        select.tap()
        // Select one row so the bulk verbs render enabled rather than greyed.
        tapDriveCard(driveRow)
        capture("walk-04-selectmode")
        let done = app.buttons["selectionDoneButton"]
        guard done.waitForExistence(timeout: 5) else {
            XCTFail("The selection Done button must exist after entering Select mode")
            return
        }
        done.tap()
    }

    private func captureTripDetail() {
        let row = driveRow
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("The Need Review drive row must exist for the Trip Detail capture")
            return
        }
        tapDriveCard(row)
        guard waitForTripDetail(timeout: 10) else {
            XCTFail("Row tap did not push Trip Detail")
            return
        }
        capture("walk-05-detail")

        tapBackFromTripDetail()
        assertScopeIsOpen("Need Review")
    }

    private func captureMonth() {
        let month = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")
        ).element(boundBy: 0)
        guard month.waitForExistence(timeout: 5) else {
            XCTFail("A month mailbox must exist for the month-list capture")
            return
        }
        month.tap()
        capture("walk-06-month")
        navigationBar(in: .detail).buttons.element(boundBy: 0).tap()
        waitForTripsScreen()
    }

    /// Adds a trip through the endpoint-search UI with deterministic Maps
    /// fixtures so the captured form shows a two-point route and derived
    /// distance without depending on network search results.
    ///
    /// Picking a suggestion is what supplies the coordinate: free text alone
    /// leaves the resolver with nothing to route between, so the distance field
    /// stays empty and no map is drawn.
    private func captureAddTripWithResolvedRoute() {
        app.buttons["addTripButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 6))
        capture("walk-07-addtrip-empty")

        replaceText(in: app.textFields["manualTripOrigin"], with: "World Trade")
        let origin = app.buttons["tripEndpointCompletion-WorldTradeCenter"]
        XCTAssertTrue(origin.waitForExistence(timeout: 6))
        origin.tap()

        replaceText(in: app.textFields["manualTripDestination"], with: "Grand Central")
        let destination = app.buttons["tripEndpointCompletion-GrandCentralTerminal"]
        XCTAssertTrue(destination.waitForExistence(timeout: 6))
        destination.tap()
        dismissKeyboardIfNeeded()

        // The route lookup fills the distance on its own; an empty field here
        // means the resolver never ran.
        let distance = app.textFields["manualTripDistance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 6))
        let value = (distance.value as? String) ?? ""
        XCTAssertFalse(
            value.isEmpty || value == "0" || value == "0.00",
            "Choosing both endpoints must auto-fill the distance; got '\(value)'"
        )

        capture("walk-07-addtrip-route")
        let saveTrip = app.buttons["manualTripSave"]
        XCTAssertTrue(saveTrip.waitForExistence(timeout: 5), "The Add Trip checkmark must exist")
        XCTAssertTrue(saveTrip.isHittable, "The Add Trip checkmark must remain visible")
        capture("walk-08-addtrip-save")
        saveTrip.tap()
        waitForTripsScreen()
    }

    // MARK: - Helpers

    /// The first real drive row. Not `cells.element(boundBy: 0)` — index 0 is
    /// the month section header, which is also a Cell and swallows the tap.
    private var driveRow: XCUIElement {
        driveCards.firstMatch
    }

    /// Swipes up only until `element` is on screen, capped so a missing element
    /// cannot turn into an endless scroll.
    @discardableResult
    private func scroll(until element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(
                to: shots.appendingPathComponent("\(name).png"),
                options: .atomic
            )
        } catch {
            XCTFail("Failed to write \(name): \(error)", file: file, line: line)
        }
    }
}
