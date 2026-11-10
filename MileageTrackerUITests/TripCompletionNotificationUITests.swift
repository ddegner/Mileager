import XCTest

@MainActor
final class TripCompletionNotificationUITests: XCTestCase {
    func testNotificationBodyOpensCompletedTripAfterBackgrounding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-mapkit-fixtures",
            "--reset-data",
            "--reset-preferences",
            "--seed-unresolved-mix",
            "--skip-onboarding",
            "--test-store-suffix=notification-tap",
            "--schedule-trip-completion-notification"
        ] + MileageTrackerUITestCase.englishLocaleArguments
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
        XCTAssertTrue(app.staticTexts["COSI → North Market"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)

        let notification = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Notification")
        ).containing(NSPredicate(format: "label CONTAINS[c] %@", "Mileager")).firstMatch
        // iOS 27 may defer the permission prompt until the app backgrounds.
        // Wait for either real system UI instead of leaving a late alert
        // blocking the notification while the banner timeout expires.
        let permissionOrBanner = NSPredicate { _, _ in allow.exists || notification.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: permissionOrBanner, object: nil
        )], timeout: 40), .completed, springboard.debugDescription)
        if allow.exists { allow.tap() }
        // SpringBoard can spend another ten seconds processing the notification
        // after its twelve-second trigger fires on a cold simulator. Keep the
        // real banner-tap path, with enough time for that system delivery step.
        XCTAssertTrue(notification.waitForExistence(timeout: 40), springboard.debugDescription)
        notification.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.textFields["tripDetailOrigin"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.textFields["tripDetailOrigin"].value as? String, "COSI")
        XCTAssertFalse(app.otherElements["privacyCover"].exists)
        XCTAssertEqual(app.buttons["tripDetailClassificationMore"].value as? String, "Not Classified")
        XCTAssertFalse(app.buttons["tripDetailClassificationpersonal"].isSelected)
        XCTAssertTrue(app.buttons["tripDetailClassificationpersonal"].isHittable)
        app.buttons["tripDetailClassificationpersonal"].tap()
        XCTAssertTrue(app.buttons["tripDetailClassificationpersonal"].isSelected)
    }
}
