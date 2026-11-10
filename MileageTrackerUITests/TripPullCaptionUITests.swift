import XCTest

@MainActor
final class TripPullCaptionUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        super.launchArguments + ["--test-store-suffix=trip-pull-caption"]
    }

    func testPullSpringsBackAndPreservesTheOriginalList() {
        waitForTripsScreen()
        openNewestMonth()
        let total = app.descendants(matching: .any)["periodTotalReimbursement"].firstMatch
        XCTAssertFalse(total.exists)
        let row = driveCards.firstMatch
        let initialRowTop = row.frame.minY
        let initialBarTop = navigationBar(in: .list).frame.minY
        pullList()
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(row.frame.minY - initialRowTop) < 2 }, object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        XCTAssertEqual(navigationBar(in: .list).frame.minY, initialBarTop, accuracy: 2)
        XCTAssertFalse(total.exists)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        tapDriveCard(row)
        XCTAssertTrue(waitForTripDetail(timeout: 5))
    }

    func testEmptySearchStillBouncesAndKeepsTheQuery() {
        waitForTripsScreen()
        openNewestMonth()
        let field = app.searchFields.firstMatch
        if !field.isHittable { app.buttons["Search"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zzzznomatchingtrip\n")
        XCTAssertTrue(app.staticTexts["No Matching Trips"].waitForExistence(timeout: 5))
        pullList(distance: 190)
        pullList()
        XCTAssertTrue(app.staticTexts["No Matching Trips"].exists)
        XCTAssertEqual(field.value as? String, "zzzznomatchingtrip")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    }

    func testAllTripsPullWithLargeTitle() {
        waitForTripsScreen()
        openAllTrips()
        let row = driveCards.firstMatch
        let initialRowTop = row.frame.minY
        for distance: CGFloat in [110, 190, 300, 420] {
            pullList(distance: distance)
            let returned = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in abs(row.frame.minY - initialRowTop) < 2 }, object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        }
    }

    private func pullList(distance: CGFloat = 420) {
        let list = app.collectionViews["tripList"]
        let barBottom = app.navigationBars.count > 0 ? navigationBar(in: .list).frame.maxY : 100
        let scope = app.segmentedControls["tripSearchScopePicker"]
        let controlsBottom = scope.exists ? max(barBottom, scope.frame.maxY) : barBottom
        let start = list.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: list.frame.width * 0.65, dy: controlsBottom + 32 - list.frame.minY))
        start.press(forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 4)
    }
}
