import XCTest

@MainActor
final class OnboardingUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        ["--uitesting", "--reset-data", "--reset-preferences", "--reset-onboarding", "--seed-mileage-data"]
    }

    func testOnboardingFirstLaunchCompletesAndPersists() {
        XCTAssertTrue(app.navigationBars["Permissions"].waitForExistence(timeout: 8))
        let intro = app.staticTexts["onboardingPermissionsIntroText"]
        XCTAssertTrue(intro.waitForExistence(timeout: 2))
        XCTAssertEqual(
            intro.label,
            "Automatic tracking uses Motion & Fitness to recognize driving and Location to record distance. Bluetooth can improve trip starts, and Notifications can remind you to review trips. Manual entry and exports work without granting these permissions."
        )
        XCTAssertTrue(app.buttons["onboardingLocationPermissionRow"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["onboardingLocationPermissionSetUpButton"].exists)
        XCTAssertFalse(app.buttons["onboardingPermissionsButton"].exists)
        XCTAssertFalse(app.buttons["Enable All Permissions"].exists)
        advanceOnboardingToVehicle()
        XCTAssertFalse(app.buttons["onboardingSkipOdometerButton"].exists)

        // The vehicle name is prefilled with the default; enter a reading that
        // must land on this one vehicle.
        XCTAssertTrue(app.textFields["vehicleNameField"].waitForExistence(timeout: 4))
        let field = app.textFields["vehicleOdometerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("12345")
        dismissKeyboardIfNeeded()

        app.buttons["onboardingFinishButton"].tap()
        waitForTripsScreen()

        relaunch(arguments: ["--uitesting", "--seed-mileage-data"])
        XCTAssertFalse(app.navigationBars["Permissions"].waitForExistence(timeout: 1))
        waitForTripsScreen()

        // The reading persisted under "My Car" → Odometer History.
        openSettingsFromTripsList()
        app.buttons["settingsVehiclesLink"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Vehicles"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["My Car"].waitForExistence(timeout: 4))
        app.staticTexts["My Car"].tap()
        XCTAssertTrue(app.navigationBars["My Car"].waitForExistence(timeout: 4))
        app.buttons["vehicleOdometerHistoryLink"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Odometer History"].waitForExistence(timeout: 4))
        let row = app.descendants(matching: .any).matching(identifier: "odometerHistoryRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4))
    }
}

@MainActor
final class MacOnboardingUITests: MileageTrackerUITestCase {
    override var requiresExpandedSplitShell: Bool { true }

    override var launchArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--reset-onboarding",
            "--mac-mode=on"
        ] + Self.englishLocaleArguments
    }

    func testSetUpWithoutICloudFinishesEmptyAndLeavesExplicitAddPath() {
        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Your Vehicle"].exists)

        app.buttons["onboardingSkipSyncButton"].tap()
        waitForTripsScreen()
        XCTAssertFalse(app.navigationBars["Your Vehicle"].exists)

        openSettingsFromTripsList()
        app.buttons["settingsVehiclesLink"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Vehicles"].waitForExistence(timeout: 4))
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "vehicleRow").count,
            0
        )
        XCTAssertTrue(app.buttons["vehiclesAddButton"].waitForExistence(timeout: 4))
        app.buttons["vehiclesAddButton"].tap()
        XCTAssertTrue(app.navigationBars["New Vehicle"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["vehicleNameField"].exists)
    }

    func testSyncConfirmationWarnsThatVehicleNamesAreNotMerged() {
        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 8))
        app.buttons["onboardingUseSyncButton"].tap()

        XCTAssertTrue(app.navigationBars["Combine with iCloud"].waitForExistence(timeout: 4))
        let warning = "Vehicles saved here will also be combined with vehicles already in iCloud. "
            + "Similar names stay separate; Mileager does not merge them automatically."
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label == %@", warning))
                .firstMatch.waitForExistence(timeout: 4)
        )
    }
}
