import XCTest

@MainActor
final class TripDiscoveryNavigationUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        ["--uitesting", "--uitesting-mapkit-fixtures", "--reset-data", "--reset-preferences",
         "--seed-unresolved-mix", "--skip-onboarding", "--test-store-suffix=siri-search-navigation",
         "--open-trip-search=Portrait"] + Self.englishLocaleArguments
    }

    func testQueuedSearchOpensAllTripsAndDisplaysFilteredResults() {
        XCTAssertTrue(app.staticTexts["Home → Ohio Theatre"].waitForExistence(timeout: 10))
        assertScopeIsOpen("All Trips")
        // iPad deliberately minimizes toolbar search until the user opens it.
        // Verify the native control retained the query without retyping it.
        if !app.searchFields.firstMatch.exists { app.buttons["Search"].firstMatch.tap() }
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Portrait")
        XCTAssertEqual(driveCards.count, 1)
    }
}
