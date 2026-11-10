import XCTest

/// Captures the raw iPad 13" App Store frames (2064 × 2752 portrait) for
/// the en-US set. The same images are the Mac App Store set: an iPhone/iPad
/// app offered on Apple silicon Macs is listed with its iPad screenshots and
/// has no Mac slot of its own, so every frame here is the three-column
/// window a Mac buyer will get.
///
/// Raw PNGs land in the app container's tmp directory named
/// `en-US-ipad-NN-<shot>.png`; `scripts/capture-app-store-ipad-screenshots.sh`
/// copies them into `app-store-assets/screenshots/cards/raw/en-US/ipad/` and
/// renders the cards.
///
/// A subclass of the shared base so it resolves the shell the app reports:
/// the frames only mean anything in the expanded split shell, so this skips
/// on an iPhone rather than shipping a stack-shaped "iPad" capture.
@MainActor
final class AppStoreIPadScreenshotUITests: MileageTrackerUITestCase {
    private static let seed = "en-US"

    private static var captureArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-app-store-screenshot-data",
            "--seed-trip-suggestions",
            "--skip-onboarding",
            "--screenshot-locale=\(seed)",
            "--test-store-suffix=app-store-ipad-\(seed)"
        ]
    }

    override var launchArguments: [String] {
        Self.captureArguments + Self.englishLocaleArguments
    }

    private var screenshotDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// The touch-idiom frames: inbox with a trip open, All Trips with a trip
    /// open, a closed month, and Settings. Everything a plain iPad shows.
    func testCaptureENUSPad() throws {
        try XCTSkipUnless(
            shell == .split,
            "The iPad set is the expanded split shell; run this on an iPad simulator."
        )
        waitForTripsScreen()

        // 01 — Need Review with the hero suggestion drive open in the pane.
        openNeedsReview()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 12), "Inbox never showed a drive row")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "tripSuggestionRow").firstMatch
                .waitForExistence(timeout: 15),
            "AI suggestion line never appeared — backfill or fixtures broken"
        )
        assertStaticText(containing: "Columbus", context: "seed place")
        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetail(timeout: 12), "Trip detail never filled the reading pane")
        settle(5.0)
        capture("01-inbox-open")

        // 02 — All Trips with a classified drive open. The third row: the
        // first two are the newest unreviewed drives, which card 01 already shows.
        openAllTrips()
        XCTAssertTrue(cards.element(boundBy: 2).waitForExistence(timeout: 12))
        tapDriveCard(cards.element(boundBy: 2))
        XCTAssertTrue(waitForTripDetail(timeout: 12))
        settle(5.0)
        capture("02-all-trips-open")

        // 04 — the most recently closed month, fully classified, with its
        // first drive open. Index 1, not 0: index 0 is the current month,
        // which the seed deliberately fills with the review queue.
        let monthRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")
        )
        XCTAssertGreaterThan(monthRows.count, 1, "Seed must supply a closed month below the current one")
        monthRows.element(boundBy: 1).tap()
        XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 12))
        assertStaticText(containing: "$", context: "report currency")
        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetail(timeout: 12))
        settle(5.0)
        capture("04-month-open")

        // 05 — Settings, scrolled to the Sync / App Lock privacy cluster.
        openSettingsFromTripsList()
        scrollSettingsToPrivacySection()
        settle()
        capture("05-settings")
    }

    /// The Mac's selection model, which only `--mac-mode=on` reaches from a
    /// simulator: several rows filled, the bottom-bar verbs enabled, and the
    /// reading pane summarising the selection.
    func testCaptureENUSMacSelection() throws {
        try XCTSkipUnless(
            shell == .split,
            "The Mac list only exists in the expanded split shell; run this on an iPad simulator."
        )
        relaunch(arguments: Self.captureArguments + ["--mac-mode=on"])
        try XCTSkipUnless(shell == .split, "Mac mode still needs the expanded split shell")
        waitForTripsScreen()

        openAllTrips()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 3).waitForExistence(timeout: 12), "Need at least four rows to select")

        let selectMany = app.buttons["selectManyReadingPaneTestSelection"].firstMatch
        XCTAssertTrue(selectMany.waitForExistence(timeout: 6), "Mac-mode test driver missing")
        selectMany.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["multiTripSelectionPane"].firstMatch
                .waitForExistence(timeout: 8),
            "Several selected trips must summarise in the reading pane"
        )
        let merge = app.buttons["mergeTripsButton"]
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !merge.isEnabled {
            usleep(100_000)
        }
        XCTAssertTrue(merge.isEnabled, "A multi-selection enables Merge")
        settle()
        capture("03-selection")

        // 06 — the Mac window source: rotated to the wide Mac-mode layout, with
        // the most recently closed month open and its first drive in the
        // reading pane ("Organize and export"). Captured in Mac mode so the
        // content is exactly what the Designed-for-iPad app draws on a Mac;
        // XCUIScreen writes this on the iPad's native portrait pixel canvas;
        // the capture script takes an upright 4:3 top crop, then the card
        // renderer trims the status bar and draws the macOS titlebar strip.
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(2.0)
        let monthRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")
        )
        XCTAssertGreaterThan(monthRows.count, 1, "Seed must supply a closed month below the current one")
        monthRows.element(boundBy: 1).tap()
        XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 12))
        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetail(timeout: 12))
        settle(5.0)
        capture("06-mac-month")
        XCUIDevice.shared.orientation = .portrait
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

    private func scrollSettingsToPrivacySection() {
        let syncToggle = app.switches["settingsSyncToggle"].firstMatch
        let appLockToggle = app.switches["settingsAppLockToggle"].firstMatch
        var attempts = 0
        while (!syncToggle.exists || !appLockToggle.exists) && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    /// Row map thumbnails and the detail route map are `MKMapSnapshotter`
    /// work with nothing queryable to wait on; see `AppStoreScreenshotUITests`.
    private func settle(_ interval: TimeInterval = 3.0) {
        Thread.sleep(forTimeInterval: interval)
    }

    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let url = screenshotDirectory.appendingPathComponent("\(Self.seed)-ipad-\(name).png")
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
        } catch {
            XCTFail("Failed to write screenshot \(name): \(error.localizedDescription)", file: file, line: line)
        }
    }
}
