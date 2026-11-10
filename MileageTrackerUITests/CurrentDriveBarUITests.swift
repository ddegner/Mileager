import XCTest

@MainActor
final class CurrentDriveBarUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        super.launchArguments + ["--seed-current-drive"]
    }

    func testRecordingBarVisibleAlongsideBottomToolbar() {
        waitForTripsScreen()

        // The Toll/Parking quick actions prove the one-line glass bar rendered.
        XCTAssertTrue(app.buttons["currentDriveBarToll"].waitForExistence(timeout: 8), "Glass bar should be visible while recording")
        XCTAssertTrue(app.buttons["currentDriveBarParking"].exists)

        // The bottom toolbar (Add Trip / Reports / Settings) stays available
        // while a drive records; the glass bar stacks above it.
        XCTAssertTrue(app.buttons["addTripButton"].exists, "Add Trip should stay visible while a drive is recording")
        XCTAssertTrue(app.buttons["settingsButton"].exists, "Settings should stay visible while a drive is recording")
    }

    func testExactlyOneRecordingBarExistsOnRootAndPushedList() {
        waitForTripsScreen()
        let bars = app.descendants(matching: .any).matching(identifier: "currentDriveBar")
        XCTAssertEqual(bars.count, 1, "The Mailboxes root should host one recording bar")

        openAllTrips()
        assertScopeIsOpen("All Trips")
        XCTAssertEqual(
            bars.count,
            1,
            "Pushing a drive list must replace the root bar rather than stacking a second presenter"
        )
    }

    func testMinimizingShowsOneVehicleButtonAtBottomLeftAndRestoresControls() throws {
        waitForTripsScreen()
        try XCTSkipUnless(shell == .stack, "Bottom-left toolbar placement belongs to the phone navigation stack")

        let minimize = app.buttons["currentDriveBarMinimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 8))
        let currentVehicleName = try XCTUnwrap(app.buttons["currentDriveBarVehicle"].value as? String)
        minimize.tap()

        let expandButtons = app.buttons.matching(identifier: "currentDriveBarExpand")
        let expand = expandButtons.firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 4))
        XCTAssertEqual(expandButtons.count, 1, "A minimized recording should have one vehicle control")
        XCTAssertTrue(expand.isEnabled)
        XCTAssertTrue(
            (expand.value as? String)?.hasPrefix(currentVehicleName + ", ") == true,
            "The compact control should identify the same current vehicle as the expanded panel"
        )
        XCTAssertTrue(waitForDisappearance(of: minimize))
        XCTAssertFalse(app.buttons["currentDriveBarToll"].exists)
        XCTAssertFalse(app.buttons["currentDriveBarParking"].exists)
        XCTAssertFalse(app.buttons["currentDriveBarClassificationbusiness"].exists)

        let addTrip = app.buttons["addTripButton"]
        XCTAssertTrue(addTrip.isEnabled, "Minimizing must preserve the existing toolbar actions")
        XCTAssertLessThan(expand.frame.midX, app.frame.midX, "The vehicle control belongs on the left")
        XCTAssertLessThan(expand.frame.maxX, addTrip.frame.minX)
        XCTAssertEqual(expand.frame.midY, addTrip.frame.midY, accuracy: 8, "The vehicle control belongs in the bottom toolbar")
        let compactScreenshot = XCTAttachment(screenshot: app.screenshot())
        compactScreenshot.name = "Current drive minimized into bottom toolbar"
        compactScreenshot.lifetime = .keepAlways
        add(compactScreenshot)

        tapOnscreenToolbarControl(addTrip)
        XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 4))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 4))
        XCTAssertFalse(minimize.exists, "Canceling manual entry must preserve the minimized controls")

        tapOnscreenToolbarControl(expand)
        XCTAssertTrue(minimize.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["currentDriveBarToll"].isHittable)
        XCTAssertTrue(app.buttons["currentDriveBarParking"].isHittable)
        XCTAssertTrue(waitForDisappearance(of: expand))
        let expandedScreenshot = XCTAttachment(screenshot: app.screenshot())
        expandedScreenshot.name = "Current drive expanded glass controls"
        expandedScreenshot.lifetime = .keepAlways
        add(expandedScreenshot)
    }

    func testMinimizedDrivePersistsAcrossNavigationWithoutChangingClassification() throws {
        waitForTripsScreen()
        try XCTSkipUnless(shell == .stack, "This regression exercises pushing and popping the phone navigation stack")

        let currentDriveBar = app.descendants(matching: .any)
            .matching(identifier: "currentDriveBar").firstMatch
        XCTAssertTrue(currentDriveBar.waitForExistence(timeout: 8))
        let pendingTripID = try XCTUnwrap(currentDriveBar.value as? String)
        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        business.tap()
        XCTAssertTrue(app.navigationBars["Business Drive"].waitForExistence(timeout: 4))
        app.buttons["currentDriveDetailsConfirm"].tap()
        XCTAssertTrue(waitForSelected(business))
        app.buttons["currentDriveBarMinimize"].tap()

        let expand = app.buttons["currentDriveBarExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 4))
        openAllTrips()
        XCTAssertTrue(expand.waitForExistence(timeout: 4), "Pushing a list should preserve the minimized state")
        XCTAssertTrue(expand.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "currentDriveBarExpand").count, 1)
        XCTAssertFalse(app.buttons["currentDriveBarMinimize"].exists)

        tapBack(from: "All Trips")
        assertMailboxRootIsShowing()
        XCTAssertTrue(expand.waitForExistence(timeout: 4), "Returning to the root should preserve the minimized state")
        XCTAssertFalse(app.buttons["currentDriveBarMinimize"].exists)
        expand.tap()
        XCTAssertTrue(business.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForSelected(business), "Minimizing and navigating must preserve classification")
        XCTAssertEqual(currentDriveBar.value as? String, pendingTripID, "The same drive must still be recording")
    }

    func testLiveActivityCurrentDriveLinkExpandsMinimizedControls() throws {
        waitForTripsScreen()

        let currentDriveBar = app.descendants(matching: .any)
            .matching(identifier: "currentDriveBar").firstMatch
        XCTAssertTrue(currentDriveBar.waitForExistence(timeout: 8))
        let pendingTripID = try XCTUnwrap(currentDriveBar.value as? String)
        let currentDriveURL = try XCTUnwrap(URL(string: "mileager://drive/\(pendingTripID)"))
        app.buttons["currentDriveBarMinimize"].tap()
        let expand = app.buttons["currentDriveBarExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 4))

        // Use the already-running process so the minimized presentation is
        // still in place when the same URL as the Live Activity arrives.
        XCUIDevice.shared.system.open(currentDriveURL)

        XCTAssertTrue(app.buttons["currentDriveBarMinimize"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["currentDriveBarToll"].isHittable)
        XCTAssertTrue(waitForDisappearance(of: expand))
        XCTAssertEqual(currentDriveBar.value as? String, pendingTripID)
    }

    func testStaleLiveActivityCurrentDriveLinkKeepsControlsMinimized() throws {
        waitForTripsScreen()
        let currentDriveBar = app.descendants(matching: .any)
            .matching(identifier: "currentDriveBar").firstMatch
        XCTAssertTrue(currentDriveBar.waitForExistence(timeout: 8))
        let pendingTripID = try XCTUnwrap(currentDriveBar.value as? String)
        let staleTripID = UUID().uuidString
        XCTAssertNotEqual(staleTripID, pendingTripID)
        let staleDriveURL = try XCTUnwrap(URL(string: "mileager://drive/\(staleTripID)"))
        app.buttons["currentDriveBarMinimize"].tap()
        let expand = app.buttons["currentDriveBarExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 4))

        XCUIDevice.shared.system.open(staleDriveURL)

        XCTAssertFalse(
            app.buttons["currentDriveBarMinimize"].waitForExistence(timeout: 1),
            "A link for a different drive must not expand this drive's controls"
        )
        tapOnscreenToolbarControl(expand)
        XCTAssertTrue(currentDriveBar.waitForExistence(timeout: 4))
        XCTAssertEqual(currentDriveBar.value as? String, pendingTripID)
    }

    private func tapOnscreenToolbarControl(_ button: XCUIElement) {
        XCTAssertTrue(button.isEnabled)
        let frame = button.frame
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(app.frame.contains(frame), "The toolbar button must remain fully onscreen")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Bottom toolbar interaction state"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Bottom toolbar accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if button.isHittable {
            button.tap()
        } else {
            // iOS 27 can report infinite glass-toolbar ancestor frames even
            // when this button has correct onscreen bounds. Deliver a real
            // touch at those bounds; the caller must verify its actual action.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func testLiveActivityCurrentDriveLinkWaitsForPurposeEditorDismissal() throws {
        waitForTripsScreen()
        try XCTSkipUnless(shell == .stack, "This regression observes the phone stack return to its root")
        openAllTrips()

        let currentDriveBar = app.descendants(matching: .any)
            .matching(identifier: "currentDriveBar").firstMatch
        XCTAssertTrue(currentDriveBar.waitForExistence(timeout: 8))
        let pendingTripID = try XCTUnwrap(currentDriveBar.value as? String)
        let currentDriveURL = try XCTUnwrap(URL(string: "mileager://drive/\(pendingTripID)"))
        app.buttons["currentDriveBarClassificationbusiness"].firstMatch.tap()
        let purposeEditor = app.navigationBars["Business Drive"]
        XCTAssertTrue(purposeEditor.waitForExistence(timeout: 4))

        XCUIDevice.shared.system.open(currentDriveURL)

        XCTAssertTrue(purposeEditor.exists, "The request must not tear down an in-progress purpose editor")
        XCTAssertTrue(app.buttons["currentDriveDetailsConfirm"].isHittable)
        app.buttons["currentDriveDetailsConfirm"].tap()
        XCTAssertTrue(waitForDisappearance(of: purposeEditor))
        assertMailboxRootIsShowing()
        assertNoScopeIsOpen("All Trips")
        XCTAssertTrue(app.buttons["currentDriveBarMinimize"].isHittable)
        XCTAssertEqual(currentDriveBar.value as? String, pendingTripID)
        XCTAssertTrue(waitForSelected(app.buttons["currentDriveBarClassificationbusiness"].firstMatch))
    }

    func testSelectionTemporarilyHidesMinimizedVehicleButton() {
        waitForTripsScreen()
        XCTAssertTrue(app.buttons["currentDriveBarMinimize"].waitForExistence(timeout: 8))
        app.buttons["currentDriveBarMinimize"].tap()
        let expand = app.buttons["currentDriveBarExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 4))
        openAllTrips()
        XCTAssertTrue(expand.waitForExistence(timeout: 4))

        app.buttons["listOptionsMenu"].tap()
        let select = app.buttons["selectTripsButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 4))
        select.tap()
        let done = app.buttons["selectionDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForDisappearance(of: expand), "Recording controls must leave room for selection actions")
        XCTAssertFalse(app.buttons["currentDriveBarMinimize"].exists)

        done.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 4), "Leaving selection should restore the compact vehicle control")
        XCTAssertTrue(expand.isHittable)
        XCTAssertFalse(app.buttons["currentDriveBarMinimize"].exists, "Selection must preserve the chosen minimized state")
    }

    func testClassificationToggleSelectsBusiness() {
        waitForTripsScreen()

        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        XCTAssertTrue(business.waitForExistence(timeout: 8))
        XCTAssertFalse(business.isSelected, "Seeded drive starts unclassified")

        business.tap()
        XCTAssertTrue(
            waitForSelected(business),
            "Tapping Business should select it on the bar"
        )
    }

    func testTappingBusinessOpensPurposeNoteSheet() {
        waitForTripsScreen()

        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        XCTAssertTrue(business.waitForExistence(timeout: 8))
        business.tap()

        // The purpose/note sheet should slide up over the bar (the popover that
        // previously rendered behind the glass bar is gone).
        XCTAssertTrue(
            app.navigationBars["Business Drive"].waitForExistence(timeout: 4),
            "Tapping Business should open the purpose/note sheet"
        )
        XCTAssertTrue(
            app.buttons["currentDriveBarAddNote"].waitForExistence(timeout: 2),
            "Add Note button should be visible in the sheet"
        )

        // Revealing the note field should let the user type a note.
        app.buttons["currentDriveBarAddNote"].tap()
        XCTAssertTrue(
            app.textFields["currentDriveNoteField"].waitForExistence(timeout: 2),
            "Add Note should reveal the note field"
        )
    }

    func testLiveActivityFeeRequestWaitsForPurposeEditorDismissal() throws {
        waitForTripsScreen()

        let currentDriveBar = app.descendants(matching: .any)
            .matching(identifier: "currentDriveBar")
            .firstMatch
        XCTAssertTrue(currentDriveBar.waitForExistence(timeout: 8))
        let pendingTripID = try XCTUnwrap(
            currentDriveBar.value as? String,
            "The UI-test current-drive bar should expose its pending trip ID"
        )
        let feeURL = try XCTUnwrap(
            URL(string: "mileager://drive/\(pendingTripID)/fee/toll")
        )

        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        business.tap()
        let purposeEditor = app.navigationBars["Business Drive"]
        XCTAssertTrue(purposeEditor.waitForExistence(timeout: 4))

        // Opening through the device routes the URL into the already-running
        // process. `XCUIApplication.open` performs a fresh launch, which would
        // destroy the very sheet-over-sheet state this regression exercises.
        XCUIDevice.shared.system.open(feeURL)

        XCTAssertTrue(
            purposeEditor.exists,
            "A Live Activity request must not replace the purpose editor"
        )
        XCTAssertFalse(
            app.navigationBars["Add Fee"].waitForExistence(timeout: 1),
            "The fee sheet must remain queued while the purpose editor is visible"
        )

        app.buttons["currentDriveDetailsConfirm"].tap()
        XCTAssertTrue(
            app.navigationBars["Add Fee"].waitForExistence(timeout: 4),
            "Dismissing the purpose editor should replay the queued fee request"
        )
        XCTAssertTrue(
            app.segmentedControls.buttons["Toll"].firstMatch.isSelected,
            "The replayed request should preserve its requested category"
        )
    }

    /// Regression guard for the noteEdited dirty flag: a typed note must still
    /// save on Done and survive reopening — the guard may only suppress the
    /// no-edit write, never a real one.
    func testTypedNoteSavesOnConfirmAndSurvivesReopen() {
        waitForTripsScreen()

        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        XCTAssertTrue(business.waitForExistence(timeout: 8))
        business.tap()
        XCTAssertTrue(app.navigationBars["Business Drive"].waitForExistence(timeout: 4))

        app.buttons["currentDriveBarAddNote"].tap()
        let noteField = app.textFields["currentDriveNoteField"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 2))
        noteField.tap()
        noteField.typeText("Met client at 22 Example St")
        app.buttons["currentDriveDetailsConfirm"].tap()

        // Reopen: the note field shows immediately (non-empty note) with the text.
        business.tap()
        XCTAssertTrue(app.navigationBars["Business Drive"].waitForExistence(timeout: 4))
        XCTAssertTrue(noteField.waitForExistence(timeout: 2), "Saved note should reveal the field on reopen")
        XCTAssertEqual(noteField.value as? String, "Met client at 22 Example St")
        app.buttons["currentDriveDetailsConfirm"].tap()
    }

    /// The swipe-away path must save edits too (the .onDisappear branch).
    func testTypedNoteSavesOnSwipeDismiss() {
        waitForTripsScreen()

        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        XCTAssertTrue(business.waitForExistence(timeout: 8))
        business.tap()
        let sheetBar = app.navigationBars["Business Drive"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 4))

        app.buttons["currentDriveBarAddNote"].tap()
        let noteField = app.textFields["currentDriveNoteField"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 2))
        noteField.tap()
        noteField.typeText("Swiped away")

        // Drag the sheet from its header to the bottom edge instead of
        // confirming (a plain swipeDown only hops detents with the keyboard up).
        let dragStart = sheetBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertTrue(waitForDisappearance(of: sheetBar), "Dragging down should dismiss the sheet")

        business.tap()
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 4))
        XCTAssertTrue(noteField.waitForExistence(timeout: 2), "Swipe-dismissed note should still have saved")
        XCTAssertEqual(noteField.value as? String, "Swiped away")
        app.buttons["currentDriveDetailsConfirm"].tap()
    }

    func testTollButtonOpensFeeSheetWithTollSelected() {
        waitForTripsScreen()

        let toll = app.buttons["currentDriveBarToll"].firstMatch
        XCTAssertTrue(toll.waitForExistence(timeout: 8))
        toll.tap()

        XCTAssertTrue(app.navigationBars["Add Fee"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.segmentedControls.buttons["Toll"].firstMatch.isSelected, "Toll should be pre-selected")
    }

    func testParkingButtonOpensFeeSheetWithParkingSelected() {
        waitForTripsScreen()

        let parking = app.buttons["currentDriveBarParking"].firstMatch
        XCTAssertTrue(parking.waitForExistence(timeout: 8))
        parking.tap()

        XCTAssertTrue(app.navigationBars["Add Fee"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.segmentedControls.buttons["Parking"].firstMatch.isSelected, "Parking should be pre-selected")
    }

    func testNewLegButtonVisibleOnBar() {
        waitForTripsScreen()

        let newLeg = app.buttons["currentDriveBarNewLeg"].firstMatch
        XCTAssertTrue(newLeg.waitForExistence(timeout: 8), "New Leg button should be on the glass bar")
        XCTAssertEqual(newLeg.label, "Start new leg")
    }

    func testNewLegKeepsBarRecordingAndResetsClassification() {
        waitForTripsScreen()

        let business = app.buttons["currentDriveBarClassificationbusiness"].firstMatch
        XCTAssertTrue(business.waitForExistence(timeout: 8))

        // Classify first so the reset to unclassified is observable, then dismiss
        // the purpose sheet the Business tap opens.
        business.tap()
        XCTAssertTrue(app.navigationBars["Business Drive"].waitForExistence(timeout: 4))
        app.buttons["currentDriveDetailsConfirm"].tap()
        XCTAssertTrue(waitForSelected(business), "Business should be selected before the split")

        app.buttons["currentDriveBarNewLeg"].firstMatch.tap()

        // The split keeps a drive recording: the bar stays, the bottom toolbar
        // stays available, and the new leg starts unclassified.
        XCTAssertTrue(app.buttons["currentDriveBarToll"].waitForExistence(timeout: 4), "Glass bar should survive the split")
        XCTAssertTrue(app.buttons["addTripButton"].exists, "Add Trip should stay visible while the new leg records")
        XCTAssertTrue(waitForDeselected(business), "New leg should start unclassified")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(100_000)
        }
        return !element.exists
    }

    private func waitForSelected(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isSelected { return true }
            usleep(100_000)
        }
        return element.isSelected
    }

    private func waitForDeselected(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.isSelected { return true }
            usleep(100_000)
        }
        return !element.isSelected
    }
}
