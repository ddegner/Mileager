import XCTest

/// The Mac's two native selection paths: a live browse selection for ordinary
/// clicks, plus explicit SwiftUI Select mode when plain clicks need to build a
/// multi-selection. The reading pane mirrors either selection.
///
/// `--mac-mode=on` is the only way to reach it from a simulator. The proxy can
/// verify the app's platform branching and reading-pane states, but its List
/// still runs on iPadOS and cannot prove the Designed-for-iPad Mac host's click
/// behavior. That, bottom-bar delivery, and the host window stay on the manual
/// checklist.
///
/// A class of its own rather than more cases in `SplitShellUITests`: launching
/// straight into Mac mode is one app launch per test instead of two, and each
/// launch is about ten seconds of a suite that is already the slow one.
@MainActor
final class MacListSelectionUITests: MileageTrackerUITestCase {
    override var requiresExpandedSplitShell: Bool { true }

    override var launchArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-mileage-data",
            "--seed-vehicles",
            "--skip-onboarding",
            "--mac-mode=on",
            "--test-store-suffix=mac-list"
        ] + Self.englishLocaleArguments
    }

    /// The shared helper plus the wait every test here needs: a Mac list is
    /// only itself once it has rows to select.
    private func openAllTripsWithRows(file: StaticString = #filePath, line: UInt = #line) {
        openAllTrips(file: file, line: line)
        XCTAssertTrue(
            driveCards.element(boundBy: 0)
                .waitForExistence(timeout: 8),
            file: file,
            line: line
        )
    }

    /// An ordinary browse click is still persistent selection, not an implicit
    /// entry into Select mode. Its verbs stay in place and no Done appears.
    func testMacBrowseSelectionNeverChangesToolbarShape() throws {
        try XCTSkipUnless(
            shell == .split,
            "The Mac list only exists in the expanded split shell; run this on an iPad."
        )
        openAllTripsWithRows()
        XCTAssertEqual(
            driveCards.firstMatch.elementType, .button,
            "A passive row still announces itself as a button to VoiceOver"
        )

        let classify = app.buttons["bulkClassifyButton"]
        let merge = app.buttons["mergeTripsButton"]
        let delete = app.buttons["deleteSelectedTripsButton"]
        for verb in [classify, merge, delete] {
            XCTAssertTrue(verb.exists, "Every verb is there before anything is selected")
            XCTAssertFalse(verb.isEnabled, "…and grayed out while nothing is")
        }
        XCTAssertTrue(app.buttons["listAddTripButton"].exists)
        XCTAssertTrue(app.buttons["filterDrivesMenu"].exists)
        XCTAssertTrue(
            app.buttons["selectTripsButton"].exists,
            "Select must be a directly visible Mac toolbar button"
        )

        let cards = driveCards
        tapDriveCard(cards.element(boundBy: 0))

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !classify.isEnabled {
            usleep(100_000)
        }
        XCTAssertTrue(classify.isEnabled, "A selection must enable the verbs")
        XCTAssertTrue(delete.isEnabled)
        XCTAssertFalse(merge.isEnabled, "One trip is not a merge")
        XCTAssertFalse(app.buttons["selectionDoneButton"].exists, "A browse click must not enter Select mode")
        XCTAssertTrue(app.buttons["listAddTripButton"].exists, "Nothing may be displaced")
        XCTAssertTrue(app.buttons["filterDrivesMenu"].exists)
    }

    /// Explicit Select mode is SwiftUI's modifier-free fallback on a Mac:
    /// ordinary clicks add checkmarked rows until Done returns to browsing.
    func testMacSelectModeBuildsMultiSelectionAndDoneReturnsToBrowse() throws {
        try XCTSkipUnless(
            shell == .split,
            "The Mac list only exists in the expanded split shell; run this on an iPad."
        )
        openAllTripsWithRows()
        let cards = driveCards
        let placeholder = app.descendants(matching: .any)["noTripSelectedPane"].firstMatch
        let select = app.buttons["selectTripsButton"]
        XCTAssertTrue(
            select.waitForExistence(timeout: 6),
            "Select must be directly visible without opening List Options"
        )

        let stableBarIDs = [
            "bulkClassifyButton",
            "bulkVehicleButton",
            "mergeTripsButton",
            "deleteSelectedTripsButton",
        ]
        let browseFrames = Dictionary(uniqueKeysWithValues: stableBarIDs.map { identifier in
            let element = app.buttons[identifier]
            XCTAssertTrue(element.exists, "Missing \(identifier) in browse mode")
            XCTAssertFalse(element.frame.isEmpty, "\(identifier) must have a rendered frame")
            return (identifier, element.frame)
        })
        assertStableSelectionBar(browseFrames, identifiers: stableBarIDs, phase: "browse")

        select.tap()

        let done = app.buttons["selectionDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 6), "The Mac must offer a visible way out of Select mode")
        let classify = app.buttons["bulkClassifyButton"]
        XCTAssertTrue(classify.waitForExistence(timeout: 6))
        XCTAssertFalse(classify.isEnabled, "Nothing is checked yet")
        XCTAssertTrue(app.buttons["listAddTripButton"].exists, "Add must keep its stable bar position")
        XCTAssertTrue(app.buttons["filterDrivesMenu"].exists, "Filter must keep its stable bar position")
        assertStableSelectionBar(
            browseFrames,
            identifiers: stableBarIDs,
            phase: "empty Select mode"
        )

        tapDriveCard(cards.element(boundBy: 0))
        tapDriveCard(cards.element(boundBy: 1))
        let selectionDeadline = Date().addingTimeInterval(6)
        while Date() < selectionDeadline,
              !(cards.element(boundBy: 0).isSelected && cards.element(boundBy: 1).isSelected) {
            usleep(100_000)
        }
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)
        XCTAssertTrue(cards.element(boundBy: 1).isSelected)
        XCTAssertTrue(classify.isEnabled, "Two plain clicks in Select mode must build a selection")
        assertStableSelectionBar(
            browseFrames,
            identifiers: stableBarIDs,
            phase: "populated Select mode"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["multiTripSelectionPane"].firstMatch
                .waitForExistence(timeout: 6),
            "The reading pane must receive the same multi-selection"
        )

        done.tap()
        XCTAssertTrue(waitForNonExistence(done, timeout: 6))
        XCTAssertTrue(placeholder.waitForExistence(timeout: 6), "Done must clear the selection")
        XCTAssertFalse(cards.element(boundBy: 0).isSelected)
        XCTAssertFalse(cards.element(boundBy: 1).isSelected)
        XCTAssertTrue(app.buttons["listAddTripButton"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["selectTripsButton"].waitForExistence(timeout: 6))
        assertStableSelectionBar(
            browseFrames,
            identifiers: stableBarIDs,
            phase: "returned browse mode"
        )

        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetailDestination("Client"), "Done must restore singleton browse selection")
        XCTAssertFalse(app.buttons["selectionDoneButton"].exists)
    }

    /// Liquid Glass may regroup toolbar items when the content list changes.
    /// The multi-select capsule is intentionally one fixed Mac control: its
    /// items retain their order and geometry while only enablement changes.
    private func assertStableSelectionBar(
        _ reference: [String: CGRect],
        identifiers: [String],
        phase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frames = identifiers.map { identifier -> CGRect in
            let element = app.buttons[identifier]
            XCTAssertTrue(element.exists, "Missing \(identifier) during \(phase)", file: file, line: line)
            guard let expected = reference[identifier] else {
                XCTFail("No reference frame for \(identifier)", file: file, line: line)
                return element.frame
            }
            let actual = element.frame
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 4, "\(identifier) moved horizontally during \(phase)", file: file, line: line)
            XCTAssertEqual(actual.midY, expected.midY, accuracy: 4, "\(identifier) moved vertically during \(phase)", file: file, line: line)
            return actual
        }

        for pair in zip(frames, frames.dropFirst()) {
            XCTAssertLessThan(pair.0.midX, pair.1.midX, "Bulk actions changed order during \(phase)", file: file, line: line)
        }
    }

    /// The list drops the floating sidebar's safe area so swipe actions get
    /// normal full-width cells, then restores it as a scroll-content margin.
    /// Empty-state overlays are not scroll content: after the last trips are
    /// deleted, their visible text must still stay inside the uncovered part
    /// of the content column rather than centering beneath the sidebar.
    func testDeletingLastTripsKeepsEmptyStateClearOfSidebar() throws {
        try XCTSkipUnless(
            shell == .split,
            "The floating sidebar only exists in the expanded split shell; run this on an iPad."
        )
        openAllTripsWithRows()

        let selectMany = app.buttons["selectManyReadingPaneTestSelection"].firstMatch
        XCTAssertTrue(selectMany.waitForExistence(timeout: 4))
        selectMany.tap()

        let delete = app.buttons["deleteSelectedTripsButton"]
        let selectionDeadline = Date().addingTimeInterval(6)
        while Date() < selectionDeadline, !delete.isEnabled {
            usleep(100_000)
        }
        XCTAssertTrue(delete.isEnabled, "Selecting both seeded trips must enable Delete")
        delete.tap()

        let alert = app.alerts["Delete selected trips?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        alert.buttons["Delete 2 Trips"].tap()

        let emptyState = app.descendants(matching: .any)["emptyScopeState"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForNonExistence(driveCards.firstMatch, timeout: 6))

        let title = app.staticTexts["No trips"].firstMatch
        let description = app.staticTexts["Drives you take show up here automatically."].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        XCTAssertTrue(description.waitForExistence(timeout: 4))

        let sidebarTrailingEdge = max(
            navigationBar(in: .sidebar).frame.maxX,
            app.buttons["mailboxAllTrips"].frame.maxX,
            app.buttons["sidebarSettingsRow"].frame.maxX
        )
        let listTrailingEdge = navigationBar(in: .list).frame.maxX
        for text in [title, description] {
            XCTAssertGreaterThanOrEqual(
                text.frame.minX,
                sidebarTrailingEdge - 1,
                "The empty-state text must not draw underneath the floating sidebar"
            )
            XCTAssertGreaterThan(text.frame.midX, sidebarTrailingEdge)
            XCTAssertLessThan(text.frame.midX, listTrailingEdge)
        }
    }

    /// The reading pane is a direct rendering of zero, one, or several
    /// selected trips. Removing one member of a two-trip selection must render
    /// the remaining trip directly rather than passing through the placeholder.
    func testMacSelectionDrivesZeroOneManyOneReadingPaneStates() throws {
        try XCTSkipUnless(
            shell == .split,
            "The Mac list only exists in the expanded split shell; run this on an iPad."
        )
        openAllTripsWithRows()
        let cards = driveCards
        let placeholder = app.descendants(matching: .any)["noTripSelectedPane"].firstMatch
        let advanceSelection = app.buttons["advanceReadingPaneTestSelection"].firstMatch

        XCTAssertTrue(placeholder.waitForExistence(timeout: 4), "Zero selected trips show the placeholder")
        XCTAssertTrue(advanceSelection.waitForExistence(timeout: 4))

        tapReadingPaneSelectionDriver(advanceSelection)
        XCTAssertTrue(
            waitForTripDetailDestination("Client"),
            "One selected trip reads that exact trip in the pane"
        )
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)

        tapReadingPaneSelectionDriver(advanceSelection)
        XCTAssertTrue(
            app.descendants(matching: .any)["multiTripSelectionPane"].firstMatch
                .waitForExistence(timeout: 6),
            "Several selected trips summarise instead of reading one of them"
        )
        XCTAssertTrue(
            waitForNonExistence(tripDetailScreenMarker, timeout: 4),
            "No single trip may still be showing"
        )

        tapReadingPaneSelectionDriver(advanceSelection)
        XCTAssertTrue(
            waitForTripDetailDestination("Home", forbidding: placeholder),
            "Returning to one selected trip should immediately read Home"
        )
        XCTAssertTrue(
            waitForNonExistence(
                app.descendants(matching: .any)["multiTripSelectionPane"].firstMatch,
                timeout: 4
            ),
            "Returning to one selected trip must dismiss the summary"
        )
        XCTAssertFalse(cards.element(boundBy: 0).isSelected)
        XCTAssertTrue(cards.element(boundBy: 1).isSelected)
    }

    /// The reading pane changes its hosted root between empty, detail, and
    /// summary states. XCUI can retain the button's old accessibility
    /// `visiblePoint` across that swap even though its frame is current, which
    /// sends a plain `tap()` outside this test-only control. Resolve the center
    /// from the live frame instead so the driver tests presentation state, not
    /// Accessibility's cached hit-point choice.
    private func tapReadingPaneSelectionDriver(_ driver: XCUIElement) {
        driver.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// The pane and the selection are one fact here, so whatever moves the
    /// pane has to move the selection with it.
    ///
    /// Trip Detail's ↑/↓ chevrons rewrite the root's navigation path directly,
    /// which used to leave the filled row on the trip the user had clicked
    /// while the pane read the next one. Every bulk verb reads the selection,
    /// not the pane — so Classify, Merge and Delete all acted on a trip that
    /// was no longer on screen, and ⌘⌫ deleted it behind a confirmation that
    /// named no date.
    func testSteppingTheReadingPaneMovesTheSelectionWithIt() throws {
        try XCTSkipUnless(
            shell == .split,
            "The Mac list only exists in the expanded split shell; run this on an iPad."
        )
        openAllTripsWithRows()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 8))

        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetailDestination("Client"), "The first row is the Client trip")
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)

        // Matched on identity across every element type, like the suite's
        // other markers: the chevrons sit in a trailing group behind a
        // `ToolbarSpacer` in the detail column's bar, and nothing had ever
        // located them in the split shell before this test — the other suites
        // that tap them run on the iPhone. `app.buttons[...]` came back empty
        // on the first CI run; the element tree goes into the message so the
        // next failure says what the bar actually holds.
        let next = app.descendants(matching: .any)["tripDetailNextTrip"].firstMatch
        XCTAssertTrue(
            next.waitForExistence(timeout: 8),
            "No next-trip chevron in the detail column. Bars: "
                + app.navigationBars.allElementsBoundByIndex
                    .map { "\($0.identifier): \($0.buttons.allElementsBoundByIndex.map(\.identifier))" }
                    .joined(separator: " | ")
        )
        next.tap()

        let placeholder = app.descendants(matching: .any)["noTripSelectedPane"].firstMatch
        XCTAssertTrue(
            waitForTripDetailDestination("Home", forbidding: placeholder),
            "The next-trip chevron must replace Client detail with Home detail"
        )

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !cards.element(boundBy: 1).isSelected {
            usleep(100_000)
        }
        XCTAssertTrue(
            cards.element(boundBy: 1).isSelected,
            "Stepping the pane must select the row it landed on"
        )
        XCTAssertFalse(
            cards.element(boundBy: 0).isSelected,
            "…and must not leave the previous row selected for the verbs to act on"
        )
    }
    /// Repeated plain clicks must REPLACE the selection and read the new trip.
    ///
    /// Field report, 2026-09-01: the second click showed "No Trip Selected"
    /// before sliding the next detail in. The expanded detail is now rendered
    /// as the reading-pane root, so A → B is one identity replacement rather
    /// than remove-route, wait, then push-route.
    func testSecondPlainClickReplacesSelection() throws {
        try XCTSkipUnless(
            shell == .split,
            "The Mac list only exists in the expanded split shell; run this on an iPad."
        )
        openAllTripsWithRows()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 8))
        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetailDestination("Client"), "first click reads Client in the pane")
        let originalDetailMinX = tripDetailDestinationMarker.frame.minX
        let placeholder = app.descendants(matching: .any)["noTripSelectedPane"].firstMatch
        let replacements: [(row: Int, destination: String)] = [
            (1, "Home"),
            (0, "Client"),
            (1, "Home"),
            (0, "Client"),
            (1, "Home"),
            (0, "Client"),
            (1, "Home"),
            (0, "Client"),
            (1, "Home"),
            (0, "Client")
        ]

        for replacement in replacements {
            let presentationTraceBeforeReplacement = readingPanePresentationTrace
            tapDriveCard(cards.element(boundBy: replacement.row))
            XCTAssertTrue(
                waitForTripDetailDestination(replacement.destination, forbidding: placeholder),
                "Plain A/B clicks must replace detail without presenting an empty pane"
            )
            assertImmediateTripReplacementTrace(after: presentationTraceBeforeReplacement)
            XCTAssertEqual(
                tripDetailDestinationMarker.frame.minX,
                originalDetailMinX,
                accuracy: 2,
                "Peer trip details replace at the same reading-pane position rather than sliding horizontally"
            )
            XCTAssertTrue(cards.element(boundBy: replacement.row).isSelected)
            XCTAssertFalse(cards.element(boundBy: replacement.row == 0 ? 1 : 0).isSelected)
        }
    }
}

