import XCTest

/// Captures the raw App Store screenshot frames for one locale per test
/// method. Navigation goes through accessibility identifiers (never localized
/// titles) so the same flow works in every app language. Raw PNGs land in the
/// app container's tmp directory named `<seed>-NN-<shot>.png`;
/// `scripts/capture-app-store-screenshots.sh` copies them into
/// `app-store-assets/screenshots/cards/raw/<seed>/iphone/` and renders the
/// final cards.
///
/// Locales beyond en-US are enabled by adding a test method + populating the
/// locale's slice of AppStoreScreenshotSeeds.json — see
/// app-store-assets/screenshots/cards/README.md for the full checklist.
@MainActor
final class AppStoreScreenshotUITests: XCTestCase {
    /// Per-locale strings the capture asserts on before saving screenshots:
    /// proof that the right seed set, language, unit, and currency loaded.
    private struct LocaleExpectations {
        /// Strongest visible reason on the hero AI-suggestion fixture.
        var suggestionReason: String
        /// Distance unit token in the trips list — bare "km"/"mi" (no leading
        /// space): French separates the number and unit with a narrow no-break
        /// space, so a literal " km" wouldn't match.
        var unitFragment: String
        /// Currency symbol expected on the Reports screen.
        var currencyFragment: String
        /// A distinctive place token present in a seeded label on the trips
        /// list (proves the right locale's seed set loaded).
        var placeFragment: String
        /// A word from the collapsed month-disclosure accessibility label
        /// ("Expand %@" localized) — matched with `contains`, since German puts
        /// the month first ("%@ ausklappen"). Take it from Localizable.xcstrings.
        var expandMonthLabelToken: String
    }

