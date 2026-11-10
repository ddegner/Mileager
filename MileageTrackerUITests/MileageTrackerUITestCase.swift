import XCTest
import UIKit

@MainActor
class MileageTrackerUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// The app is localized; these tests assert English UI text, so every
    /// launch pins language, locale, and (via the app's own preferences code
    /// paths) miles/USD regardless of the simulator's region settings.
    static let englishLocaleArguments = [
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US"
    ]

    var launchArguments: [String] {
        [
            "--uitesting",
            "--uitesting-mapkit-fixtures",
            "--reset-data",
            "--reset-preferences",
            "--seed-mileage-data",
            "--skip-onboarding"
        ]
            + Self.englishLocaleArguments
    }

    /// Three visible split columns need the iPad's landscape width. Ordinary
    /// suites retain portrait so expanded coverage cannot leak into them.
    var requiresExpandedSplitShell: Bool { false }

    /// Which navigation shell the app reported mounting.
    ///
    /// Resolved once, from the app's own marker — never inferred from the
    /// device or from a navigation-bar count. Resolving it is also the
    /// suite's first real assertion: if neither marker appears, every helper
    /// below would be guessing, so we fail here rather than somewhere
    /// downstream and confusing.
    private(set) var shell: UITestShell = .stack

    enum UITestShell: String {
        case stack
        case split
    }

    /// The three columns of the split shell, and their stack equivalents.
    enum ShellColumn {
        /// The mailbox list. In the stack this is the root.
        case sidebar
        /// The trip list for the selected scope.
        case list
        /// The reading pane.
        case detail
    }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = requiresExpandedSplitShell ? .landscapeLeft : .portrait
        }
        app = XCUIApplication()
        app.launchArguments = launchArguments
        app.launch()
        shell = resolveShell()
        if shell == .split {
            // On iOS 27, portrait iPads may collapse the sidebar even when
            // NavigationSplitView is initialized with visibility .all. The
            // cross-column assertions below require its expanded layout.
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    private func resolveShell(file: StaticString = #filePath, line: UInt = #line) -> UITestShell {
        let split = app.descendants(matching: .any)["navigationShellSplit"].firstMatch
        let stack = app.descendants(matching: .any)["navigationShellStack"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !split.exists, !stack.exists {
            usleep(100_000)
        }
        if split.exists { return .split }
        if stack.exists { return .stack }
        XCTFail(
            "The app published no navigation-shell marker. Every shell-aware "
            + "helper would be guessing from here.",
            file: file,
            line: line
        )
        return .stack
    }

    /// The navigation bar belonging to one column.
    ///
    /// Replaces `app.navigationBars.firstMatch`, which in the split shell picks
    /// nondeterministically among three concurrently-live bars.
    ///
    /// Geometry cannot identify them. Measured on an iPad Pro 13", the three
    /// bars are:
    ///
    ///     "All Trips"              minX=0    width=567   <- content column
    ///     NavigationStackHosting   minX=568  width=464   <- detail column
    ///     "Trips"                  minX=10   width=280   <- sidebar
    ///
    /// The CONTENT column's bar reports minX=0 and spans the sidebar, so
    /// sorting by minX puts it first and the sidebar second. Identity is the
    /// only stable discriminator: the sidebar's title is always "Trips"
    /// (MailboxesList's navigationTitle never changes), the detail column is
    /// the rightmost bar, and the list column is whatever is left.
    func navigationBar(
        in column: ShellColumn,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        guard shell == .split else {
            // A stack shows one bar at a time, and during a push two briefly
            // coexist at the same origin - so geometry says nothing here
            // either. Let the transition settle, then take the last by index,
            // which is the one on top.
            let settled = Date().addingTimeInterval(4)
            while Date() < settled, app.navigationBars.count > 1 {
                usleep(100_000)
            }
            let stackBars = app.navigationBars.allElementsBoundByIndex.filter(\.exists)
            guard let top = stackBars.last else {
                XCTFail("No navigation bar is present", file: file, line: line)
                return app.navigationBars.firstMatch
            }
            return top
        }

        let bars = app.navigationBars.allElementsBoundByIndex.filter(\.exists)
        guard !bars.isEmpty else {
            XCTFail("No navigation bar is present", file: file, line: line)
            return app.navigationBars.firstMatch
        }
        let sidebar = bars.first { $0.identifier == "Trips" }
        let detail = bars.max { $0.frame.minX < $1.frame.minX }

        let match: XCUIElement?
        switch column {
        case .sidebar:
            match = sidebar
        case .detail:
            match = detail
        case .list:
            match = bars.first { bar in
                bar.identifier != "Trips" && bar.frame.minX != detail?.frame.minX
            }
        }
        guard let match else {
            XCTFail(
                "No bar for \(column) among \(bars.count): \(bars.map(\.identifier))",
                file: file,
                line: line
            )
            return app.navigationBars.firstMatch
        }
        return match
    }

    func relaunch(arguments: [String]) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = arguments + Self.englishLocaleArguments
        app.launch()
        // A relaunch can mount a different shell (a different --ui-shell, a
        // different seed), and every helper below keys off `shell`. Leaving the
        // old value in place would silently point them at the wrong columns.
        shell = resolveShell()
    }

    /// Waits for the app to be usable and leaves it on the Mailboxes root.
    ///
    /// A seeded app with unresolved work launches into Need Review, so this pops
    /// back when it has to. Resolved-only and fresh installs remain at the root.
    /// The short stabilization window
    /// avoids mistaking the root's transient first frame for a completed launch.
    func waitForTripsScreen(file: StaticString = #filePath, line: UInt = #line) {
        let root = app.navigationBars["Trips"]
        let inbox = app.navigationBars["Need Review"]
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !root.exists, !inbox.exists {
            usleep(100_000)
        }
        XCTAssertTrue(
            root.exists || inbox.exists,
            "Neither the Mailboxes root nor the inbox appeared",
            file: file,
            line: line
        )

        switch shell {
        case .stack:
            // A seeded app with unresolved work launches into Need Review, so
            // pop back when it has to.
            if root.exists, !inbox.exists {
                _ = inbox.waitForExistence(timeout: 1.5)
            }
            if inbox.exists {
                tapBack(from: "Need Review", file: file, line: line)
                // The pop must be observable. Without this the final assertion
                // below passes whether or not the tap did anything.
                XCTAssertTrue(
                    waitForNonExistence(inbox, timeout: 6),
                    "Popping Need Review left its bar on screen",
                    file: file,
                    line: line
                )
            }
            XCTAssertTrue(root.waitForExistence(timeout: 8), file: file, line: line)
            XCTAssertTrue(
                app.buttons["settingsButton"].exists,
                "The stack shell must offer the toolbar Settings gear",
                file: file,
                line: line
            )
            XCTAssertFalse(
                app.buttons["sidebarSettingsRow"].exists,
                "The sidebar Settings row belongs to the split shell only",
                file: file,
                line: line
            )

        case .split:
            // "Pop back to the root" has no meaning here: the sidebar and the
            // content column are mounted at the same time, so root.exists and
            // inbox.exists is the normal steady state, not a transient. The
            // old code read that as "we navigated into the inbox" and tapped
            // back out of a column it never entered.
            XCTAssertTrue(
                app.navigationBars["Trips"].waitForExistence(timeout: 8),
                "The sidebar column should always show the mailbox root",
                file: file,
                line: line
            )
            let allTrips = app.buttons["mailboxAllTrips"].firstMatch
            XCTAssertTrue(allTrips.waitForExistence(timeout: 8), file: file, line: line)
            // The direct analogue of the Mac bug where a .bottomBar group laid
            // an invisible UIToolbar across the sidebar and made every row
            // unclickable. Existence alone would not have caught it.
            XCTAssertTrue(
                allTrips.isHittable,
                "Sidebar rows must be clickable",
                file: file,
                line: line
            )
            XCTAssertTrue(
                app.buttons["sidebarSettingsRow"].exists,
                "The split shell reaches Settings through the sidebar footer row",
                file: file,
                line: line
            )
            XCTAssertFalse(
                app.buttons["settingsButton"].exists,
                "The sidebar's toolbar gear is dead furniture on the Mac and must not render",
                file: file,
                line: line
            )
        }
    }

    func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, element.exists {
            usleep(100_000)
        }
        return !element.exists
    }

    /// Pops the top of the stack.
    ///
    /// Meaningless in the split shell, where the content column is the root of
    /// its own stack and has no back button — so this fails loudly there rather
    /// than tapping whatever button happens to be indexed first.
    func tapBack(from navBarTitle: String, file: StaticString = #filePath, line: UInt = #line) {
        guard shell == .stack else {
            XCTFail(
                "tapBack has no meaning in the split shell — the content column "
                + "and reading pane are roots without Back levels. Select a "
                + "different scope or trip instead.",
                file: file,
                line: line
            )
            return
        }
        let back = app.navigationBars[navBarTitle].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 4), file: file, line: line)
        XCTAssertTrue(back.isHittable, file: file, line: line)
        back.tap()
    }

    var tripDetailScreenMarker: XCUIElement {
        app.descendants(matching: .any)["tripDetailDistanceSummary"].firstMatch
    }

    /// Passive tagged rows intentionally are not Button views: Button
    /// activation consumes a click before the native List selection can see
    /// it. Query by identifier and tap a coordinate inside the row so pointer
    /// tests exercise the List's own interaction path.
    var driveCards: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "driveCard")
    }

    func tapDriveCard(
        _ card: XCUIElement,
        modifiers: XCUIElement.KeyModifierFlags = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(card.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(card.isHittable, file: file, line: line)
        let coordinate = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        if modifiers.isEmpty {
            coordinate.tap()
        } else {
            XCUIElement.perform(withKeyModifiers: modifiers) {
                coordinate.tap()
            }
        }
    }

    /// The destination is the stable trip-identity marker in the detail pane.
    /// The seeded UI-test trips end at `Client` and `Home`, so this distinguishes
    /// a real A → B replacement from a generic Trip Detail screen surviving.
    var tripDetailDestinationMarker: XCUIElement {
        app.descendants(matching: .any)["tripDetailRouteDestination"].firstMatch
    }

    /// The app records resolved reading-pane values under --uitesting. Unlike
    /// polling the rendered placeholder, this cannot miss a one-frame empty
    /// presentation between peer trips.
    var readingPanePresentationTrace: [String] {
        let marker = app.descendants(matching: .any)["readingPanePresentationTrace"].firstMatch
        guard marker.waitForExistence(timeout: 4), let value = marker.value as? String else {
            return []
        }
        return value.split(separator: "|").map(String.init)
    }

    func assertImmediateTripReplacementTrace(
        after baseline: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let originalTrip = baseline.last, originalTrip.hasPrefix("trip:") else {
            XCTFail("Trace did not end at the original trip: \(baseline)", file: file, line: line)
            return
        }

        var trace = readingPanePresentationTrace
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline,
              (trace.count <= baseline.count || trace.last == originalTrip) {
            usleep(20_000)
            trace = readingPanePresentationTrace
        }

        XCTAssertGreaterThan(trace.count, baseline.count, "No replacement was recorded", file: file, line: line)
        let replacement = Array(trace.dropFirst(baseline.count))
        XCTAssertEqual(
            replacement.count,
            1,
            "A peer replacement must be one presentation update: \(replacement)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            replacement.last?.hasPrefix("trip:") == true && replacement.last != originalTrip,
            "The replacement must resolve directly to a different trip: \(replacement)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            replacement.contains("empty"),
            "A peer replacement must never expose the placeholder: \(replacement)",
            file: file,
            line: line
        )
    }

    @discardableResult
    func waitForTripDetail(timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tripDetailScreenMarker.exists {
                return true
            }
            usleep(100_000)
        }
        return tripDetailScreenMarker.exists
    }

    /// Waits for an exact seeded-trip identity while sampling a state that must
    /// never appear during the replacement. This catches a placeholder that
    /// survives long enough to be presented after the initiating tap. A truly
    /// frame-transient state still requires an app-side transition trace.
    @discardableResult
    func waitForTripDetailDestination(
        _ destination: String,
        timeout: TimeInterval = 8,
        forbidding forbiddenElement: XCUIElement? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if forbiddenElement?.exists == true {
                XCTFail(
                    "Forbidden detail-pane state appeared while waiting for \(destination)",
                    file: file,
                    line: line
                )
                return false
            }
            if tripDetailDestinationMarker.exists,
               tripDetailDestinationMarker.label == destination {
                return true
            }
            usleep(20_000)
        }
        return tripDetailDestinationMarker.exists
            && tripDetailDestinationMarker.label == destination
    }

    func tapBackFromTripDetail(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForTripDetail(), file: file, line: line)
        guard shell == .stack else {
            XCTFail(
                "tapBackFromTripDetail has no meaning in the split shell — a "
                    + "trip is the reading-pane root, not a pushed destination.",
                file: file,
                line: line
            )
            return
        }

        let back = navigationBar(in: .detail, file: file, line: line).buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 4), file: file, line: line)
        XCTAssertTrue(back.isHittable, file: file, line: line)
        back.tap()
    }

    /// Opens Settings by whichever affordance this shell actually renders.
    ///
    /// The stack has a toolbar gear; the split shell deliberately does not —
    /// on the Mac that toolbar sits in the window titlebar and never delivers
    /// clicks, so Settings arrives through the sidebar footer row and Cmd-comma.
    /// Each branch also asserts the OTHER shell's affordance is absent, which
    /// is what catches a regression in those gates.
    func openSettingsFromTripsList(file: StaticString = #filePath, line: UInt = #line) {
        let opener: XCUIElement
        switch shell {
        case .stack:
            opener = app.buttons["settingsButton"].firstMatch
            XCTAssertFalse(
                app.buttons["sidebarSettingsRow"].exists,
                "The sidebar Settings row belongs to the split shell only",
                file: file,
                line: line
            )
        case .split:
            opener = app.buttons["sidebarSettingsRow"].firstMatch
            XCTAssertFalse(
                app.buttons["settingsButton"].exists,
                "The split shell must not render the toolbar gear",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(opener.waitForExistence(timeout: 4), file: file, line: line)
        opener.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8), file: file, line: line)
    }

    // MARK: - Shell-shaped assertions
    //
    // "Trips", "Need Review", "All Trips" and month titles are the only bar
    // titles that mean different things per shell, so they route through these
    // three helpers rather than being matched inline. Sheet titles ("Add Fee",
    // "Settings", "Vehicles"...) are identical in both shells and are left alone.

    /// Pops back until the mailbox root is fronted.
    ///
    /// A no-op in the split shell, where the sidebar is always mounted beside
    /// the other columns and there is nothing to pop.
    func popToMailboxRoot(file: StaticString = #filePath, line: UInt = #line) {
        guard shell == .stack else { return }
        var guardCount = 0
        while !app.navigationBars["Trips"].exists, guardCount < 6 {
            navigationBar(in: .detail, file: file, line: line)
                .buttons.element(boundBy: 0).tap()
            guardCount += 1
        }
        XCTAssertTrue(app.navigationBars["Trips"].waitForExistence(timeout: 6), file: file, line: line)
    }

    /// The mailbox root is showing.
    func assertMailboxRootIsShowing(file: StaticString = #filePath, line: UInt = #line) {
        switch shell {
        case .stack:
            XCTAssertTrue(
                app.navigationBars["Trips"].waitForExistence(timeout: 12),
                file: file,
                line: line
            )
        case .split:
            XCTAssertTrue(
                app.navigationBars["Trips"].waitForExistence(timeout: 8),
                "The sidebar column should always show the mailbox root",
                file: file,
                line: line
            )
        }
    }

    /// A scope is open, verified in the column that actually shows it.
    ///
    /// In the split shell this cannot be satisfied by the sidebar's own
    /// "Trips" bar, which is what a bare `app.navigationBars[title]` match
    /// would happily accept.
    func assertScopeIsOpen(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        switch shell {
        case .stack:
            // One bar at a time, so a title match IS the column-scoped check.
            // The vacuous-pass problem this helper exists for is specific to
            // the split shell, where the sidebar's own bar can satisfy a bare
            // title match while nothing was selected.
            //
            // 12s, not 8: the call sites this replaced allowed 12, and a
            // relaunch that reseeds the store needs it.
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 12),
                file: file,
                line: line
            )
        case .split:
            let bar = navigationBar(in: .list, file: file, line: line)
            XCTAssertTrue(bar.waitForExistence(timeout: 8), file: file, line: line)
            XCTAssertEqual(bar.identifier, title, file: file, line: line)
        }
    }

    /// No scope is open.
    ///
    /// In the stack that means the bar does not exist. In the split shell the
    /// content column is always mounted, so absence proves nothing — it asserts
    /// the positive no-selection marker instead, which cannot pass vacuously.
    func assertNoScopeIsOpen(_ title: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        switch shell {
        case .stack:
            if let title {
                XCTAssertFalse(app.navigationBars[title].exists, file: file, line: line)
            }
        case .split:
            XCTAssertTrue(
                app.descendants(matching: .any)["noScopeSelectedPane"].firstMatch
                    .waitForExistence(timeout: 6),
                "Expected the content column's no-selection pane",
                file: file,
                line: line
            )
        }
    }

    func advanceOnboardingToVehicle() {
        var attempts = 0
        while !app.navigationBars["Your Vehicle"].exists, attempts < 3 {
            let nextButton = app.buttons["onboardingNextButton"].firstMatch
            XCTAssertTrue(nextButton.waitForExistence(timeout: 2))
            nextButton.tap()
            attempts += 1
        }
        XCTAssertTrue(app.navigationBars["Your Vehicle"].waitForExistence(timeout: 4))
    }

    /// Pushes the newest month's screen from the Mailboxes root.
    ///
    /// Replaces the old `expandCollapsedMonthIfNeeded`
    /// pair: months used to be collapsible sections on the root and are now
    /// pushed screens. Both predecessors failed *silently* (`if …exists { tap }`
    /// and `guard exists else { return }`), which meant a broken disclosure
    /// surfaced seconds later as an unrelated missing static text — so this one
    /// asserts.
    @discardableResult
    func openNewestMonth(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let month = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")
        ).element(boundBy: 0)
        XCTAssertTrue(month.waitForExistence(timeout: 8), "No month row on the root", file: file, line: line)
        month.tap()
        return true
    }

    /// Opens the Need Review inbox from the Mailboxes root.
    ///
    /// The old verification — "a nav bar with this title exists" — is exactly
    /// the self-verifying pattern that cannot fail in a multi-column shell,
    /// where the content column already shows a scope before the tap. The
    /// column-scoped check plus scope-specific content evidence works in both.
    func openNeedsReview(file: StaticString = #filePath, line: UInt = #line) {
        let inbox = app.buttons["mailboxNeedsReview"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 8), file: file, line: line)
        inbox.tap()
        assertScopeIsOpen("Need Review", file: file, line: line)
        // Need Review is the one scope with no filter menu.
        XCTAssertFalse(app.buttons["filterDrivesMenu"].exists, file: file, line: line)
    }

    /// Opens All Trips, the scope that shows resolved and unresolved together.
    func openAllTrips(file: StaticString = #filePath, line: UInt = #line) {
        let all = app.buttons["mailboxAllTrips"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 8), file: file, line: line)
        all.tap()
        assertScopeIsOpen("All Trips", file: file, line: line)
    }

    func replaceText(in element: XCUIElement, with value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        dismissKeyboardIfNeeded()
        scrollIntoComfortableTapPosition(element)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let current = element.value as? String, !current.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        element.typeText(value)
    }

    func dismissKeyboardIfNeeded() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }

        let appDone = app.buttons["keyboardDismissDone"].firstMatch
        if appDone.exists {
            appDone.tap()
            return
        }
        let keyboardDone = app.keyboards.buttons["Done"].firstMatch
        if keyboardDone.exists {
            keyboardDone.tap()
            return
        }
        for _ in 0..<3 where keyboard.exists {
            scrollForKeyboardDismissal()
        }
    }

    func scrollIntoComfortableTapPosition(_ element: XCUIElement) {
        scrollUntilVisible(element)

        let window = app.windows.firstMatch
        guard window.exists else { return }

        var attempts = 0
        while element.exists,
              (element.frame.midY < window.frame.height * 0.28 ||
                element.frame.midY > window.frame.height * 0.68),
              attempts < 8 {
            let container = scrollContainer()
            let shouldMoveContentUp = element.frame.midY > window.frame.height * 0.68
            let startY = shouldMoveContentUp ? 0.72 : 0.42
            let endY = shouldMoveContentUp ? 0.45 : 0.62
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            start.press(forDuration: 0.1, thenDragTo: end)
            attempts += 1
        }

        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    func scrollUntilVisible(_ element: XCUIElement, direction: ScrollDirection = .up) {
        if element.exists && element.isHittable {
            return
        }

        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < 6 {
            scroll(direction)
            attempts += 1
        }
        if !element.exists || !element.isHittable {
            let reverseDirection: ScrollDirection = direction == .up ? .down : .up
            attempts = 0
            while (!element.exists || !element.isHittable) && attempts < 6 {
                scroll(reverseDirection)
                attempts += 1
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    func scrollUntilExists(_ element: XCUIElement, direction: ScrollDirection = .up) {
        if element.exists {
            return
        }

        var attempts = 0
        while !element.exists && attempts < 6 {
            scroll(direction)
            attempts += 1
        }
        if !element.exists {
            let reverseDirection: ScrollDirection = direction == .up ? .down : .up
            attempts = 0
            while !element.exists && attempts < 6 {
                scroll(reverseDirection)
                attempts += 1
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
    }

    private func scrollForKeyboardDismissal() {
        let container = scrollContainer()
        let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func scroll(_ direction: ScrollDirection) {
        switch direction {
        case .up:
            scrollContainer().swipeUp()
        case .down:
            scrollContainer().swipeDown()
        }
    }

    private func scrollContainer() -> XCUIElement {
        for identifier in [
            "onboardingForm",
            "settingsPermissionsForm",
            "settingsForm",
            "vehicleDetailForm",
            "quickTripEntryForm",
            "manualTripForm",
            "tripDetailForm"
        ] {
            let form = app.collectionViews[identifier].firstMatch
            if form.exists {
                return form
            }
        }
        let collectionView = app.collectionViews.firstMatch
        if collectionView.exists {
            return collectionView
        }
        return app
    }
}

enum ScrollDirection {
    case up
    case down
}
