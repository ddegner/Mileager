import XCTest

@MainActor
final class ReportsUITests: MileageTrackerUITestCase {
    /// Reports is no longer a sheet: the Mailboxes root is the report index,
    /// and both annual and monthly exports live on their respective period
    /// screens.
    func testYearSummaryOpensAnnualDriveListAndExposesItsExport() {
        waitForTripsScreen()

        XCTAssertTrue(app.staticTexts["May"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Full Year"].waitForExistence(timeout: 2))

        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'yearSummaryRow-'")
        ).element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["2026"].waitForExistence(timeout: 6))
        XCTAssertTrue(driveCards.firstMatch.waitForExistence(timeout: 4))
        // The earlier pull-down-caption change removed the redundant inline
        // total. Period navigation and exports must work without restoring it.
        XCTAssertFalse(app.descendants(matching: .any)["periodTotalReimbursement"].exists)
        // The annual scope still groups its trip rows by month and exposes
        // report exports, without requiring an inline reimbursement total.
        XCTAssertTrue(
            app.staticTexts["May 2026"].waitForExistence(timeout: 4),
            "The year list should group its rows under month headers, as All Trips does"
        )

        let exportMenu = app.navigationBars["2026"].buttons["periodExportMenu"].firstMatch
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 4))
        exercisePeriodExport(
            menu: exportMenu,
            choiceIdentifier: "periodExportPDF",
            expectedExtension: "pdf",
            expectedNavigationTitle: "2026"
        )
        exercisePeriodExport(
            menu: exportMenu,
            choiceIdentifier: "periodExportCSV",
            expectedExtension: "csv",
            expectedNavigationTitle: "2026"
        )
        exercisePeriodExport(
            menu: exportMenu,
            choiceIdentifier: "periodExportQuickBooksCSV",
            expectedExtension: "csv",
            expectedNavigationTitle: "2026"
        )
    }

    func testMonthScreenExposesItsExportAndTripList() {
        waitForTripsScreen()
        openNewestMonth()
        XCTAssertTrue(app.navigationBars["May 2026"].waitForExistence(timeout: 6))

        XCTAssertTrue(driveCards.firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["periodTotalReimbursement"].exists)

        let exportMenu = app.navigationBars["May 2026"].buttons["periodExportMenu"].firstMatch
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 4))
        exercisePeriodExport(
            menu: exportMenu,
            choiceIdentifier: "periodExportPDF",
            expectedExtension: "pdf",
            expectedNavigationTitle: "May 2026"
        )
        exercisePeriodExport(
            menu: exportMenu,
            choiceIdentifier: "periodExportCSV",
            expectedExtension: "csv",
            expectedNavigationTitle: "May 2026"
        )
        exercisePeriodExport(
            menu: exportMenu,
            choiceIdentifier: "periodExportQuickBooksCSV",
            expectedExtension: "csv",
            expectedNavigationTitle: "May 2026"
        )
    }

    func testTripPDFExportEntryPointIsAvailable() {
        waitForTripsScreen()
        openNewestMonth()

        app.staticTexts["Home → Client"].firstMatch.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))
        let detailExport = app.buttons["tripDetailExportPDF"].firstMatch
        XCTAssertTrue(detailExport.waitForExistence(timeout: 4))
        XCTAssertTrue(detailExport.isEnabled)
    }

    private func exercisePeriodExport(
        menu: XCUIElement,
        choiceIdentifier: String,
        expectedExtension: String,
        expectedNavigationTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        menu.tap()
        let choice = app.buttons[choiceIdentifier].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 4), file: file, line: line)
        choice.tap()

        let closeButton = app.buttons["Close"].firstMatch
        let cancelButton = app.buttons["Cancel"].firstMatch
        let shareSheet = app.sheets.firstMatch
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline,
              !closeButton.exists,
              !cancelButton.exists,
              !shareSheet.exists {
            usleep(100_000)
        }
        XCTAssertTrue(
            closeButton.exists || cancelButton.exists || shareSheet.exists,
            "The \(expectedExtension.uppercased()) export did not open the share sheet",
            file: file,
            line: line
        )

        if closeButton.exists {
            closeButton.tap()
        } else if cancelButton.exists {
            cancelButton.tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(
            app.navigationBars[expectedNavigationTitle].waitForExistence(timeout: 4),
            file: file,
            line: line
        )
    }
}
