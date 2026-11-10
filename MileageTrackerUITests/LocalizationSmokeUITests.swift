import XCTest

/// Per-language launch smoke: the app must reach the trips list in every
/// shipped localization. Assertions are identifier-based, never text-based,
/// so they hold in any language. Not part of the validate.sh critical path.
@MainActor
final class LocalizationSmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchesInSpanish() {
        assertLaunches(language: "es", locale: "es_ES")
    }

    func testLaunchesInFrench() {
        assertLaunches(language: "fr", locale: "fr_FR")
    }

    func testLaunchesInGerman() {
        assertLaunches(language: "de", locale: "de_DE")
    }

    private func assertLaunches(language: String, locale: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "--reset-data", "--reset-preferences",
            "--seed-mileage-data", "--skip-onboarding",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale
        ]
        app.launch()

        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 12),
            "\(language): no navigation bar appeared"
        )
        let settingsButton = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 8),
            "\(language): settings button not found"
        )
        settingsButton.tap()
        XCTAssertTrue(
            app.collectionViews["settingsForm"].firstMatch.waitForExistence(timeout: 8),
            "\(language): settings form did not open"
        )
    }
}
