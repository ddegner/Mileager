import XCTest

@MainActor
final class VehiclesUITests: MileageTrackerUITestCase {
    private let seededVehicleArguments = [
        "--uitesting", "--reset-data", "--reset-preferences",
        "--seed-mileage-data", "--skip-onboarding", "--seed-vehicles"
    ]

    func testDefaultVehicleExistsAndCannotBeDeletedWhenSole() {
        waitForTripsScreen()
        openVehiclesList()

        // Every configured iPhone/iPad install owns the backfilled default vehicle.
        XCTAssertTrue(app.staticTexts["My Car"].waitForExistence(timeout: 4))
        app.staticTexts["My Car"].tap()
        XCTAssertTrue(app.navigationBars["My Car"].waitForExistence(timeout: 4))

        // The odometer now lives on the vehicle page, and the sole vehicle
        // cannot be deleted.
        XCTAssertTrue(app.textFields["vehicleOdometerField"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["vehicleDetailDelete"].exists)
    }

    func testOdometerEditingLivesOnVehicleDetail() {
        relaunch(arguments: seededVehicleArguments)
        waitForTripsScreen()
        openVehiclesList()

        app.staticTexts["Honda Odyssey"].tap()
        XCTAssertTrue(app.navigationBars["Honda Odyssey"].waitForExistence(timeout: 4))

        // Odometer editing lives on the vehicle page (near the top of the form).
        let field = app.textFields["vehicleOdometerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("60000")
        // The keyboard bar's Done saves the reading.
        dismissKeyboardIfNeeded()

        app.buttons["vehicleOdometerHistoryLink"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Odometer History"].waitForExistence(timeout: 4))
        let row = app.descendants(matching: .any).matching(identifier: "odometerHistoryRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4))

        // With two vehicles, deletion is available again (the delete section sits
        // at the bottom of the form, so scroll it into the accessibility tree).
        tapBack(from: "Odometer History")
        scrollUntilExists(app.staticTexts["Car Connections"])
        XCTAssertTrue(app.staticTexts["No CarPlay or Bluetooth connections are saved for this vehicle yet."].exists)
        scrollUntilExists(app.buttons["vehicleDetailDelete"])
        XCTAssertTrue(app.buttons["vehicleDetailDelete"].exists)
    }

    func testVehicleRemovalExplainsEveryConsequenceBeforeDeleting() {
        relaunch(arguments: seededVehicleArguments)
        waitForTripsScreen()
        openVehiclesList()

        app.staticTexts["Ford F-150"].tap()
        XCTAssertTrue(app.navigationBars["Ford F-150"].waitForExistence(timeout: 4))
        // isHittable can be true for the button's six-pixel visible edge while
        // its center is below the screen. Bring the whole control into view.
        let removeButton = app.buttons["vehicleDetailDelete"]
        scrollIntoComfortableTapPosition(removeButton)
        removeButton.tap()

        let confirmationAppeared = app.staticTexts["Remove Ford F-150?"].waitForExistence(timeout: 2)
        if !confirmationAppeared {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Missing vehicle removal confirmation"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(confirmationAppeared, app.debugDescription)
        let message = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                "Trips assigned to Ford F-150 will remain and will appear under Honda Odyssey, your default vehicle. Ford F-150’s odometer history and saved CarPlay and Bluetooth connections will be deleted."
            )
        ).firstMatch
        XCTAssertTrue(message.exists)
        XCTAssertTrue(app.buttons["vehicleDetailDeleteConfirm"].exists)
    }

    /// Regression guard for the rename dirty check: an edited name must still
    /// save when the detail screen pops — the originalName comparison may only
    /// suppress the untouched-dismissal write, never a real rename.
    func testRenameOnDetailPopPersists() {
        waitForTripsScreen()
        openVehiclesList()

        XCTAssertTrue(app.staticTexts["My Car"].waitForExistence(timeout: 4))
        app.staticTexts["My Car"].tap()
        XCTAssertTrue(app.navigationBars["My Car"].waitForExistence(timeout: 4))

        replaceText(in: app.textFields["vehicleNameField"], with: "Honda Fit")
        dismissKeyboardIfNeeded()
        // The nav title tracks the edited name live.
        tapBack(from: "Honda Fit")

        XCTAssertTrue(app.navigationBars["Vehicles"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Honda Fit"].waitForExistence(timeout: 4), "Rename must persist on pop")
        XCTAssertFalse(app.staticTexts["My Car"].exists)
    }

    func testAddVehiclePersistsAcrossRelaunch() {
        waitForTripsScreen()
        openVehiclesList()

        app.buttons["vehiclesAddButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Vehicle"].waitForExistence(timeout: 4))
        replaceText(in: app.textFields["vehicleNameField"], with: "Honda Odyssey")
        dismissKeyboardIfNeeded()
        app.buttons["vehicleAddConfirm"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Vehicles"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Honda Odyssey"].waitForExistence(timeout: 4))

        // Relaunch without resetting data; the vehicle must survive.
        relaunch(arguments: ["--uitesting", "--skip-onboarding"])
        waitForTripsScreen()
        openVehiclesList()
        XCTAssertTrue(app.staticTexts["Honda Odyssey"].waitForExistence(timeout: 4))
    }

    /// Two vehicles is what puts a vehicle scope in the list's filter menu.
    ///
    /// This deliberately does NOT look for the vehicle name on the row. The
    /// preview line stopped carrying it in "Simplify trip summary status rails"
    /// — that slot is reserved for a blocker or a user note, and both seeded
    /// trips spend it on their notes. Assert the scope control instead, which
    /// is the thing a second vehicle actually unlocks.
    func testSeededVehiclesPutAVehicleScopeInTheListFilter() {
        relaunch(arguments: seededVehicleArguments)
        waitForTripsScreen()

        // Both seeded trips land in the one seeded month, one per vehicle.
        openNewestMonth()
        XCTAssertTrue(app.staticTexts["Home → Client"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Gym → Home"].firstMatch.exists)

        let filter = app.buttons["filterDrivesMenu"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 4))
        XCTAssertEqual(filter.value as? String, "All Trips, All Vehicles")

        // The scope is a Picker inside that menu, so its rows only enter the
        // accessibility tree once the menu opens.
        filter.tap()
        XCTAssertTrue(app.buttons["All Vehicles"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Honda Odyssey"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Ford F-150"].firstMatch.exists)
    }

    func testVehicleFilterDoesNotSilentlyCarryBackToMailboxes() {
        relaunch(arguments: seededVehicleArguments)
        waitForTripsScreen()
        openAllTrips()

        app.buttons["filterDrivesMenu"].tap()
        let fordChoice = app.buttons["Ford F-150"].firstMatch
        XCTAssertTrue(fordChoice.waitForExistence(timeout: 2))
        fordChoice.tap()
        XCTAssertEqual(
            app.buttons["filterDrivesMenu"].firstMatch.value as? String,
            "All Trips, Ford F-150"
        )
        // The scope narrows the list to the Ford's one seeded trip.
        XCTAssertTrue(app.staticTexts["Gym → Home"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Home → Client"].firstMatch.exists)

        tapBack(from: "All Trips")
        assertMailboxRootIsShowing()
        openAllTrips()

        // Mailboxes has no visible vehicle-scope control. Returning there must
        // clear the pushed list's scope so its month/year totals and exports
        // cannot remain silently narrowed.
        XCTAssertEqual(
            app.buttons["filterDrivesMenu"].firstMatch.value as? String,
            "All Trips, All Vehicles"
        )
    }

    /// Verifies the vehicle strings actually resolve to translations at runtime
    /// (a key that doesn't match the code silently falls back to English),
    /// using the Vehicles list in Spanish. The backfilled default vehicle is
    /// named in the device language, so "My Car" appears as "Mi coche".
    func testVehicleStringsLocalizeInSpanish() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "--reset-data", "--reset-preferences",
            "--seed-mileage-data", "--skip-onboarding",
            "-AppleLanguages", "(es)", "-AppleLocale", "es_ES"
        ]
        app.launch()

        let settingsButton = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 12))
        settingsButton.tap()

        app.buttons["settingsVehiclesLink"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Mi coche"].waitForExistence(timeout: 4),
                      "Spanish translation for the default vehicle name 'My Car' did not resolve")
        XCTAssertTrue(app.staticTexts["Añadir vehículo"].waitForExistence(timeout: 4),
                      "Spanish translation for 'Add Vehicle' did not resolve")
    }

    /// Opens Settings and pushes the Vehicles list, scrolling the row into view.
    private func openVehiclesList() {
        openSettingsFromTripsList()
        let link = app.buttons["settingsVehiclesLink"].firstMatch
        scrollUntilVisible(link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Vehicles"].waitForExistence(timeout: 4))
    }
}
