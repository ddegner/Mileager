import XCTest

@MainActor
final class SettingsUITests: MileageTrackerUITestCase {
    func testSettingsMileageRatePersistsSelection() {
        waitForTripsScreen()
        openSettings()
        openCurrentMileageRateEditor()

        let rateField = app.textFields["settingsMileageRateField"].firstMatch
        scrollUntilVisible(rateField)
        replaceText(in: rateField, with: "0.800")
        XCTAssertEqual(rateField.value as? String, "0.800")

        // Rates now have a dedicated editor and an explicit save action.
        app.navigationBars["Mileage Rate"].buttons["Save"].tap()
        XCTAssertTrue(rateField.waitForNonExistence(timeout: 4))
        let currentRate = app.descendants(matching: .any)["settingsCustomCurrentRate"].firstMatch
        let rateText = ([currentRate.label, currentRate.value as? String ?? ""]
            + currentRate.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        XCTAssertTrue(rateText.contains("$0.80/mi"), app.debugDescription)
        popSubpage()
        app.buttons["settingsDone"].tap()
        relaunchWithExistingData()
        waitForTripsScreen()
        openSettings()
        openCurrentMileageRateEditor()
        let persistedRateField = app.textFields["settingsMileageRateField"].firstMatch
        scrollUntilVisible(persistedRateField)
        XCTAssertEqual(persistedRateField.value as? String, "0.8")
    }

    func testBusinessPurposeDraftPersistsWhenDoneTapped() {
        waitForTripsScreen()
        openSettings()
        openSubpage("settingsTripPurposesLink")

        let purposeField = app.textFields["settingsPurposeField"].firstMatch
        scrollUntilVisible(purposeField)
        replaceText(in: purposeField, with: "QA Visit")
        dismissKeyboardIfNeeded()
        XCTAssertEqual(purposeField.value as? String, "QA Visit")

        // Popping the subpage commits the edit.
        popSubpage()
        app.buttons["settingsDone"].tap()
        relaunchWithExistingData()
        waitForTripsScreen()
        openSettings()
        openSubpage("settingsTripPurposesLink")

        let persistedPurposeField = app.textFields["settingsPurposeField"].firstMatch
        scrollUntilVisible(persistedPurposeField)
        XCTAssertEqual(persistedPurposeField.value as? String, "QA Visit")
    }

    func testVehicleStartShortcutInstructionsPage() {
        waitForTripsScreen()
        openSettings()

        let link = app.buttons["settingsShortcutSetupLink"].firstMatch
        scrollIntoComfortableTapPosition(link)
        link.tap()
        scrollUntilExists(app.otherElements["settingsShortcutSetupContent"].firstMatch)
        scrollUntilExists(app.staticTexts["settingsShortcutSetupText"].firstMatch)
        scrollUntilVisible(app.buttons["settingsOpenShortcutsButton"].firstMatch)
    }

    func testCurrentDriveLockScreenSettingUsesPlainLanguage() {
        waitForTripsScreen()
        openSettings()

        let toggle = app.switches["settingsCurrentDriveLiveActivityToggle"].firstMatch
        scrollUntilVisible(toggle)
        XCTAssertTrue(toggle.label.contains("Show Current Drive on Lock Screen"))
    }

    // TEMPORARY: captures the redesigned "Automate trip starts" surfaces for review.
    func testCaptureAutomateTripStartsSection() {
        waitForTripsScreen()
        openSettings()

        // Main page: the drill-in row with its one-line footer.
        let link = app.buttons["settingsShortcutSetupLink"].firstMatch
        scrollIntoComfortableTapPosition(link)
        Thread.sleep(forTimeInterval: 0.6)
        captureScreenshot(named: "automate-collapsed")

        // Subpage: intro, Open Shortcuts, the Bluetooth setup steps + variation note.
        link.tap()
        scrollIntoComfortableTapPosition(app.buttons["settingsOpenShortcutsButton"].firstMatch)
        Thread.sleep(forTimeInterval: 0.6)
        captureScreenshot(named: "automate-expanded")
    }

    private func captureScreenshot(named name: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
    }

    func testPermissionRowsUseRequestedOrder() {
        waitForTripsScreen()
        openSettings()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        expandTrackingPermissions()
        XCTAssertFalse(app.staticTexts["Permissions for Automatic Tracking"].exists)
        let intro = app.staticTexts["settingsPermissionsIntroText"].firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Setup Needed"].exists)

        let rows = [
            app.buttons["settingsMotionPermissionRow"].firstMatch,
            app.buttons["settingsLocationPermissionRow"].firstMatch,
            app.buttons["settingsBluetoothPermissionRow"].firstMatch,
            app.buttons["settingsNotificationsPermissionRow"].firstMatch
        ]

        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 4))
        }
        XCTAssertFalse(app.buttons["settingsBackgroundRefreshPermissionRow"].firstMatch.exists)
        XCTAssertFalse(app.buttons["settingsPermissionsButton"].exists)
        XCTAssertFalse(app.buttons["Enable All Permissions"].exists)
        XCTAssertEqual(app.buttons["settingsBluetoothPermissionRow"].firstMatch.value as? String, "Not Determined")
        XCTAssertFalse(app.staticTexts["On"].exists)
        XCTAssertFalse(app.staticTexts["Off"].exists)

        for pair in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.minY, pair.1.frame.minY)
        }
    }

    func testPermissionRowsUseDeterministicStatesAndDeniedOpensSettingsPrompt() {
        relaunch(arguments: [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-mileage-data",
            "--skip-onboarding",
            "--permission-states=motion:authorized,location:partial,bluetooth:denied,notifications:restricted"
        ])
        waitForTripsScreen()
        openSettings()
        expandTrackingPermissions()

        let motion = app.buttons["settingsMotionPermissionRow"].firstMatch
        let location = app.buttons["settingsLocationPermissionRow"].firstMatch
        let bluetooth = app.buttons["settingsBluetoothPermissionRow"].firstMatch
        let notifications = app.buttons["settingsNotificationsPermissionRow"].firstMatch

        XCTAssertEqual(motion.value as? String, "Authorized")
        XCTAssertEqual(location.value as? String, "Partial")
        XCTAssertEqual(bluetooth.value as? String, "Denied")
        XCTAssertEqual(notifications.value as? String, "Restricted")

        bluetooth.tap()

        XCTAssertTrue(app.alerts["Bluetooth Access"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.alerts["Bluetooth Access"].buttons["Open Settings"].exists)
        app.alerts["Bluetooth Access"].buttons["Cancel"].tap()
    }

    func testAppLockToggleDisabledWithoutPasscode() {
        waitForTripsScreen()
        openSettings()

        // UI-testing runs use an authenticator that reports no passcode, so
        // the toggle must render disabled without extra footer copy.
        let lockToggle = app.switches["settingsAppLockToggle"].firstMatch
        scrollUntilVisible(lockToggle)
        XCTAssertFalse(lockToggle.isEnabled)
        XCTAssertFalse(app.staticTexts["App Lock needs a device passcode. Set one in the Settings app, then return here."].exists)
    }

    func testSettingsShowsAppVersionAndEstimateDisclaimerFooter() {
        waitForTripsScreen()
        openSettings()

        let appVersion = app.staticTexts["settingsAppVersion"].firstMatch
        scrollUntilExists(appVersion)
        XCTAssertTrue(appVersion.label.hasPrefix("Version "))

        let creatorLink = app.descendants(matching: .any)["settingsCreatorLink"].firstMatch
        scrollUntilExists(creatorLink)
        XCTAssertEqual(creatorLink.label, "Created by David Degner")

        let disclaimer = app.staticTexts["settingsEstimateDisclaimer"].firstMatch
        scrollUntilExists(disclaimer)
        XCTAssertEqual(
            disclaimer.label,
            "These are estimates for your own records, not tax advice."
        )
    }

    func testReportIssueButtonStartsShareFlow() {
        waitForTripsScreen()
        openSettings()

        let reportButton = app.buttons["settingsReportIssueButton"].firstMatch
        scrollUntilVisible(reportButton)
        XCTAssertEqual(reportButton.label, "Report Issue")
        XCTAssertTrue(reportButton.isEnabled)
        reportButton.tap()

        let consentSheet = app.collectionViews["settingsDiagnosticsConsentSheet"].firstMatch
        XCTAssertTrue(consentSheet.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["settingsDiagnosticsPrivacyWarning"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Last 7 days"].firstMatch.isSelected)

        app.buttons["Last 3 days"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Last 3 days"].firstMatch.isSelected)

        let prepareButton = app.buttons["settingsDiagnosticsPrepareButton"].firstMatch
        XCTAssertTrue(prepareButton.waitForExistence(timeout: 2))
        XCTAssertTrue(prepareButton.isEnabled)
        prepareButton.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 4))
        dismissShareSheetIfNeeded()
    }

    private func openSettings() {
        openSettingsFromTripsList()
    }

    private func openCurrentMileageRateEditor() {
        let link = app.buttons["settingsMileageRateLink"].firstMatch
        let form = app.collectionViews["settingsForm"].firstMatch
        // A full swipe can jump over this row in the shorter iPad sheet.
        // Move a small part of the viewport so the row remains reachable.
        for _ in 0..<10 {
            if link.exists, link.isHittable,
               link.frame.minY > form.frame.minY + 96,
               link.frame.maxY < form.frame.maxY - 80 { break }
            let movingUp = !link.exists || link.frame.midY >= form.frame.midY
            let startY = movingUp ? 0.7 : 0.4
            let endY = movingUp ? 0.4 : 0.7
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
                ))
        }
        XCTAssertTrue(link.isHittable, app.debugDescription)
        link.tap()
        let editRate = app.buttons["settingsEditMileageRate"].firstMatch
        let customSource = app.buttons["settingsCustomMileageRateSource"].firstMatch
        XCTAssertTrue(customSource.waitForExistence(timeout: 8), app.debugDescription)
        if editRate.exists {
            editRate.tap()
        } else {
            customSource.tap()
        }
        XCTAssertTrue(app.textFields["settingsMileageRateField"].waitForExistence(timeout: 8), app.debugDescription)
    }

    private func openSubpage(_ identifier: String) {
        let link = app.buttons[identifier].firstMatch
        scrollIntoComfortableTapPosition(link)
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
    }

    private func popSubpage() {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        back.tap()
        XCTAssertTrue(app.buttons["settingsDone"].waitForExistence(timeout: 4))
    }

    private func expandTrackingPermissions() {
        let link = app.buttons["settingsTrackingPermissionsLink"].firstMatch
        scrollIntoComfortableTapPosition(link)
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
    }

    private func relaunchWithExistingData() {
        relaunch(arguments: ["--uitesting", "--seed-mileage-data", "--skip-onboarding"])
    }

    private func dismissShareSheetIfNeeded() {
        let closeButton = app.buttons["Close"].firstMatch
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.tap()
            return
        }

        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 1) {
            cancelButton.tap()
            return
        }

        if app.sheets.firstMatch.exists {
            app.swipeDown()
        }
    }
}
