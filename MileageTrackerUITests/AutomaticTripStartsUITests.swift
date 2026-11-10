import XCTest

@MainActor
final class AutomaticTripStartsUITests: MileageTrackerUITestCase {
    private let approvedIntro = "Adding a \"Shortcuts automation\" can start a trip when your phone connects to your car's bluetooth or Carplay."

    func testTriggerSettingsPlacementAndBothDefault() {
        waitForTripsScreen()
        openSettingsFromTripsList()

        let start = app.buttons["Start Tracking"]
        let today = app.buttons["Pause Until Midnight"]
        let vacation = app.buttons["Vacation Pause"]
        let setup = app.buttons["settingsShortcutSetupLink"]
        let permissions = app.buttons["settingsTrackingPermissionsLink"]
        let liveActivity = app.switches["settingsCurrentDriveLiveActivityToggle"]
        let automaticTracking = app.staticTexts["Automatic Tracking"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 4))
        XCTAssertTrue(modePicker.label.contains("Start Trips With"))
        XCTAssertTrue(automaticTracking.exists)
        XCTAssertTrue(trackingStatus.exists)
        XCTAssertEqual(trackingStatus.label, "Off")
        XCTAssertTrue(start.exists)
        XCTAssertTrue(today.exists)
        XCTAssertTrue(vacation.exists)
        XCTAssertFalse(today.isEnabled)
        XCTAssertFalse(vacation.isEnabled)
        XCTAssertEqual(start.frame.midY, today.frame.midY, accuracy: 1)
        XCTAssertEqual(start.frame.midY, vacation.frame.midY, accuracy: 1)
        XCTAssertEqual(
            today.frame.height, vacation.frame.height, accuracy: 1,
            "Neither pause label should wrap onto another line"
        )
        XCTAssertTrue(setup.exists)
        XCTAssertTrue(setup.label.contains("Set Up Bluetooth"))
        XCTAssertTrue(permissions.exists)
        XCTAssertTrue(liveActivity.exists)
        XCTAssertLessThan(automaticTracking.frame.minY, start.frame.minY)
        XCTAssertGreaterThan(modePicker.frame.minY, start.frame.minY)
        XCTAssertLessThan(modePicker.frame.minY, setup.frame.minY)
        XCTAssertLessThan(setup.frame.minY, permissions.frame.minY)
        XCTAssertLessThan(permissions.frame.minY, liveActivity.frame.minY)
        assertMode("Both")
        let motion = modePicker.buttons["Motion"]
        let bluetooth = modePicker.buttons["Bluetooth"]
        let both = modePicker.buttons["Both"]
        XCTAssertEqual(modePicker.buttons.count, 3)
        XCTAssertTrue(bluetooth.exists)
        XCTAssertTrue(both.exists)
        XCTAssertEqual(motion.frame.minY, bluetooth.frame.minY, accuracy: 1)
        XCTAssertEqual(motion.frame.minY, both.frame.minY, accuracy: 1)
        XCTAssertEqual(motion.frame.height, bluetooth.frame.height, accuracy: 1)
        XCTAssertEqual(motion.frame.height, both.frame.height, accuracy: 1)
        XCTAssertLessThan(motion.frame.midX, bluetooth.frame.midX)
        XCTAssertLessThan(bluetooth.frame.midX, both.frame.midX)
        XCTAssertFalse(app.staticTexts[approvedIntro].exists)
        attachScreen(named: "Automatic Tracking Off with colored controls")
    }

    func testActiveTrackingActionsStayOnOneRowAndOpenVacationPicker() {
        waitForTripsScreen()
        openSettingsFromTripsList()
        let start = app.buttons["Start Tracking"]
        XCTAssertTrue(start.waitForExistence(timeout: 4))
        XCTAssertEqual(trackingStatus.label, "Off")
        let inactivePickerY = modePicker.frame.minY
        start.tap()

        let stop = app.buttons["Stop Tracking"]
        let today = app.buttons["Pause Until Midnight"]
        let vacation = app.buttons["Vacation Pause"]
        XCTAssertTrue(stop.waitForExistence(timeout: 4))
        XCTAssertEqual(trackingStatus.label, "On")
        XCTAssertTrue(today.isHittable)
        XCTAssertTrue(vacation.isHittable)
        XCTAssertTrue(today.isEnabled)
        XCTAssertTrue(vacation.isEnabled)
        XCTAssertEqual(stop.frame.midY, today.frame.midY, accuracy: 1)
        XCTAssertEqual(stop.frame.midY, vacation.frame.midY, accuracy: 1)
        XCTAssertEqual(
            today.frame.height, vacation.frame.height, accuracy: 1,
            "Neither pause label should wrap onto another line"
        )
        XCTAssertLessThan(stop.frame.midX, today.frame.midX)
        XCTAssertLessThan(today.frame.midX, vacation.frame.midX)
        XCTAssertLessThan(stop.frame.width, today.frame.width)
        XCTAssertLessThan(stop.frame.width, vacation.frame.width)
        XCTAssertLessThan(stop.frame.maxY, modePicker.frame.minY)
        XCTAssertEqual(modePicker.frame.minY, inactivePickerY, accuracy: 1)
        attachScreen(named: "Automatic Tracking On with larger Stop icon and colored pause buttons")

        vacation.tap()
        let vacationNavigation = app.navigationBars["Restart date"]
        XCTAssertTrue(vacationNavigation.waitForExistence(timeout: 4))
        vacationNavigation.buttons["Set"].tap()
        XCTAssertTrue(vacationNavigation.waitForNonExistence(timeout: 4))

        // UI tests suppress the capture runtime, so the pause's scheduling is
        // covered by runtime tests; the sheet and native button routing are real.
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 4))
        XCTAssertEqual(trackingStatus.label, "Off")
        XCTAssertTrue(today.exists)
        XCTAssertTrue(vacation.exists)
        XCTAssertFalse(today.isEnabled)
        XCTAssertFalse(vacation.isEnabled)
        XCTAssertEqual(today.frame.height, vacation.frame.height, accuracy: 1)
        XCTAssertEqual(modePicker.frame.minY, inactivePickerY, accuracy: 1)
    }

    func testTriggerChoicesSelectDirectlyAndExplicitMotionPersists() {
        // The default fixture has no confirmed car connection or automation.
        waitForTripsScreen()
        openSettingsFromTripsList()
        assertMode("Both")
        let defaultRowHeight = modePicker.frame.height
        selectMode("Bluetooth")
        assertMode("Bluetooth")
        XCTAssertEqual(
            modePicker.frame.height, defaultRowHeight, accuracy: 1,
            "Changing the selected segment must not add another row"
        )
        XCTAssertTrue(app.buttons["settingsDone"].isHittable)
        XCTAssertFalse(app.navigationBars["Connect a Car"].exists)
        XCTAssertFalse(app.navigationBars["Create a Shortcuts Automation"].exists)
        selectMode("Motion")
        assertMode("Motion")

        relaunch(arguments: ["--uitesting", "--uitesting-mapkit-fixtures", "--skip-onboarding"])
        waitForTripsScreen()
        openSettingsFromTripsList()
        assertMode("Motion")
        selectMode("Both")
        assertMode("Both")
    }

    func testPausedTrackingKeepsModeAndSetupAvailable() {
        relaunch(arguments: launchArguments + ["--seed-tracking-paused"])
        waitForTripsScreen()
        openSettingsFromTripsList()
        XCTAssertEqual(trackingStatus.label, "Paused")
        XCTAssertTrue(app.buttons["Resume Tracking"].isEnabled)
        XCTAssertFalse(app.buttons["settingsPauseTodayButton"].isEnabled)
        XCTAssertFalse(app.buttons["settingsVacationPauseButton"].isEnabled)
        selectMode("Bluetooth")
        XCTAssertEqual(trackingStatus.label, "Paused")
        XCTAssertTrue(app.buttons["settingsShortcutSetupLink"].isEnabled)
        XCTAssertTrue(app.buttons["settingsTrackingPermissionsLink"].isEnabled)
        attachScreen(named: "Paused tracking with Bluetooth selected")
    }

    func testSetupOpensShortcutsAutomationInstructions() {
        waitForTripsScreen()
        openSettingsFromTripsList()
        XCTAssertFalse(app.staticTexts[approvedIntro].exists)

        let setup = app.buttons["settingsShortcutSetupLink"]
        scrollUntilVisible(setup)
        XCTAssertFalse(setup.label.contains("Shortcut received"))
        setup.tap()
        XCTAssertTrue(app.navigationBars["Create a Shortcuts Automation"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["settingsShortcutSetupText"].label, approvedIntro)
        XCTAssertTrue(app.buttons["settingsOpenShortcutsButton"].exists)
        XCTAssertFalse(shortcutLastReceived.exists)
        tapBack(from: "Create a Shortcuts Automation")
        assertMode("Both")
    }

    func testReceivedShortcutIndicatorAndDatePersist() {
        relaunch(arguments: launchArguments + ["--seed-vehicle-shortcut-receipt"])
        waitForTripsScreen()
        openSettingsFromTripsList()

        let setup = app.buttons["settingsShortcutSetupLink"]
        scrollUntilVisible(setup)
        XCTAssertTrue(setup.label.contains("Set Up Bluetooth"))
        XCTAssertTrue(setup.label.contains("Shortcut received"))
        attachScreen(named: "Automatic Tracking with received Bluetooth shortcut")

        setup.tap()
        XCTAssertTrue(app.navigationBars["Create a Shortcuts Automation"].waitForExistence(timeout: 4))
        XCTAssertTrue(shortcutLastReceived.waitForExistence(timeout: 4))
        let receivedLabel = shortcutLastReceived.label
        attachScreen(named: "Bluetooth setup with last shortcut receipt date")

        // Relaunch without seeding or clearing preferences so this proves the
        // indicator represents a saved receipt rather than this launch's fixture.
        relaunch(arguments: ["--uitesting", "--uitesting-mapkit-fixtures", "--skip-onboarding"])
        waitForTripsScreen()
        openSettingsFromTripsList()
        let persistedSetup = app.buttons["settingsShortcutSetupLink"]
        scrollUntilVisible(persistedSetup)
        XCTAssertTrue(persistedSetup.label.contains("Set Up Bluetooth"))
        XCTAssertTrue(persistedSetup.label.contains("Shortcut received"))
        persistedSetup.tap()
        XCTAssertTrue(app.navigationBars["Create a Shortcuts Automation"].waitForExistence(timeout: 4))
        XCTAssertTrue(shortcutLastReceived.waitForExistence(timeout: 4))
        XCTAssertEqual(shortcutLastReceived.label, receivedLabel)
    }

    func testVehicleBluetoothSetupUsesSharedGuideWithoutClaimingCarReceipt() {
        relaunch(arguments: launchArguments + ["--seed-vehicles", "--seed-vehicle-shortcut-receipt"])
        waitForTripsScreen()
        openSettingsFromTripsList()
        openSeededVehicle()

        let setup = app.buttons["vehicleDetailShortcutSetupLink"]
        scrollIntoComfortableTapPosition(setup)
        XCTAssertTrue(setup.label.contains("Set Up Bluetooth"))
        XCTAssertFalse(setup.label.contains("Shortcut received"))
        XCTAssertFalse(app.buttons["vehicleDetailOpenShortcutsButton"].exists)
        setup.tap()
        XCTAssertTrue(app.navigationBars["Create a Shortcuts Automation"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["settingsShortcutSetupText"].label, approvedIntro)
        XCTAssertFalse(shortcutLastReceived.exists)
        XCTAssertTrue(app.buttons["settingsOpenShortcutsButton"].exists)
    }

    func testTriggerSettingsAreAbsentOnMac() {
        relaunch(arguments: launchArguments + ["--mac-mode=on", "--seed-vehicles"])
        waitForTripsScreen()
        openSettingsFromTripsList()
        XCTAssertTrue(app.buttons["settingsTrackingPermissionsLink"].exists)
        XCTAssertFalse(modePicker.exists)
        XCTAssertFalse(app.buttons["settingsShortcutSetupLink"].exists)
        XCTAssertFalse(app.switches["settingsCurrentDriveLiveActivityToggle"].exists)
        XCTAssertFalse(trackingStatus.exists)
        openSeededVehicle()
        XCTAssertFalse(app.buttons["vehicleDetailShortcutSetupLink"].exists)
        XCTAssertFalse(app.buttons["vehicleDetailOpenShortcutsButton"].exists)
    }

    private var modePicker: XCUIElement {
        app.segmentedControls["settingsAutomaticTripStartsPicker"].firstMatch
    }

    private var trackingStatus: XCUIElement {
        app.staticTexts["settingsAutomaticTrackingStatus"].firstMatch
    }

    private var shortcutLastReceived: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "settingsShortcutLastReceived").firstMatch
    }

    private func openSeededVehicle() {
        let vehicles = app.buttons["settingsVehiclesLink"]
        scrollUntilVisible(vehicles)
        vehicles.tap()
        let vehicle = app.staticTexts["Honda Odyssey"]
        XCTAssertTrue(vehicle.waitForExistence(timeout: 4))
        vehicle.tap()
        XCTAssertTrue(app.navigationBars["Honda Odyssey"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["vehicleOdometerField"].exists)
    }

    private func selectMode(_ title: String) {
        scrollUntilVisible(modePicker)
        let option = modePicker.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 4))
        option.tap()
    }

    private func assertMode(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(modePicker.waitForExistence(timeout: 4), file: file, line: line)
        let selected = modePicker.buttons[title]
        XCTAssertTrue(selected.exists, file: file, line: line)
        XCTAssertTrue(selected.isSelected, "Expected \(title) to be selected", file: file, line: line)
        for option in modePicker.buttons.allElementsBoundByIndex where option.label != title {
            XCTAssertFalse(option.isSelected, "Only \(title) should be selected", file: file, line: line)
        }
    }

    private func attachScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class AutomaticTrackingAccessibleLayoutUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting", "--uitesting-mapkit-fixtures", "--reset-data",
            "--reset-preferences", "--seed-mileage-data", "--skip-onboarding",
            "--seed-vehicle-shortcut-receipt",
            "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
    }

    func testFrenchTrackingControlsAndPermissionsAtLargestTextSize() {
        // Stable identifiers avoid English navigation helpers in this locale.
        let settings = app.buttons[shell == .split ? "sidebarSettingsRow" : "settingsButton"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        settings.tap()
        let form = app.collectionViews["settingsForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 4))

        let controls = [
            app.buttons["settingsStartStopTrackingButton"],
            app.buttons["settingsPauseTodayButton"],
            app.buttons["settingsVacationPauseButton"]
        ]
        for control in controls {
            scrollUntilVisible(control)
            capture("French \(control.identifier) at largest text size")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThanOrEqual(control.frame.minX, form.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, form.frame.maxX)
        }
        for pair in zip(controls, controls.dropFirst()) {
            XCTAssertFalse(pair.0.frame.intersects(pair.1.frame))
        }
        let picker = app.segmentedControls["settingsAutomaticTripStartsPicker"]
        scrollUntilVisible(picker)
        capture("French tracking mode at largest text size")
        XCTAssertEqual(picker.buttons.count, 3)
        XCTAssertTrue(picker.buttons["Les deux"].isSelected)
        for option in picker.buttons.allElementsBoundByIndex {
            XCTAssertTrue(option.isHittable)
        }

        let setup = app.buttons["settingsShortcutSetupLink"]
        scrollUntilVisible(setup)
        capture("French Bluetooth receipt at largest text size")
        XCTAssertTrue(setup.label.contains("Configurer Bluetooth"))
        XCTAssertTrue(setup.label.contains("Raccourci reçu"))

        let permissions = app.buttons["settingsTrackingPermissionsLink"]
        scrollUntilVisible(permissions)
        permissions.tap()
        let permissionForm = app.collectionViews["settingsPermissionsForm"].firstMatch
        XCTAssertTrue(permissionForm.waitForExistence(timeout: 4))
        for identifier in ["Motion", "Location", "Bluetooth", "Notifications"] {
            let row = app.buttons["settings\(identifier)PermissionRow"]
            scrollUntilVisible(row)
            capture("French \(identifier) permission at largest text size")
            XCTAssertTrue(row.isHittable)
            XCTAssertGreaterThanOrEqual(row.frame.minX, permissionForm.frame.minX)
            XCTAssertLessThanOrEqual(row.frame.maxX, permissionForm.frame.maxX)
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
