import XCTest

/// Exercises source selection, custom drafts, and rate history with deterministic IRS evidence.
@MainActor
final class IRSRateSettingsUITests: MileageTrackerUITestCase {
    override var requiresExpandedSplitShell: Bool { true }

    override var launchArguments: [String] {
        super.launchArguments + ["--irs-rate-fixture=setup"]
    }

    func testCustomEditorSavesCurrencyUnitAndAmountTogether() {
        openRateSettings()
        let customSource = app.buttons["settingsCustomMileageRateSource"].firstMatch
        let irsSource = app.buttons["settingsIRSMileageRateSource"].firstMatch
        XCTAssertTrue(customSource.waitForExistence(timeout: 4), app.debugDescription)
        assertRateSource(isIRS: false)
        XCTAssertLessThan(irsSource.frame.minY, customSource.frame.minY)
        assertRow("settingsCustomCurrentRate", contains: "$0.725/mi")
        XCTAssertFalse(app.buttons["settingsCheckIRSRateNow"].exists)
        XCTAssertFalse(app.buttons["settingsBaseMileageRate"].exists, "History starts collapsed")

        app.buttons["settingsEditMileageRate"].firstMatch.tap()
        let currency = app.buttons["settingsMileageRateCurrency"].firstMatch
        XCTAssertTrue(currency.waitForExistence(timeout: 4), app.debugDescription)
        currency.tap()
        let euro = app.buttons["currencyOption-EUR"].firstMatch
        scrollUntilVisible(euro)
        euro.tap()
        XCTAssertTrue(app.navigationBars["Mileage Rate"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.alerts["Change Currency?"].exists, "Currency remains a draft until Save")
        let unit = app.buttons["settingsMileageRateUnitPicker"].firstMatch
        scrollIntoComfortableTapPosition(unit)
        unit.tap()
        app.buttons["Kilometer"].firstMatch.tap()
        replaceRateText(in: app.textFields["settingsMileageRateField"].firstMatch, with: "0.800")
        attachScreen(named: "Native custom rate editor with euros and kilometers")
        saveEditor()
        XCTAssertFalse(app.buttons["settingsIRSMileageRateSource"].exists)
        XCTAssertFalse(app.buttons["settingsCustomMileageRateSource"].exists)
        assertRow("settingsCustomCurrentRate", contains: "€0.80/km")
        attachScreen(named: "Custom euro rate saved with kilometers")

        returnToSettings()
        XCTAssertFalse(app.buttons["settingsCurrencyPicker"].exists)
        app.buttons["settingsDone"].tap()
        relaunchKeepingRates()
        openRateSettings()
        assertRow("settingsCustomCurrentRate", contains: "€0.80/km")
        app.buttons["settingsEditMileageRate"].firstMatch.tap()
        let persistedRateField = app.textFields["settingsMileageRateField"].firstMatch
        XCTAssertTrue(persistedRateField.waitForExistence(timeout: 4))
        XCTAssertEqual(persistedRateField.value as? String, "0.8")
    }

    func testCustomHistoryCanBeEditedWithoutChangingSource() {
        openRateSettings()
        expandHistory()
        let initialRate = app.buttons["settingsBaseMileageRate"].firstMatch
        XCTAssertTrue(initialRate.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(initialRate.label.contains("May 23, 2026"), initialRate.label)
        XCTAssertFalse(initialRate.label.contains("Base Rate"))
        initialRate.tap()
        replaceRateText(in: app.textFields["settingsMileageRateField"].firstMatch, with: "0.800")
        saveEditor()
        assertRateSource(isIRS: false)
        assertRow("settingsCustomCurrentRate", contains: "$0.80/mi")
        assertRow("settingsBaseMileageRate", contains: "$0.80/mi")
        XCTAssertTrue(app.buttons["settingsBaseMileageRate"].exists)
    }

    func testChoosingIRSVerifiesAndShowsCollapsedReadOnlyHistory() {
        openRateSettings()
        assertRateSource(isIRS: false)
        app.buttons["settingsIRSMileageRateSource"].firstMatch.tap()
        XCTAssertTrue(element("settingsIRSCurrentRate").waitForExistence(timeout: 8), app.debugDescription)
        assertRateSource(isIRS: true)
        assertRow("settingsIRSCurrentRate", contains: "$0.76/mi")
        XCTAssertTrue(element("settingsMileageRateHistory").exists)
        XCTAssertTrue(element("settingsIRSUpdateDetails").exists)
        XCTAssertFalse(element("settingsMileageRateRule-2026-1-1").exists)
        XCTAssertFalse(element("settingsIRSLastChecked").exists)
        XCTAssertFalse(element("settingsIRSUpcomingRate").exists, "Future rates live in history")
        XCTAssertFalse(app.buttons["settingsEditMileageRate"].exists)
        XCTAssertFalse(app.buttons["settingsAddMileageRate"].exists)
        XCTAssertFalse(app.buttons["settingsUseIRSRate"].exists)
        attachScreen(named: "Automatic IRS rate with native collapsed details")

        expandHistory()
        XCTAssertFalse(element("settingsBaseMileageRate").exists, "IRS history covers the first trip")
        for (date, amount) in [("2026-1-1", "$0.725/mi"), ("2026-7-1", "$0.76/mi"), ("2027-1-1", "$0.78/mi")] {
            let identifier = "settingsMileageRateRule-\(date)"
            assertRow(identifier, contains: amount)
            XCTAssertFalse(app.buttons[identifier].exists, "Automatic history must be read-only")
        }
        XCTAssertFalse(app.buttons["settingsAddMileageRate"].exists)
        attachScreen(named: "Read-only automatic rate history")
        expandUpdateDetails()
        assertInlineRefresh()
        XCTAssertTrue(element("settingsIRSRateSourceLink").exists)
        checkRatesNow()
        XCTAssertFalse(element("settingsIRSRateStatus").exists)
    }

    func testFailedInitialIRSSelectionKeepsCustomRatesAndCanBeRetriedOrCancelled() {
        launchFixture("failureSetup")
        openRateSettings()
        app.buttons["settingsIRSMileageRateSource"].firstMatch.tap()
        assertRow("settingsIRSRateStatus", contains: "could not be verified")
        XCTAssertFalse(element("settingsIRSLastChecked").exists, "Failure stays visible outside collapsed update details")
        assertRateSource(isIRS: false)
        assertRow("settingsCustomCurrentRate", contains: "$0.725/mi")
        XCTAssertFalse(element("settingsIRSCurrentRate").exists)
        expandUpdateDetails()
        assertRow("settingsIRSLastChecked", contains: "Not Yet Checked")
        assertInlineRefresh()
        checkRatesNow()
        assertRow("settingsIRSRateStatus", contains: "could not be verified")
        assertRateSource(isIRS: false)
        app.buttons["settingsCustomMileageRateSource"].firstMatch.tap()
        cancelEditor()
        XCTAssertFalse(element("settingsIRSRateStatus").exists)
        XCTAssertFalse(app.buttons["settingsCheckIRSRateNow"].exists)
        assertRateSource(isIRS: false)
        assertRow("settingsCustomCurrentRate", contains: "$0.725/mi")
        attachScreen(named: "Failed IRS selection keeps the custom rate")
    }

    func testCustomSelectionCancelsPendingIRSVerificationWithoutApplyingRates() {
        launchFixture("delayedSetup")
        openRateSettings()
        let irsSource = app.buttons["settingsIRSMileageRateSource"].firstMatch
        irsSource.tap()
        let checking = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: irsSource)
        wait(for: [checking], timeout: 3)
        app.buttons["settingsCustomMileageRateSource"].firstMatch.tap()
        cancelEditor()
        let adopted = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: irsSource)
        adopted.isInverted = true
        wait(for: [adopted], timeout: 6)
        assertRateSource(isIRS: false)
        XCTAssertFalse(element("settingsIRSCurrentRate").exists)
        XCTAssertFalse(app.buttons["settingsCheckIRSRateNow"].exists)
        assertRow("settingsCustomCurrentRate", contains: "$0.725/mi")
    }

