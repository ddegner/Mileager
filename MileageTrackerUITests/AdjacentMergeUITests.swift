import XCTest

@MainActor
final class AdjacentMergeUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-app-store-screenshot-data",
            "--skip-onboarding",
            "--screenshot-locale=en-US",
            "--test-store-suffix=adjacent-merge-ui"
        ] + Self.englishLocaleArguments
    }

    func testAdjacentMergeControlMergesOnlyItsTwoRows() {
        waitForTripsScreen()

        // The screenshot fixture's deliberate split capture is in May: two
        // same-purpose business legs on May 26, separated by a few hours.
        let monthRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")
        )
        let may = monthRows.element(boundBy: 1)
        XCTAssertTrue(may.waitForExistence(timeout: 8))
        may.tap()

        // These fixture distances uniquely identify the May 26 split legs and
        // the neighboring May 28 trip. Unlike route accessibility labels, the
        // values are also the literal row text the user sees.
        let firstLeg = app.staticTexts["38.5 mi"]
        let secondLeg = app.staticTexts["38.2 mi"]
        let unrelatedTrip = app.staticTexts["59.2 mi"]
        XCTAssertTrue(app.staticTexts["9 trips"].waitForExistence(timeout: 8))

        // Newest-first order puts the evening capture above the midday one.
        let merge = mergeButton(12, 11)
        revealMerge(merge, above: firstLeg)
        XCTAssertTrue(
            merge.waitForExistence(timeout: 4),
            "The adjacent capture fixture should expose the one-tap merge control"
        )
        XCTAssertTrue(merge.isHittable)
        XCTAssertGreaterThanOrEqual(merge.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(merge.frame.height, 44 - 0.001)
        XCTAssertTrue(app.frame.contains(merge.frame))
        XCTAssertTrue(firstLeg.exists)
        XCTAssertTrue(secondLeg.exists)
        merge.tap()

        XCTAssertTrue(
            app.staticTexts["8 trips"].waitForExistence(timeout: 8),
            "Merging one adjacent pair should reduce the month by exactly one trip"
        )
        let mergedTrip = app.staticTexts["76.7 mi"]
        XCTAssertTrue(
            mergedTrip.waitForExistence(timeout: 4),
            "The merged row should contain the two May 26 legs' combined distance"
        )
        XCTAssertFalse(firstLeg.exists)
        XCTAssertFalse(secondLeg.exists)
        XCTAssertFalse(merge.exists)
        scrollUntilVisible(unrelatedTrip)
        XCTAssertTrue(
            unrelatedTrip.exists,
            "The neighboring May 28 trip must remain untouched"
        )

        scrollUntilVisible(mergedTrip)
        mergedTrip.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))

        let mainMap = app.descendants(matching: .any)["tripDetailMainMap"].firstMatch
        XCTAssertTrue(
            mainMap.images["routeMapSnapshot"].firstMatch.waitForExistence(timeout: 30),
            "The merged route must finish rendering after the source rows disappear"
        )
        let mapScreenshot = XCTAttachment(screenshot: app.screenshot())
        mapScreenshot.name = "Merged trip - rendered main map"
        mapScreenshot.lifetime = .keepAlways
        add(mapScreenshot)

        let unmerge = app.buttons["tripDetailUnmerge"]
        scrollUntilVisible(unmerge)
        XCTAssertTrue(unmerge.waitForExistence(timeout: 4))

        let legsScreenshot = XCTAttachment(screenshot: app.screenshot())
        legsScreenshot.name = "Merged trip - compact Legs rows"
        legsScreenshot.lifetime = .keepAlways
        add(legsScreenshot)

        let detailsHeader = app.staticTexts["Details"]
        scrollUntilVisible(detailsHeader)
        XCTAssertTrue(detailsHeader.waitForExistence(timeout: 4))
        XCTAssertTrue(unmerge.exists)
        XCTAssertLessThan(
            unmerge.frame.minY,
            detailsHeader.frame.minY,
            "The unmerge action should sit with the legs, before Details"
        )

        scrollUntilVisible(unmerge, direction: .down)
        unmerge.tap()
        XCTAssertTrue(app.staticTexts["9 trips"].waitForExistence(timeout: 8))
        XCTAssertTrue(firstLeg.waitForExistence(timeout: 4))
        XCTAssertTrue(secondLeg.exists)
    }

    func testCrossMonthMergeAndContextMenuUseTheSameDisplayedNeighbor() {
        waitForTripsScreen()
        openAllTrips()
        let merge = mergeButton(9, 10) // June 10 -> May 28, across the May header.
        let juneTrip = app.staticTexts["39.1 mi"]
        let mayTrip = app.staticTexts["59.2 mi"]
        revealMerge(merge, above: mayTrip)
        XCTAssertTrue(juneTrip.exists)
        XCTAssertTrue(mayTrip.exists)
        XCTAssertGreaterThanOrEqual(merge.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(merge.frame.height, 44 - 0.001)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Merge across month header"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Exercise the second entry point at that exact boundary. It must use
        // the same successor, even though it belongs to another month.
        juneTrip.press(forDuration: 1)
        // UIKit's native context menu exposes the title, but drops SwiftUI IDs.
        let menuMerge = app.buttons["Merge with Next Trip"]
        XCTAssertTrue(menuMerge.waitForExistence(timeout: 4))
        // The native context-menu snapshot can report this visible item as
        // non-hittable on iOS 27. Tap its rendered center, then verify the
        // resulting merge rather than relying on that host AX flag.
        menuMerge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let combined = app.staticTexts["98.3 mi"]
        scrollUntilVisible(combined)
        XCTAssertTrue(combined.exists)
        XCTAssertFalse(juneTrip.exists)
        XCTAssertFalse(mayTrip.exists)
        XCTAssertFalse(merge.exists)
        scrollUntilVisible(app.staticTexts["38.2 mi"])
        XCTAssertTrue(app.staticTexts["38.2 mi"].exists)
    }

    func testMixedClassificationBoundaryHidesDuringSelectionAndHasNoFinalSuccessor() {
        waitForTripsScreen()
        let may = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mailboxMonth-'")).element(boundBy: 1)
        XCTAssertTrue(may.waitForExistence(timeout: 8))
        may.tap()
        let mixed = mergeButton(17, 18) // Business -> Personal.
        let personalTrip = app.staticTexts["6.1 mi"]
        revealMerge(mixed, above: personalTrip)
        XCTAssertTrue(mixed.isHittable)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mergeAdjacentTripsButton.\(seedID(18)).")
        ).count, 0)
        app.buttons["listOptionsMenu"].tap()
        let select = app.buttons["selectTripsButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 4))
        select.tap()
        XCTAssertTrue(app.buttons["selectionDoneButton"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'mergeAdjacentTripsButton.'")
        ).firstMatch.waitForNonExistence(timeout: 4))
        app.buttons["selectionDoneButton"].tap()
        revealMerge(mixed, above: personalTrip)
        mixed.tap()
        XCTAssertTrue(app.staticTexts["8.6 mi"].waitForExistence(timeout: 4))
        XCTAssertFalse(personalTrip.exists)
        XCTAssertFalse(app.staticTexts["2.4 mi"].exists)
        XCTAssertFalse(mixed.exists)
        scrollUntilVisible(app.staticTexts["8 trips"], direction: .down)
        XCTAssertTrue(app.staticTexts["8 trips"].exists)
    }

    func testCrossMonthControlsCoexistWithOneLiveDriveBar() {
        app.terminate()
        app.launchArguments += ["--seed-current-drive"]
        app.launch()
        waitForTripsScreen()
        openAllTrips()
        let merge = mergeButton(9, 10)
        revealMerge(merge, above: app.staticTexts["59.2 mi"])
        XCTAssertTrue(merge.isHittable)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "currentDriveBar").count, 1)
        XCTAssertTrue(app.buttons["currentDriveBarToll"].isHittable)
        XCTAssertTrue(app.buttons["currentDriveBarParking"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Neighbor controls with Live Drive bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func revealMerge(_ merge: XCUIElement, above followingTrip: XCUIElement) {
        // Overlay accessibility elements can remain "hittable" outside the
        // viewport. Scroll the real list column and check physical placement.
        let list = app.collectionViews.containing(.staticText, identifier: "driveRowDistance").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 4))
        for _ in 0..<12 {
            let top = navigationBar(in: .list).frame.maxY + 8
            let liveBar = app.descendants(matching: .any)["currentDriveBar"].firstMatch
            let addTrip = app.buttons["listAddTripButton"]
            let bottom = liveBar.exists ? liveBar.frame.minY - 8
                : addTrip.exists ? addTrip.frame.minY - 8 : app.frame.maxY - 80
            if merge.exists, followingTrip.exists,
               merge.frame.minY >= top, merge.frame.maxY <= bottom,
               followingTrip.frame.maxY <= bottom, followingTrip.isHittable {
                XCTAssertTrue(merge.isHittable)
                return
            }
            // Move by the actual overflow of both controls. Fixed fractions
            // can oscillate around the target in the shorter live-bar viewport.
            XCTAssertGreaterThan(bottom, top)
            let visibleHeight = bottom - top
            let center = (top + bottom) / 2
            var movement = -visibleHeight * 0.3
            if merge.exists, followingTrip.exists {
                let bounds = merge.frame.union(followingTrip.frame)
                if bounds.minY.isFinite, bounds.maxY.isFinite {
                    if bounds.minY < top {
                        movement = top - bounds.minY + 12
                    } else if bounds.maxY > bottom {
                        movement = bottom - bounds.maxY - 12
                    } else {
                        movement = center - bounds.midY
                    }
                }
            }
            let maximumTravel = visibleHeight * 0.35
            movement = max(-maximumTravel, min(maximumTravel, movement))
            if abs(movement) < 12 { movement = movement >= 0 ? 12 : -12 }
            // Keep both endpoints inside the actual list viewport, above
            // safe-area controls, while allowing a small final adjustment.
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: list.frame.width / 2,
                dy: center - movement / 2 - list.frame.minY
            ))
            let end = origin.withOffset(CGVector(
                dx: list.frame.width / 2,
                dy: center + movement / 2 - list.frame.minY
            ))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTFail("The intended Merge control and following trip did not scroll into the visible list: merge=\(merge.frame), following=\(followingTrip.frame)")
    }

    private func seedID(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", index)
    }

    private func mergeButton(_ first: Int, _ second: Int) -> XCUIElement {
        app.buttons["mergeAdjacentTripsButton.\(seedID(first)).\(seedID(second))"]
    }
}
