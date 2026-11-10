import XCTest

@MainActor
final class SampleDataUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--skip-onboarding",
            "--test-store-suffix=sample-data"
        ]
    }

    func testEmptyInstallStaysOnMailboxesRoot() {
        assertMailboxRootIsShowing()
        assertNoScopeIsOpen("Need Review")
        XCTAssertTrue(app.staticTexts["No trips yet"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["emptyStateLoadSampleDataButton"].isHittable)
    }

    func testEmptyStateCanLoadSampleData() {
        waitForTripsScreen()

        XCTAssertTrue(app.staticTexts["No trips yet"].waitForExistence(timeout: 4))
        app.buttons["emptyStateLoadSampleDataButton"].tap()
        app.alerts["Load sample data?"].buttons["Load Sample Data"].tap()

        // Months are rows on the root now.
        XCTAssertTrue(app.buttons["mailboxNeedsReview"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["June"].waitForExistence(timeout: 4))

        // Drive rows live inside a scope. All Trips is used rather than Needs
        // Review because the sample set is deliberately a mix of resolved and
        // unresolved, so only All Trips is guaranteed to hold a row.
        openAllTrips()
        // Matched across element types: the row's identifier rides both the
        // Button that activates it and the container inside it, and which of
        // the two the query resolves is not something this test cares about.
        XCTAssertTrue(
            driveCards.firstMatch.waitForExistence(timeout: 4)
        )
        XCTAssertFalse(app.staticTexts["Boston Common, 139 Tremont St, Boston, MA 02111, United States"].exists)
        assertVisibleLabelsOmitRawAddressClutter()
    }

    private func assertVisibleLabelsOmitRawAddressClutter(file: StaticString = #filePath, line: UInt = #line) {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let clutteredLabels = labels.filter { label in
            label.localizedCaseInsensitiveContains("United States") ||
                label.range(
                    of: #"\b\d{5}(?:-\d{4})?\b"#,
                    options: .regularExpression
                ) != nil
        }
        XCTAssertTrue(
            clutteredLabels.isEmpty,
            "Visible labels should be rendered by the app without ZIP/country clutter: \(clutteredLabels)",
            file: file,
            line: line
        )
    }
}