    func testIRSChoiceFinishesAfterLeavingSettings() {
        launchFixture("delayedSetup")
        openRateSettings()
        let irsSource = app.buttons["settingsIRSMileageRateSource"].firstMatch
        irsSource.tap()
        let checking = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: irsSource)
        wait(for: [checking], timeout: 3)
        returnToSettings()
        app.buttons["settingsDone"].tap()
        openRateSettings()
        let following = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: irsSource)
        wait(for: [following], timeout: 8)
        assertRateSource(isIRS: true)
        assertRow("settingsIRSCurrentRate", contains: "$0.76/mi")
        expandHistory()
        assertRow("settingsMileageRateRule-2026-1-1", contains: "$0.725/mi")
    }

    func testKilometerDisplayPreservesIRSAmountsAndFollowingAfterRelaunch() {
        launchFixture("following")
        waitForTripsScreen()
        openSettingsFromTripsList()
        let distancePicker = app.buttons["settingsDistanceUnitPicker"].firstMatch
        scrollIntoComfortableTapPosition(distancePicker)
        distancePicker.tap()
        let kilometers = app.buttons["Kilometers"].firstMatch
        XCTAssertTrue(kilometers.waitForExistence(timeout: 4), app.debugDescription)
        kilometers.tap()
        openMileageRates()
        assertRateSource(isIRS: true)
        assertRow("settingsIRSCurrentRate", contains: "$0.472/km")
        checkRatesNow()
        assertRow("settingsIRSCurrentRate", contains: "$0.472/km")
        returnToSettings()
        app.buttons["settingsDone"].tap()
        relaunchKeepingRates()
        openRateSettings()
        assertRateSource(isIRS: true)
        assertRow("settingsIRSCurrentRate", contains: "$0.472/km")
        expandHistory()
        assertRow("settingsMileageRateRule-2027-1-1", contains: "$0.485/km")
        attachScreen(named: "Automatic IRS rates persist in kilometers")
    }

    func testConflictingCustomRatesRequireReviewAndCanBeReplaced() {
        launchFixture("conflict")
        openRateSettings()
        checkRatesNow()
        let replace = app.buttons["settingsReplaceCustomRatesWithIRS"].firstMatch
        scrollUntilVisible(replace)
        XCTAssertTrue(replace.waitForExistence(timeout: 8), app.debugDescription)
        assertRow("settingsIRSConflictPeriod-2026-7-1", contains: "$0.76/mi")
        assertRateSource(isIRS: true)
        expandHistory()
        assertRow("settingsMileageRateRule-2026-8-1", contains: "$0.90/mi")
        scrollUntilVisible(replace, direction: .down)
        replace.tap()
        XCTAssertTrue(replace.waitForNonExistence(timeout: 4))
        assertRateSource(isIRS: true)
        assertRow("settingsIRSCurrentRate", contains: "$0.76/mi")
        assertRow("settingsMileageRateRule-2027-1-1", contains: "$0.78/mi")
        scrollUntilVisible(element("settingsMileageRateRule-2026-7-1"))
        XCTAssertFalse(element("settingsMileageRateRule-2026-8-1").exists)
    }

    func testConflictingCustomRatesCanBeKeptWithoutChangingHistory() {
        launchFixture("conflict")
        openRateSettings()
        checkRatesNow()
        let keep = app.buttons["settingsKeepCustomMileageRates"].firstMatch
        scrollUntilVisible(keep)
        XCTAssertTrue(keep.waitForExistence(timeout: 8), app.debugDescription)
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 4))
        assertRateSource(isIRS: false)
        assertRow("settingsCustomCurrentRate", contains: "$0.90/mi")
        expandHistory()
        assertRow("settingsMileageRateRule-2026-8-1", contains: "$0.90/mi")
        assertRow("settingsMileageRateRule-2026-7-1", contains: "$0.76/mi")
        XCTAssertTrue(app.buttons["settingsMileageRateRule-2026-7-1"].exists)
        XCTAssertFalse(element("settingsBaseMileageRate").exists)
        XCTAssertFalse(element("settingsIRSRateStatus").exists)
    }

    func testCancellingCustomDraftPreservesAutomaticRateAndScheduledHistory() {
        launchFixture("following")
        openRateSettings()
        app.buttons["settingsCustomMileageRateSource"].firstMatch.tap()
        XCTAssertTrue(app.textFields["settingsMileageRateField"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.alerts["Switch to Custom Rate?"].exists)
        app.buttons["settingsMileageRateCurrency"].firstMatch.tap()
        let euro = app.buttons["currencyOption-EUR"].firstMatch
        scrollUntilVisible(euro)
        euro.tap()
        replaceRateText(in: app.textFields["settingsMileageRateField"].firstMatch, with: "0.810")
        cancelEditor()
        assertRateSource(isIRS: true)
        assertRow("settingsIRSCurrentRate", contains: "$0.76/mi")
        expandHistory()
        assertRow("settingsMileageRateRule-2026-7-1", contains: "$0.76/mi")
        assertRow("settingsMileageRateRule-2027-1-1", contains: "$0.78/mi")
        attachScreen(named: "Cancelled custom currency draft preserves automatic USD rate")
    }

    func testSavingCustomRatePreservesPastHistoryAndRemovesFutureIRSRate() {
        launchFixture("following")
        openRateSettings()
        app.buttons["settingsCustomMileageRateSource"].firstMatch.tap()
        let field = app.textFields["settingsMileageRateField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        XCTAssertFalse(app.alerts["Switch to Custom Rate?"].exists)
        XCTAssertTrue(element("settingsMileageRateEffectiveDate").exists)
        replaceRateText(in: field, with: "0.810")
        saveEditor()
        assertRateSource(isIRS: false)
        assertRow("settingsCustomCurrentRate", contains: "$0.81/mi")
        XCTAssertTrue(app.buttons["settingsEditMileageRate"].exists)
        XCTAssertFalse(element("settingsIRSUpdateDetails").exists)
        expandHistory()
        assertRow("settingsMileageRateRule-2026-1-1", contains: "$0.725/mi")
        assertRow("settingsMileageRateRule-2026-7-1", contains: "$0.76/mi")
        assertRow("settingsMileageRateRule-2026-10-3", contains: "$0.81/mi")
        XCTAssertFalse(element("settingsMileageRateRule-2027-1-1").exists)
        XCTAssertTrue(app.buttons["settingsAddMileageRate"].exists)
        attachScreen(named: "Custom rate replaces future IRS updates and preserves past history")

        returnToSettings()
        app.buttons["settingsDone"].tap()
        relaunchKeepingRates()
        openRateSettings()
        assertRateSource(isIRS: false)
        assertRow("settingsCustomCurrentRate", contains: "$0.81/mi")
        expandHistory()
        assertRow("settingsMileageRateRule-2026-10-3", contains: "$0.81/mi")
        XCTAssertFalse(element("settingsMileageRateRule-2027-1-1").exists)
    }

    func testFailedRateCheckShowsStatusAndRetainsCurrentAndFutureRates() {
        launchFixture("failure")
        openRateSettings()
        checkRatesNow()
        assertRow("settingsIRSRateStatus", contains: "could not be verified")
        assertRow("settingsIRSCurrentRate", contains: "$0.76/mi")
        assertRateSource(isIRS: true)
        assertRow("settingsIRSLastChecked", contains: "Not Yet Checked")
        assertInlineRefresh()
        expandHistory()
        assertRow("settingsMileageRateRule-2027-1-1", contains: "$0.78/mi")
    }

    private func launchFixture(_ scenario: String) {
        relaunch(arguments: [
            "--uitesting", "--uitesting-mapkit-fixtures", "--reset-data", "--reset-preferences",
            "--seed-mileage-data", "--skip-onboarding", "--irs-rate-fixture=\(scenario)"
        ])
    }

    private func relaunchKeepingRates() {
        relaunch(arguments: [
            "--uitesting", "--uitesting-mapkit-fixtures", "--seed-mileage-data", "--skip-onboarding",
            "--irs-rate-fixture=following"
        ])
    }

    private func openRateSettings() {
        waitForTripsScreen()
        openSettingsFromTripsList()
        openMileageRates()
    }

    private func expandHistory() {
        let history = element("settingsMileageRateHistory")
        scrollUntilVisible(history)
        history.tap()
    }

    private func expandUpdateDetails() {
        let details = element("settingsIRSUpdateDetails")
        scrollUntilVisible(details, direction: .down)
        if !app.buttons["settingsCheckIRSRateNow"].exists {
            details.tap()
        }
        XCTAssertTrue(app.buttons["settingsCheckIRSRateNow"].waitForExistence(timeout: 4), app.debugDescription)
    }

    private func checkRatesNow() {
        expandUpdateDetails()
        let check = app.buttons["settingsCheckIRSRateNow"].firstMatch
        scrollIntoComfortableTapPosition(check)
        check.tap()
        // Conflict review inserts rows above Update Details. Its refresh
        // button can leave Form's visible accessibility tree after completion;
        // each caller verifies the resulting rate, status, or conflict controls.
        let ready = NSPredicate { _, _ in !check.exists || check.isEnabled }
        expectation(for: ready, evaluatedWith: check)
        waitForExpectations(timeout: 8)
    }

    private func saveEditor() {
        let field = app.textFields["settingsMileageRateField"].firstMatch
        let save = app.navigationBars["Mileage Rate"].buttons["Save"].firstMatch
        XCTAssertTrue(save.isEnabled, app.debugDescription)
        save.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 4), app.debugDescription)
    }

    private func cancelEditor() {
        let field = app.textFields["settingsMileageRateField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4), app.debugDescription)
        app.navigationBars["Mileage Rate"].buttons["Cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 4), app.debugDescription)
    }

    private func assertInlineRefresh(file: StaticString = #filePath, line: UInt = #line) {
        let lastChecked = element("settingsIRSLastChecked")
        scrollUntilVisible(lastChecked)
        let refresh = lastChecked.buttons["settingsCheckIRSRateNow"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 4), app.debugDescription, file: file, line: line)
        XCTAssertEqual(refresh.label, "Check Now", file: file, line: line)
    }

    private func assertRateSource(isIRS: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = isIRS ? "settingsIRSMileageRateSource" : "settingsCustomMileageRateSource"
        let source = app.buttons[identifier].firstMatch
        // Form only exposes visible rows in its accessibility tree.
        scrollUntilVisible(source, direction: .down)
        XCTAssertTrue(source.isSelected, "Expected selected source: \(identifier)", file: file, line: line)
    }

    private func replaceRateText(in field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        scrollUntilVisible(field)
        field.press(forDuration: 1)
        let selectAll = app.buttons["Select All"].firstMatch
        let selectAllMenuItem = app.menuItems["Select All"].firstMatch
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        } else if selectAllMenuItem.exists {
            selectAllMenuItem.tap()
        } else {
            field.doubleTap()
        }
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value, app.debugDescription)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func assertRow(
        _ identifier: String, contains expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let row = element(identifier)
        scrollUntilVisible(row)
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription, file: file, line: line)
        let text = ([row.label, row.value as? String ?? ""] + row.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " ")
        XCTAssertTrue(text.contains(expected), "Expected \(expected) in \(identifier): \(text)", file: file, line: line)
    }

    private func attachScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMileageRates() {
        let link = app.buttons["settingsMileageRateLink"].firstMatch
        let form = app.collectionViews["settingsForm"].firstMatch
        // Small drags avoid skipping the row in the compact Settings sheet.
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
        XCTAssertTrue(app.navigationBars["Mileage Rates"].waitForExistence(timeout: 8), app.debugDescription)
    }

    private func returnToSettings() {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 4), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.buttons["settingsDone"].waitForExistence(timeout: 4))
    }
}
