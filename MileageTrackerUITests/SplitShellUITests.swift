import XCTest

/// The only automated coverage of the three-column shell.
///
/// **Requires a regular-width device — run it on an iPad.**
///
/// `--ui-shell=split` cannot substitute for one. The override decides which
/// container `ContentView` mounts, but SwiftUI still COLLAPSES a
/// `NavigationSplitView` at compact width, and a collapsed split view shows one
/// column at a time — so on an iPhone these tests would exercise a third thing
/// that ships nowhere. Every test here skips rather than pretending otherwise;
/// `scripts/validate.sh` runs the suite on an iPad. The shared test setup
/// rotates the split shell to landscape so all three columns are visible.
///
/// What this CANNOT catch, because a simulator is not a Mac: the invisible
/// `UIToolbar` a `.bottomBar` group lays across the sidebar (on iPad that bar
/// is perfectly clickable), the sidebar toolbar dying in the window titlebar,
/// `MacSheetFrame`'s Mac-only sizing, and anything involving the menu bar or
/// Cmd-chords. Those stay on the manual checklist in
/// `docs/mac-manual-verification.md`. What it CAN catch is every gate and
/// every cross-column route below.
@MainActor
final class SplitShellUITests: MileageTrackerUITestCase {
    override var requiresExpandedSplitShell: Bool { true }

