import XCTest

/// End-to-end Siri coverage for natural references to both the drive currently
/// visible in Mileager and the newest completed trip. Unlike the
/// AppIntentsTesting suite, this goes through Siri's real request UI and
/// natural-language routing before verifying the app mutation. The suffixed
/// UI-test store keeps every synthetic drive separate from the user's mileage
/// database when this suite runs on a physical iPhone.
@MainActor
final class SiriCurrentDriveUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        super.launchArguments + [
            "--test-store-suffix=siri-current-drive-xcuitest",
            "--seed-current-drive"
        ]
    }

    override func tearDown() async throws {
        // Siri can keep an assistant session alive after the target app returns
        // to the foreground. Ending on the Home Screen prevents that session
        // from stalling the next Siri activation in the same test run.
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        try await super.tearDown()
    }

    func testThisDriveRoutesToMileagerAndClassifiesBusiness() {
        assertSiriClassification(
            phrase: "Mark this drive as business in Mileage Tracker",
            expectedIdentifier: "currentDriveBarClassificationbusiness",
            expectedDialogFragment: "Marked your current drive as Business"
        )
    }

    func testCurrentDriveRoutesToMileagerAndClassifiesPersonal() {
        assertSiriClassification(
            phrase: "Mark my current drive as personal in Mileager",
            expectedIdentifier: "currentDriveBarClassificationpersonal",
            expectedDialogFragment: "Marked your current drive as Personal"
        )
    }

    func testThisTripRoutesToMileagerAndClassifiesCurrentDrive() {
        assertSiriClassification(
            phrase: "Mark this trip as business in Mileager",
            expectedIdentifier: "currentDriveBarClassificationbusiness",
            expectedDialogFragment: "Marked your current drive as Business"
        )
    }

    func testLastDriveRoutesToMileagerAndClassifiesNewestCompletedTrip() {
        assertSiriCompletedTripClassification(
            phrase: "Mark my last drive as personal in Mileage Tracker"
        )
    }

    func testPreviousDriveRoutesToMileagerAndClassifiesNewestCompletedTrip() {
        assertSiriCompletedTripClassification(
            phrase: "Mark my previous drive as personal in Mileager"
        )
    }

    func testGenericTripRoutesToMileagerAndPromptsForAParameter() {
        waitForTripsScreen()
        activateSiri(phrase: "Classify a trip in Mileager")

        let siri = XCUIDevice.shared.siriService
        let recentTripText = siri.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Home' AND label CONTAINS[c] 'Client'")
        ).firstMatch
        let recentTripButton = siri.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Home' AND label CONTAINS[c] 'Client'")
        ).firstMatch
        let category = siri.buttons.matching(
            NSPredicate(format: "label ==[c] 'Business' OR label ==[c] 'Personal'")
        ).firstMatch

        guard recentTripText.waitForExistence(timeout: 10)
                || recentTripButton.waitForExistence(timeout: 2)
                || category.waitForExistence(timeout: 4) else {
            attachSiriFailure(phrase: "Classify a trip in Mileager")
            XCTFail(
                "Siri did not route the generic trip request to Mileager's required-parameter flow. "
                    + "UI: \(siri.debugDescription)"
            )
            return
        }
    }

    private func assertSiriClassification(
        phrase: String,
        expectedIdentifier: String,
        expectedDialogFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForTripsScreen(file: file, line: line)
        let classification = app.buttons[expectedIdentifier].firstMatch
        XCTAssertTrue(classification.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertFalse(classification.isSelected, "The seeded drive must start unclassified.", file: file, line: line)

        activateSiri(phrase: phrase)

        let siri = XCUIDevice.shared.siriService
        let response = siri.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", expectedDialogFragment)
        ).firstMatch
        guard response.waitForExistence(timeout: 20) else {
            attachSiriFailure(phrase: phrase)
            XCTFail(
                "Siri did not return Mileager's success dialog for '\(phrase)'. UI: \(siri.debugDescription)",
                file: file,
                line: line
            )
            return
        }

        app.activate()
        XCTAssertTrue(classification.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(
            waitForSelection(classification),
            "Siri routed the phrase but the current drive did not receive the classification.",
            file: file,
            line: line
        )
    }

    private func assertSiriCompletedTripClassification(
        phrase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForTripsScreen(file: file, line: line)
        activateSiri(phrase: phrase)

        let siri = XCUIDevice.shared.siriService
        let response = siri.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                "Marked",
                "Personal"
            )
        ).firstMatch
        guard response.waitForExistence(timeout: 20) else {
            attachSiriFailure(phrase: phrase)
            XCTFail(
                "Siri did not classify Mileager's newest completed trip for '\(phrase)'. "
                    + "UI: \(siri.debugDescription)",
                file: file,
                line: line
            )
            return
        }

        app.activate()
        waitForTripsScreen(file: file, line: line)
        openNewestMonth()
        let latestTrip = app.staticTexts["Home → Client"].firstMatch
        XCTAssertTrue(latestTrip.waitForExistence(timeout: 8), file: file, line: line)
        latestTrip.tap()
        XCTAssertTrue(
            waitForTripDetail(timeout: 8),
            file: file,
            line: line
        )
        let personal = app.buttons["tripDetailClassificationpersonal"].firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(
            waitForSelection(personal),
            "Siri routed the phrase but did not update the newest completed trip.",
            file: file,
            line: line
        )
    }

    private func activateSiri(phrase: String) {
        let siri = XCUIDevice.shared.siriService
        siri.activate(voiceRecognitionText: phrase)

        // The first Siri invocation after installing a development build can
        // require explicit per-app consent. Accepting the system-owned prompt
        // continues the original request; later invocations skip this branch.
        let turnOn = siri.buttons["Turn On"].firstMatch
        if turnOn.waitForExistence(timeout: 6) {
            turnOn.tap()
        }
    }

    private func attachSiriFailure(phrase: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Siri response for: \(phrase)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitForSelection(
        _ element: XCUIElement,
        timeout: TimeInterval = 8
    ) -> Bool {
        let predicate = NSPredicate { _, _ in element.isSelected }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