/// The compact Mac keeps a browse-only primary action because it has no
/// adjacent reading pane. A forced stack launch proves explicit Select mode
/// bypasses that different binding and navigation path.
@MainActor
final class MacCompactSelectionUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-mileage-data",
            "--skip-onboarding",
            "--mac-mode=on",
            "--ui-shell=stack",
            "--test-store-suffix=mac-compact-selection"
        ] + Self.englishLocaleArguments
    }

    func testSelectModeBuildsMultiSelectionWithoutOpeningTripDetail() throws {
        try XCTSkipUnless(shell == .stack, "This test requires the forced compact shell")
        waitForTripsScreen()
        openAllTrips()

        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 8))
        let select = app.buttons["selectTripsButton"]
        XCTAssertTrue(
            select.waitForExistence(timeout: 6),
            "Compact Mac must expose Select directly too"
        )
        select.tap()

        let done = app.buttons["selectionDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 6))
        tapDriveCard(cards.element(boundBy: 0))
        tapDriveCard(cards.element(boundBy: 1))

        let selectionDeadline = Date().addingTimeInterval(6)
        while Date() < selectionDeadline,
              !(cards.element(boundBy: 0).isSelected && cards.element(boundBy: 1).isSelected) {
            usleep(100_000)
        }
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)
        XCTAssertTrue(cards.element(boundBy: 1).isSelected)
        XCTAssertTrue(app.buttons["bulkClassifyButton"].isEnabled)
        XCTAssertFalse(
            tripDetailScreenMarker.waitForExistence(timeout: 2),
            "Select-mode clicks must not invoke compact Mac's browse primary action"
        )
        assertScopeIsOpen("All Trips")

        // The compact browse binding deliberately delays singleton empty
        // writes. Edit mode must bypass it, including when the final checked
        // row is toggled off rather than cleared by Done.
        tapDriveCard(cards.element(boundBy: 1))
        tapDriveCard(cards.element(boundBy: 0))
        let emptyDeadline = Date().addingTimeInterval(6)
        while Date() < emptyDeadline,
              (cards.element(boundBy: 0).isSelected || cards.element(boundBy: 1).isSelected) {
            usleep(100_000)
        }
        XCTAssertFalse(cards.element(boundBy: 0).isSelected)
        XCTAssertFalse(cards.element(boundBy: 1).isSelected)
        XCTAssertTrue(done.exists, "An empty selection must remain in explicit Select mode")

        tapDriveCard(cards.element(boundBy: 0))
        tapDriveCard(cards.element(boundBy: 1))
        let reselectionDeadline = Date().addingTimeInterval(6)
        while Date() < reselectionDeadline,
              !(cards.element(boundBy: 0).isSelected && cards.element(boundBy: 1).isSelected) {
            usleep(100_000)
        }
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)
        XCTAssertTrue(cards.element(boundBy: 1).isSelected)

        done.tap()
        XCTAssertTrue(waitForNonExistence(done, timeout: 6))
        XCTAssertFalse(cards.element(boundBy: 0).isSelected)
        XCTAssertFalse(cards.element(boundBy: 1).isSelected)
        XCTAssertTrue(app.buttons["listAddTripButton"].waitForExistence(timeout: 6))

        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(
            waitForTripDetailDestination("Client"),
            "Done must restore compact Mac's singleton browse navigation"
        )
    }
}