    private var app: XCUIApplication!
    private var screenshotDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        screenshotDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
    }

    func testCaptureENUS() throws {
        try captureSet(language: "en", locale: "en_US", seed: "en-US", expectations: LocaleExpectations(
            suggestionReason: "Fall issue", unitFragment: " mi", currencyFragment: "$",
            placeFragment: "Columbus", expandMonthLabelToken: "Expand"))
    }

    func testCaptureESES() throws {
        try captureSet(language: "es", locale: "es_ES", seed: "es-ES", expectations: LocaleExpectations(
            suggestionReason: "Portada", unitFragment: "km", currencyFragment: "€",
            placeFragment: "Serranos", expandMonthLabelToken: "Expandir"))
    }

    func testCaptureESMX() throws {
        try captureSet(language: "es", locale: "es_MX", seed: "es-MX", expectations: LocaleExpectations(
            suggestionReason: "Portada", unitFragment: "km", currencyFragment: "$",
            placeFragment: "Degollado", expandMonthLabelToken: "Expandir"))
    }

    func testCaptureFRFR() throws {
        try captureSet(language: "fr", locale: "fr_FR", seed: "fr-FR", expectations: LocaleExpectations(
            suggestionReason: "Couverture", unitFragment: "km", currencyFragment: "€",
            placeFragment: "Fourvière", expandMonthLabelToken: "Développer"))
    }

    func testCaptureFRCA() throws {
        try captureSet(language: "fr", locale: "fr_CA", seed: "fr-CA", expectations: LocaleExpectations(
            suggestionReason: "Urbania", unitFragment: "km", currencyFragment: "$",
            placeFragment: "Montréal", expandMonthLabelToken: "Développer"))
    }

    func testCaptureDEDE() throws {
        try captureSet(language: "de", locale: "de_DE", seed: "de-DE", expectations: LocaleExpectations(
            suggestionReason: "Titelbild", unitFragment: "km", currencyFragment: "€",
            placeFragment: "Marienplatz", expandMonthLabelToken: "ausklappen"))
    }

    // MARK: - Shared capture flow

    private func captureSet(
        language: String,
        locale: String,
        seed: String,
        expectations: LocaleExpectations
    ) throws {
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-app-store-screenshot-data",
            "--seed-trip-suggestions",
            "--skip-onboarding",
            "--screenshot-locale=\(seed)",
            "--test-store-suffix=app-store-screenshots-\(seed)",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale
        ]
        app.launch()

        // Trips list: To Review cards with the AI suggestion band, one
        // expanded month of classified history below.
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 12))

        // Card 1 is now the Need Review inbox: the drives awaiting a decision,
        // which is what the app is actually for. The old card 1 was the mixed
        // Trips list, which no longer exists as a screen.
        //
        // The app launches straight into the inbox, so the root row is only
        // tapped when a launch happened to land on the root instead.
        //
        // Detected by identifier, never by the nav-bar title: this method runs
        // in six languages and "Need Review" is translated in every one of
        // them. `mailboxNeedsReview` only exists while the root is on screen.
        let inbox = app.buttons["mailboxNeedsReview"].firstMatch
        if inbox.waitForExistence(timeout: 12) {
            inbox.tap()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "driveCard").firstMatch
                .waitForExistence(timeout: 12),
            "Inbox never showed a drive row"
        )

        // Matched across element types: the suggestion is the row's preview
        // line now, so its concrete type is SwiftUI's to decide.
        let suggestionRow = app.descendants(matching: .any)
            .matching(identifier: "tripSuggestionRow").firstMatch
        XCTAssertTrue(
            suggestionRow.waitForExistence(timeout: 15),
            "AI suggestion line never appeared — backfill or fixtures broken"
        )
        XCTAssertTrue(
            suggestionRow.label.contains(expectations.suggestionReason),
            "Suggestion line '\(suggestionRow.label)' missing localized reason"
        )
        assertStaticText(containing: expectations.unitFragment, context: "distance unit")
        assertStaticText(containing: expectations.placeFragment, context: "seed place")
        scrollToTop()
        settle()
        capture("\(seed)-01-trip-list")

        // Trip detail (06): the slide set's phone A — route-map hero,
        // addresses, and a confirmed Business classification. Open the inbox's
        // hero suggestion fixture, then classify it through the real UI.
        let firstDrive = app.descendants(matching: .any)
            .matching(identifier: "driveCard").firstMatch
        firstDrive.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let detailForm = app.descendants(matching: .any)
            .matching(identifier: "tripDetailForm").firstMatch
        XCTAssertTrue(detailForm.waitForExistence(timeout: 12), "Trip detail never appeared")
        let business = app.buttons["tripDetailClassificationbusiness"].firstMatch
        XCTAssertTrue(business.waitForExistence(timeout: 4), "Business control never appeared")
        business.tap()
        let selectedBusiness = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: business
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selectedBusiness], timeout: 4), .completed,
            "Trip detail must show Business selected before capture"
        )
        // The hero's route map is MKMapSnapshotter work plus tile loads; the
        // list-thumbnail settle is not enough for a full-width route render.
        settle(5.0)
        capture("\(seed)-06-detail")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "driveCard").firstMatch
                .waitForExistence(timeout: 8),
            "Did not return to the inbox after the detail capture"
        )

        // Back to the root by identifier, again because every one of these
        // titles is translated. The root is the screen that has the month rows.
        let monthRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")
        )
        if monthRows.firstMatch.exists == false {
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(monthRows.firstMatch.waitForExistence(timeout: 8))

        // Card 4 keeps the no-subscription message but now shows the actual
        // mailbox directory instead of a text-only marketing panel. Besides
        // being more useful to shoppers, this keeps every App Store screenshot
        // grounded in the shipping app UI.
        scrollToTop()
        settle()
        capture("\(seed)-04-mailboxes")

        // Card 2 is a month: the roll-up plus its trips, where Reports used to
        // be a separate sheet. The filename is unchanged so the capture script's
        // copy step keeps matching.
        //
        // Index 1, not 0: index 0 is the current month, which the seed
        // deliberately fills with the Need Review queue, so its total excludes
        // seven unclassified drives. Index 1 is the most recently closed month —
        // fully classified, and the one a user would actually export.
        XCTAssertGreaterThan(
            monthRows.count, 1,
            "Seed must supply a closed month below the current one for card 2"
        )
        let month = monthRows.element(boundBy: 1)
        XCTAssertTrue(month.waitForExistence(timeout: 8))
        month.tap()
        assertStaticText(containing: expectations.currencyFragment, context: "report currency")
        settle()
        capture("\(seed)-02-reports")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()

        // Settings scrolled to the Sync / App Lock privacy cluster.
        let settingsButton = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()
        scrollSettingsToPrivacySection()
        settle()
        capture("\(seed)-05-settings")
    }

    // MARK: - Helpers

    private func assertStaticText(
        containing fragment: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let match = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: 8),
            "No visible text contains '\(fragment)' (\(context))",
            file: file,
            line: line
        )
    }

    private func scrollToTop() {
        for _ in 0..<4 {
            app.swipeDown()
        }
    }

    /// Lets scroll deceleration and nav-bar collapse animations finish so
    /// captures don't include ghosted mid-animation rows.
    ///
    /// Also covers the row map thumbnails, which are `MKMapSnapshotter` work
    /// off the main thread and are not queryable (the thumbnail is
    /// accessibility-hidden), so there is nothing to wait *on*. At 0.8s the
    /// month capture shipped with two blank thumbnails — the long location
    /// days, whose snapshots take the longest.
    private func settle(_ interval: TimeInterval = 3.0) {
        Thread.sleep(forTimeInterval: interval)
    }

    private func scrollSettingsToPrivacySection() {
        let syncToggle = app.switches["settingsSyncToggle"].firstMatch
        let appLockToggle = app.switches["settingsAppLockToggle"].firstMatch

        var attempts = 0
        while (!syncToggle.exists || !appLockToggle.exists) && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let url = screenshotDirectory.appendingPathComponent("\(name).png")
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
        } catch {
            XCTFail("Failed to write screenshot \(name): \(error.localizedDescription)", file: file, line: line)
        }
    }
}