    override var launchArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-mileage-data",
            "--skip-onboarding",
            "--test-store-suffix=split-shell"
        ] + Self.englishLocaleArguments
    }

    /// Skips on any device that does not mount the expanded split view, so a
    /// stray iPhone run reports "skipped" instead of a wall of misleading
    /// failures. Called first in every test below.
    private func requireSplitShell() throws {
        try XCTSkipUnless(
            shell == .split,
            "SplitShellUITests needs a regular-width device (iPad); this one mounted the stack."
        )
    }

    func testLaunchMountsTheSplitShell() throws {
        try requireSplitShell()
        XCTAssertEqual(shell, .split)
    }

    /// The two `if !usesSplitView` toolbar gates. Both encode real Mac bugs:
    /// the gear renders in the window titlebar where it never delivers clicks,
    /// and the bottom bar made the entire sidebar column inert. This is the
    /// only automated cover they will ever get.
    func testSplitShellDropsTheStackOnlyToolbarItems() throws {
        try requireSplitShell()
        waitForTripsScreen()
        XCTAssertFalse(app.buttons["settingsButton"].exists, "The toolbar gear is dead furniture here")
        XCTAssertFalse(app.buttons["addTripButton"].exists, "The bottom bar swallows sidebar clicks here")
        XCTAssertTrue(app.buttons["sidebarSettingsRow"].exists, "Settings must still be reachable")
    }

    /// Selecting in the sidebar must drive the content column. The proxy for
    /// "the sidebar went completely inert" — the single worst Mac regression
    /// in this area.
    func testSidebarSelectionDrivesTheContentColumn() throws {
        try requireSplitShell()
        waitForTripsScreen()
        openAllTrips()
        XCTAssertTrue(
            driveCards.firstMatch.waitForExistence(timeout: 8),
            "Selecting All Trips should fill the content column"
        )
    }

    /// Cross-column routing: a trip row must fill the detail column WITHOUT
    /// collapsing the list. A regression to `NavigationLink(value:)` leaves the
    /// detail column empty, which the list-column assertion would not notice on
    /// its own.
    func testOpeningATripFillsDetailWithoutLeavingTheList() throws {
        try requireSplitShell()
        waitForTripsScreen()
        openAllTrips()
        let card = driveCards.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        tapDriveCard(card)
        XCTAssertTrue(
            waitForTripDetailDestination("Client"),
            "The seeded Client trip should open in the detail column"
        )
        assertScopeIsOpen("All Trips")
    }

    /// On an expanded iPad a normal tap is a primary action, not a checkmark.
    /// Peer trips replace the reading-pane root: they do not briefly remove the
    /// old route and push a new detail with a horizontal transition.
    func testPrimaryActionAndChevronReplaceTripIdentityInPlaceOnIPad() throws {
        try requireSplitShell()
        waitForTripsScreen()
        openAllTrips()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 8))

        tapDriveCard(cards.element(boundBy: 0))
        XCTAssertTrue(waitForTripDetailDestination("Client"), "Row A should read the Client trip")
        let presentationTraceBeforeReplacement = readingPanePresentationTrace
        let originalDetailMinX = tripDetailDestinationMarker.frame.minX
        let originalDetailButtons = navigationBar(in: .detail).buttons.allElementsBoundByIndex
            .map(\.identifier)
        let placeholder = app.descendants(matching: .any)["noTripSelectedPane"].firstMatch

        tapDriveCard(cards.element(boundBy: 1))
        XCTAssertTrue(
            waitForTripDetailDestination("Home", forbidding: placeholder),
            "Row B should replace Client with Home without an empty reading pane"
        )
        assertImmediateTripReplacementTrace(after: presentationTraceBeforeReplacement)
        XCTAssertEqual(
            tripDetailDestinationMarker.frame.minX,
            originalDetailMinX,
            accuracy: 2,
            "Peer details must occupy the same column position instead of sliding in"
        )
        XCTAssertEqual(
            navigationBar(in: .detail).buttons.allElementsBoundByIndex.map(\.identifier),
            originalDetailButtons,
            "Replacing a peer detail must not add another navigation-stack level"
        )

        let previous = app.descendants(matching: .any)["tripDetailPreviousTrip"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 8), "Home detail should offer the previous-trip chevron")
        previous.tap()
        XCTAssertTrue(
            waitForTripDetailDestination("Client", forbidding: placeholder),
            "The detail chevron should replace Home with the exact Client trip"
        )
        XCTAssertEqual(tripDetailDestinationMarker.frame.minX, originalDetailMinX, accuracy: 2)
        assertScopeIsOpen("All Trips")
    }

    /// A split reading pane is a root presentation, not a pushed destination.
    /// It therefore has no peer-detail Back level; the selected scope remains
    /// independently mounted in the content column.
    func testTripDetailIsReadingPaneRootWithoutBackLevel() throws {
        try requireSplitShell()
        waitForTripsScreen()
        openAllTrips()
        let card = driveCards.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        tapDriveCard(card)
        XCTAssertTrue(waitForTripDetailDestination("Client"))

        let detailBar = navigationBar(in: .detail)
        XCTAssertFalse(detailBar.buttons["Back"].exists, "The reading-pane root must not have a Back level")
        XCTAssertFalse(detailBar.buttons["All Trips"].exists, "The scope belongs to the adjacent content column")
        assertScopeIsOpen("All Trips")
    }

    /// iPad's method: a trackpad's ⌘-click fills the SAME selection Select
    /// mode does and raises the same bar. It used to leave rows painted by
    /// UIKit while `List(selection:)` stayed empty, so nothing — the bar, the
    /// ⌘-menu, the context menu — could act on what the user had picked.
    func testCommandClickRevealsTheBulkActionBarOnIPad() throws {
        try requireSplitShell()
        waitForTripsScreen()
        openAllTrips()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["bulkClassifyButton"].exists, "Nothing is selected yet")

        tapDriveCard(cards.element(boundBy: 0), modifiers: .command)

        XCTAssertTrue(
            app.buttons["bulkClassifyButton"].waitForExistence(timeout: 6),
            "A pointer selection must offer the same verbs Select mode does"
        )
        XCTAssertTrue(app.buttons["deleteSelectedTripsButton"].exists)
        XCTAssertTrue(app.buttons["selectionDoneButton"].exists)
        // The browse chrome yields to the selection bar, exactly as it does in
        // Select mode — one bar at a time.
        XCTAssertFalse(app.buttons["listAddTripButton"].exists)

        app.buttons["selectionDoneButton"].tap()
        XCTAssertTrue(
            waitForNonExistence(app.buttons["bulkClassifyButton"], timeout: 6),
            "Done must clear a pointer selection too"
        )
        XCTAssertTrue(app.buttons["listAddTripButton"].waitForExistence(timeout: 6))
    }

    /// The iPad's own half of the touch method: Select mode, then a bare tap
    /// fills the checkmark rather than opening the trip.
    ///
    /// Rows expose their primary action through the list-level selection API;
    /// while the list is editing, SwiftUI owns the touch and updates the
    /// selection instead of invoking that primary action.
    func testSelectModeChecksRowsByTouchOnIPad() throws {
        try requireSplitShell()
        waitForTripsScreen()
        openAllTrips()
        let cards = driveCards
        XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 8))

        app.buttons["listOptionsMenu"].firstMatch.tap()
        let select = app.buttons["selectTripsButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 6))
        select.tap()
        XCTAssertTrue(
            app.buttons["selectionDoneButton"].waitForExistence(timeout: 6),
            "Select mode should be running"
        )

        let classify = app.buttons["bulkClassifyButton"]
        XCTAssertTrue(classify.waitForExistence(timeout: 6))
        XCTAssertFalse(classify.isEnabled, "Nothing is checked yet")

        tapDriveCard(cards.element(boundBy: 0))

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !classify.isEnabled {
            usleep(100_000)
        }
        XCTAssertTrue(classify.isEnabled, "A tap in Select mode must check the row")
        // A checkmark is only a checkmark (David's call, 2026-09-01, which
        // replaced the 08-31 pane-follows-first-checked rule): checking a row
        // must not open or change the reading pane. This assertion was
        // flipped once to match the old rule; the decision since then is the
        // newer one, and DriveListView no longer opens anything on check.
        XCTAssertFalse(
            tripDetailScreenMarker.exists,
            "…and must not open the trip instead"
        )
    }

    /// Settings through the sidebar footer row, the split shell's only
    /// pointer-driven route to it.
    func testSettingsOpensFromTheSidebarFooterRow() throws {
        try requireSplitShell()
        waitForTripsScreen()

        let settings = app.buttons["sidebarSettingsRow"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 4))
        XCTAssertTrue(settings.isHittable, "The fixed Settings footer must remain clickable")
        XCTAssertGreaterThan(
            settings.frame.midY,
            app.frame.height * 0.75,
            "Settings should stay in the bottom quarter of the sidebar"
        )
        XCTAssertLessThan(
            app.frame.maxY - settings.frame.maxY,
            app.frame.height * 0.12,
            "Settings should stay close to the bottom edge"
        )

        openSettingsFromTripsList()
    }
}
