import XCTest

@MainActor
final class TripEditingUITests: MileageTrackerUITestCase {
    func testTripSummaryDetailsShareCompactBottomRow() {
        waitForTripsScreen()
        openAllTrips()

        XCTAssertFalse(app.descendants(matching: .any)["driveRowReviewState"].exists)

        let businessNote = app.staticTexts["Seed business trip"].firstMatch
        let businessDistance = app.staticTexts["12.3 mi"].firstMatch
        XCTAssertTrue(businessNote.waitForExistence(timeout: 6))
        XCTAssertTrue(businessDistance.exists)
        XCTAssertEqual(businessNote.identifier, "driveRowPreview")
        XCTAssertEqual(businessNote.frame.maxX, businessDistance.frame.maxX, accuracy: 3)
        XCTAssertLessThanOrEqual(businessNote.frame.maxY, businessDistance.frame.minY + 2)

        let card = driveCards.firstMatch
        let identity = app.descendants(matching: .any)["driveRowIdentity"].firstMatch
        let timeline = app.descendants(matching: .any)["driveRowTimeline"].firstMatch
        let detailsRow = app.descendants(matching: .any)["driveRowTimelineMileageRow"].firstMatch
        let distance = app.descendants(matching: .any)["driveRowDistance"].firstMatch
        XCTAssertTrue(card.exists)
        XCTAssertTrue(identity.exists)
        XCTAssertTrue(timeline.exists)
        XCTAssertTrue(detailsRow.exists)
        XCTAssertTrue(distance.exists)
        XCTAssertFalse(identity.frame.isEmpty)
        XCTAssertFalse(detailsRow.frame.isEmpty)
        XCTAssertEqual(timeline.frame.minX, identity.frame.minX, accuracy: 4)
        XCTAssertLessThanOrEqual(timeline.frame.maxX, distance.frame.minX)
        XCTAssertEqual(timeline.frame.maxY, distance.frame.maxY, accuracy: 3)
        XCTAssertEqual(timeline.frame.height, distance.frame.height, accuracy: 2)
        XCTAssertTrue(card.frame.insetBy(dx: -2, dy: -2).contains(detailsRow.frame))
        XCTAssertTrue(detailsRow.frame.insetBy(dx: -2, dy: -2).contains(timeline.frame))
        XCTAssertTrue(detailsRow.frame.insetBy(dx: -2, dy: -2).contains(distance.frame))
        XCTAssertEqual(
            detailsRow.frame.maxY,
            identity.frame.maxY,
            accuracy: 3,
            "The compact details row should finish at the bottom of the thumbnail-height text column"
        )

        app.staticTexts["Home → Client"].firstMatch.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))

        let detailNote = app.descendants(matching: .any)["tripDetailPreview"].firstMatch
        let detailDistance = app.descendants(matching: .any)["tripDetailDistanceSummary"].firstMatch
        XCTAssertTrue(detailNote.waitForExistence(timeout: 6))
        XCTAssertEqual(detailNote.label, "Seed business trip")
        XCTAssertTrue(detailDistance.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["tripDetailReviewState"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["tripDetailDesignation"].exists)
        XCTAssertLessThanOrEqual(detailNote.frame.maxX, detailDistance.frame.maxX)
        XCTAssertLessThanOrEqual(detailNote.frame.maxY, detailDistance.frame.minY + 3)
    }

    func testTripDetailMapChrome() {
        relaunch(arguments: [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-unresolved-mix",
            "--skip-onboarding",
            "--test-store-suffix=trip-detail-map-chrome"
        ])

        waitForTripsScreen()
        openNeedsReview()
        let firstTrip = driveCards.firstMatch
        XCTAssertTrue(firstTrip.waitForExistence(timeout: 6))
        tapDriveCard(firstTrip)
        XCTAssertTrue(waitForTripDetail(timeout: 6))
        XCTAssertFalse(app.staticTexts["Trip Detail"].isHittable)

        let expandMap = app.buttons["routeMapExpandButton"]
        let detailSummary = app.descendants(matching: .any)["tripDetailDistanceSummary"]
        XCTAssertTrue(expandMap.waitForExistence(timeout: 4))
        XCTAssertTrue(expandMap.isHittable)
        XCTAssertTrue(detailSummary.waitForExistence(timeout: 4))
        // Accessibility rounds the 44-point frame to physical pixels.
        XCTAssertGreaterThanOrEqual(expandMap.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(expandMap.frame.height, 43.5)
        XCTAssertGreaterThan(expandMap.frame.minY, navigationBar(in: .detail).frame.maxY)
        XCTAssertGreaterThan(expandMap.frame.midX, app.frame.midX)
        XCTAssertLessThan(expandMap.frame.maxY, detailSummary.frame.minY)

        let form = app.descendants(matching: .any)["tripDetailForm"].firstMatch
        let preview = form.images["routeMapSnapshot"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "The detail must show a rendered, cached image")
        XCTAssertEqual(app.maps.count, 0, "The collapsed detail must not construct a live map")
        XCTAssertEqual(preview.frame.minX, form.frame.minX, accuracy: 2)
        XCTAssertEqual(preview.frame.maxX, form.frame.maxX, accuracy: 2)
        XCTAssertLessThan(preview.frame.minY, navigationBar(in: .detail).frame.maxY)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Trip Detail full bleed map - top"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let initialSummaryY = detailSummary.frame.minY
        let initialMapY = preview.frame.minY
        for (distance, name) in [(120.0, "blurred"), (150.0, "faded")] {
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
            if name == "blurred" {
                XCTAssertEqual(
                    preview.frame.minY, initialMapY, accuracy: 3,
                    "The map should stay anchored while the summary scrolls over it"
                )
            }
            let scrolled = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            let stage = shell == .split && name == "faded" ? "scroll limit" : name
            scrolled.name = "Trip Detail full bleed map - \(stage)"
            scrolled.lifetime = .keepAlways
            add(scrolled)
        }
        // A tall iPad can reach the bottom of this fixture before the header
        // has travelled as far as it does on a phone.
        XCTAssertLessThan(detailSummary.frame.minY, initialSummaryY - (shell == .split ? 100 : 180))
        // Returning to the top also proves the map and its expand control
        // recover after the visual effect has faded the image away.
        for _ in 0..<3 where detailSummary.frame.minY < initialSummaryY - 4 {
            form.swipeDown()
        }
        XCTAssertTrue(expandMap.isHittable)
        expandMap.tap()
        XCTAssertTrue(app.navigationBars["Route Map"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 6))
        app.maps.firstMatch.pinch(withScale: 1.5, velocity: 1)
        app.buttons["expandedRouteMapDone"].tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))
    }

    func testTripDetailCompactClassificationAndTripNavigation() {
        relaunch(arguments: [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-unresolved-mix",
            "--skip-onboarding",
            "--test-store-suffix=trip-detail-compact-actions"
        ])

        waitForTripsScreen()
        openNeedsReview()
        let firstTrip = driveCards.firstMatch
        XCTAssertTrue(firstTrip.waitForExistence(timeout: 6))
        tapDriveCard(firstTrip)
        XCTAssertTrue(waitForTripDetail(timeout: 6))
        XCTAssertFalse(app.staticTexts["Trip Detail"].isHittable)

        let expandMap = app.buttons["routeMapExpandButton"]
        XCTAssertTrue(expandMap.waitForExistence(timeout: 4))
        let detailSummary = app.descendants(matching: .any)["tripDetailDistanceSummary"]
        XCTAssertTrue(detailSummary.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(expandMap.frame.minY, navigationBar(in: .detail).frame.maxY)
        XCTAssertGreaterThan(expandMap.frame.midX, app.frame.midX)
        XCTAssertLessThan(expandMap.frame.maxY, detailSummary.frame.minY)
        expandMap.tap()
        XCTAssertTrue(app.navigationBars["Route Map"].waitForExistence(timeout: 6))
        app.buttons["expandedRouteMapDone"].tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))

        let business = app.buttons["tripDetailClassificationbusiness"]
        let personal = app.buttons["tripDetailClassificationpersonal"]
        let more = app.buttons["tripDetailClassificationMore"]
        XCTAssertTrue(business.waitForExistence(timeout: 4))
        XCTAssertTrue(personal.exists)
        XCTAssertTrue(more.exists)
        XCTAssertFalse(more.isSelected)
        XCTAssertEqual(more.value as? String, "Not Classified")
        XCTAssertGreaterThanOrEqual(more.frame.width, 44)
        let newPurpose = app.buttons["tripDetailNewPurpose"]
        XCTAssertFalse(newPurpose.exists)

        more.tap()
        var notClassified = app.buttons["tripDetailClassificationNotClassified"]
        var notADrive = app.buttons["tripDetailClassificationnotADrive"]
        XCTAssertTrue(notClassified.waitForExistence(timeout: 4))
        XCTAssertTrue(notADrive.exists)
        XCTAssertTrue(notClassified.isSelected)
        XCTAssertFalse(notADrive.isSelected)
        notClassified.tap()

        business.tap()
        XCTAssertFalse(more.isSelected)
        XCTAssertTrue(newPurpose.waitForExistence(timeout: 4))

        more.tap()
        notClassified = app.buttons["tripDetailClassificationNotClassified"]
        notADrive = app.buttons["tripDetailClassificationnotADrive"]
        XCTAssertTrue(notClassified.waitForExistence(timeout: 4))
        XCTAssertTrue(notADrive.exists)
        XCTAssertFalse(notClassified.isSelected)
        XCTAssertFalse(notADrive.isSelected)
        notADrive.tap()
        XCTAssertTrue(more.isSelected)
        XCTAssertEqual(more.value as? String, "Not a Drive")
        XCTAssertFalse(newPurpose.waitForExistence(timeout: 1))

        more.tap()
        notClassified = app.buttons["tripDetailClassificationNotClassified"]
        notADrive = app.buttons["tripDetailClassificationnotADrive"]
        XCTAssertTrue(notADrive.waitForExistence(timeout: 4))
        XCTAssertFalse(notClassified.isSelected)
        XCTAssertTrue(notADrive.isSelected)
        notClassified.tap()
        XCTAssertEqual(more.value as? String, "Not Classified")

        personal.tap()
        XCTAssertTrue(personal.isSelected)
        XCTAssertFalse(more.isSelected)

        let distance = app.textFields["tripDetailDistance"]
        scrollUntilVisible(distance)
        replaceText(in: distance, with: "7.70")
        dismissKeyboardIfNeeded()

        XCTAssertFalse(app.buttons["tripDetailSaveAndAdvance"].exists)

        let export = app.buttons["tripDetailExportPDF"]
        let previousTrip = app.buttons["tripDetailPreviousTrip"]
        let nextTrip = app.buttons["tripDetailNextTrip"]
        XCTAssertTrue(export.waitForExistence(timeout: 4))
        XCTAssertTrue(previousTrip.waitForExistence(timeout: 4))
        XCTAssertFalse(previousTrip.isEnabled)
        XCTAssertTrue(nextTrip.waitForExistence(timeout: 4))
        XCTAssertTrue(nextTrip.isEnabled)
        XCTAssertEqual(nextTrip.label, "Next Trip")
        let form = app.descendants(matching: .any)["tripDetailForm"].firstMatch
        XCTAssertGreaterThan(previousTrip.frame.minX, form.frame.midX)
        XCTAssertGreaterThan(nextTrip.frame.minX, previousTrip.frame.minX)
        XCTAssertEqual(previousTrip.frame.midY, nextTrip.frame.midY, accuracy: 2)
        XCTAssertGreaterThan(nextTrip.frame.minY, app.frame.maxY - 120)
        XCTAssertLessThanOrEqual(nextTrip.frame.maxY, app.frame.maxY)
        XCTAssertGreaterThan(previousTrip.frame.minY, export.frame.maxY)
        // iOS 27 can report the visible floating toolbar as not hittable
        // after keyboard dismissal. Tap its verified onscreen center and
        // assert the resulting trip and preserved edit below.
        nextTrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(waitForTripDetail(timeout: 6))
        XCTAssertTrue(app.staticTexts["Franklin Park Conservatory"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["tripDetailPreviousTrip"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["tripDetailPreviousTrip"].isEnabled)

        tapBackFromTripDetail()
        assertScopeIsOpen("Need Review")
        tapBack(from: "Need Review")
        assertMailboxRootIsShowing()
        openAllTrips()

        let savedTrip = app.staticTexts["COSI → North Market"]
        XCTAssertTrue(savedTrip.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["7.7 mi"].exists)
        savedTrip.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))
        XCTAssertTrue(app.buttons["tripDetailClassificationpersonal"].isSelected)
    }

    func testSelectedLocationAppearsOnMainMapBeforeRouteExists() {
        waitForTripsScreen()
        openAllTrips()
        app.buttons["listAddTripButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 4))

        // Destination first proves the map does not require an origin or route.
        replaceText(in: app.textFields["manualTripDestination"], with: "Grand Central")
        let result = app.buttons["tripEndpointCompletion-GrandCentralTerminal"]
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        result.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4))

        let mainMap = app.descendants(matching: .any)["tripDetailMainMap"].firstMatch
        scrollUntilVisible(mainMap, direction: .down)
        XCTAssertTrue(mainMap.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["routeEndpoint-destination"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["routeEndpoint-origin"].firstMatch.exists)
        XCTAssertFalse(app.buttons["manualTripSave"].isEnabled)
        XCTAssertFalse(app.buttons["routeMapDeleteButton"].exists)
        XCTAssertFalse(app.buttons["tripEndpointSearchUse"].exists)
        XCTAssertTrue(app.navigationBars["Add Trip"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Selected destination on main map before route"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        replaceText(in: app.textFields["manualTripOrigin"], with: "World Trade")
        let origin = app.buttons["tripEndpointCompletion-WorldTradeCenter"]
        XCTAssertTrue(origin.waitForExistence(timeout: 4))
        origin.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["manualTripSave"].isEnabled)
        XCTAssertFalse(app.buttons["routeMapDeleteButton"].exists)
        scrollUntilVisible(mainMap, direction: .down)
        // Resolving both endpoints replaces the live single-pin preview with
        // a cached route image. Verify its endpoints in the expanded map.
        XCTAssertTrue(mainMap.images["routeMapSnapshot"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(app.maps.count, 0)
        let expand = app.buttons["routeMapExpandButton"]
        scrollUntilVisible(expand, direction: .down)
        expand.tap()
        XCTAssertTrue(app.navigationBars["Route Map"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["routeEndpoint-origin"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["routeEndpoint-destination"].firstMatch.exists)
        app.buttons["expandedRouteMapDone"].tap()
        XCTAssertTrue(app.buttons["manualTripSave"].isEnabled)
    }

    func testInlineEndpointSearchCreatesAndEditsTripWithoutPicker() {
        waitForTripsScreen()
        openAllTrips()
        let addTrip = app.buttons["listAddTripButton"].firstMatch
        XCTAssertTrue(addTrip.waitForExistence(timeout: 4))
        addTrip.tap()
        XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 4))

        let origin = app.textFields["manualTripOrigin"]
        app.buttons["manualTripOriginSearch"].tap()
        origin.typeText("World Trade")
        let worldTrade = app.buttons["tripEndpointCompletion-WorldTradeCenter"]
        XCTAssertTrue(worldTrade.waitForExistence(timeout: 4))
        XCTAssertTrue(origin.isHittable)
        XCTAssertLessThanOrEqual(worldTrade.frame.maxY, app.collectionViews["manualTripForm"].frame.maxY)
        XCTAssertLessThanOrEqual(worldTrade.frame.maxY, app.buttons["keyboardDismissDone"].frame.minY)
        XCTAssertFalse(app.otherElements["tripEndpointSearchMap"].exists)
        XCTAssertFalse(app.buttons["tripEndpointSearchUse"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inline origin search in Add Trip"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        worldTrade.tap()
        XCTAssertEqual(origin.value as? String, "World Trade Center")

        replaceText(in: app.textFields["manualTripDestination"], with: "Grand Central")
        let grandCentral = app.buttons["tripEndpointCompletion-GrandCentralTerminal"]
        XCTAssertTrue(grandCentral.waitForExistence(timeout: 4))
        grandCentral.tap()
        XCTAssertEqual(app.textFields["manualTripDestination"].value as? String, "Grand Central Terminal")
        XCTAssertFalse(app.buttons["tripEndpointSearchUse"].exists)
        XCTAssertTrue(app.buttons["manualTripSave"].isEnabled)
        XCTAssertFalse(app.buttons["routeMapDeleteButton"].exists)
        let save = app.buttons["manualTripSave"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let savedTrip = app.staticTexts["World Trade Center → Grand Central Terminal"].firstMatch
        XCTAssertTrue(savedTrip.waitForExistence(timeout: 6))
        savedTrip.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))

        let detailDestination = app.textFields["tripDetailDestination"]
        scrollUntilVisible(detailDestination)
        replaceText(in: detailDestination, with: "World Trade")
        XCTAssertTrue(worldTrade.waitForExistence(timeout: 4))
        XCTAssertTrue(detailDestination.isHittable)
        XCTAssertLessThanOrEqual(worldTrade.frame.maxY, app.buttons["keyboardDismissDone"].frame.minY)
        XCTAssertFalse(app.buttons["tripEndpointSearchUse"].exists)
        let destinationScreenshot = XCTAttachment(screenshot: app.screenshot())
        destinationScreenshot.name = "Inline destination search in Trip Detail"
        destinationScreenshot.lifetime = .keepAlways
        add(destinationScreenshot)
        worldTrade.tap()
        XCTAssertEqual(detailDestination.value as? String, "World Trade Center")

        let detailOrigin = app.textFields["tripDetailOrigin"]
        replaceText(in: detailOrigin, with: "Grand Central")
        XCTAssertTrue(grandCentral.waitForExistence(timeout: 4))
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Inline origin search in Trip Detail"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
        grandCentral.tap()
        XCTAssertEqual(detailOrigin.value as? String, "Grand Central Terminal")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4))
        if shell == .stack {
            // The hero is off-screen after inline search; use the visible toolbar.
            let back = navigationBar(in: .detail).buttons.element(boundBy: 0)
            XCTAssertTrue(back.isHittable)
            back.tap()
        } else {
            openNewestMonth()
            openAllTrips()
        }
        XCTAssertTrue(app.staticTexts["Grand Central Terminal → World Trade Center"].firstMatch.waitForExistence(timeout: 6))
    }

    func testInlineEndpointSearchClearsSuggestionsWhenSwitchingFields() {
        waitForTripsScreen()
        openAllTrips()
        tapDriveCard(driveCards.firstMatch)
        XCTAssertTrue(waitForTripDetail(timeout: 6))

        let origin = app.textFields["tripDetailOrigin"]
        scrollUntilVisible(origin)
        replaceText(in: origin, with: "World Trade")
        let worldTrade = app.buttons["tripEndpointCompletion-WorldTradeCenter"]
        XCTAssertTrue(worldTrade.waitForExistence(timeout: 4))
        // The destination row may sit beneath the keyboard accessory while
        // Origin has completions. Use the native next-field control to move
        // focus without dismissing the keyboard (which also clears results).
        let nextField = app.buttons["keyboardNextField"]
        XCTAssertTrue(nextField.isHittable)
        nextField.tap()
        XCTAssertFalse(worldTrade.exists)
        XCTAssertFalse(app.buttons["tripEndpointSearchUse"].exists)
        XCTAssertTrue(origin.exists)

        let destination = app.textFields["tripDetailDestination"]
        replaceText(in: destination, with: "No matching fixture")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 4))
        XCTAssertFalse(worldTrade.exists)
        replaceText(in: destination, with: "")
        XCTAssertFalse(app.staticTexts["No Results"].exists)
        replaceText(in: destination, with: "Grand Central")
        XCTAssertTrue(app.buttons["tripEndpointCompletion-GrandCentralTerminal"].waitForExistence(timeout: 4))
        dismissKeyboardIfNeeded()
        XCTAssertFalse(app.buttons["tripEndpointCompletion-GrandCentralTerminal"].exists)
    }

    func testManualTripAddEditDeleteUsesDisposableData() {
        waitForTripsScreen()

        // Add Trip is a root toolbar item, so this stays on the Mailboxes root.
        app.buttons["addTripButton"].tap()
        XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 4))
        replaceText(in: app.textFields["manualTripOrigin"], with: "World Trade")
        let originSuggestion = app.buttons["tripEndpointCompletion-WorldTradeCenter"]
        XCTAssertTrue(originSuggestion.waitForExistence(timeout: 4))
        originSuggestion.tap()

        replaceText(in: app.textFields["manualTripDestination"], with: "Grand Central")
        let destinationSuggestion = app.buttons["tripEndpointCompletion-GrandCentralTerminal"]
        XCTAssertTrue(destinationSuggestion.waitForExistence(timeout: 4))
        destinationSuggestion.tap()

        XCTAssertFalse(app.buttons["routeMapDeleteButton"].exists)
        XCTAssertTrue(app.buttons["manualTripSave"].isEnabled)

        dismissKeyboardIfNeeded()
        let addFeeButton = app.buttons["manualTripAddFee"].firstMatch
        scrollUntilVisible(addFeeButton)
        addFeeButton.tap()
        XCTAssertTrue(app.navigationBars["Add Fee"].waitForExistence(timeout: 4))
        replaceText(in: app.textFields["feeEntryAmount"], with: "3.25")
        replaceText(in: app.textFields["feeEntryLabel"], with: "Bridge")
        dismissKeyboardIfNeeded()
        app.buttons["feeEntrySave"].tap()
        XCTAssertTrue(app.navigationBars["Add Trip"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Bridge"].waitForExistence(timeout: 4))

        dismissKeyboardIfNeeded()
        let saveTrip = app.buttons["manualTripSave"]
        XCTAssertTrue(saveTrip.waitForExistence(timeout: 4))
        XCTAssertTrue(saveTrip.isHittable)
        saveTrip.tap()

        // The trip defaults to Business, so it lands in its (collapsed) month
        // section rather than the Need Review inbox — open the month to see it.
        openNewestMonth()
        XCTAssertTrue(app.staticTexts["World Trade Center → Grand Central Terminal"].waitForExistence(timeout: 4))

        app.staticTexts["World Trade Center → Grand Central Terminal"].tap()
        XCTAssertTrue(waitForTripDetail(timeout: 4))
        scrollUntilVisible(app.staticTexts["Bridge"])
        XCTAssertTrue(app.staticTexts["$3.25"].exists)
        scrollUntilVisible(app.textFields["tripDetailDistance"])
        replaceText(in: app.textFields["tripDetailDistance"], with: "6.40")
        dismissKeyboardIfNeeded()
        scrollUntilVisible(app.descendants(matching: .any)["tripDetailDistanceSummary"].firstMatch, direction: .down)
        tapBackFromTripDetail()

        XCTAssertTrue(app.staticTexts["World Trade Center → Grand Central Terminal"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["6.4 mi"].waitForExistence(timeout: 4))

        app.staticTexts["World Trade Center → Grand Central Terminal"].tap()
        XCTAssertTrue(waitForTripDetail(timeout: 4))

        // The detail map offers expand (fullscreen), never delete.
        XCTAssertFalse(app.buttons["routeMapDeleteButton"].exists)
        let expandMap = app.buttons["routeMapExpandButton"].firstMatch
        XCTAssertTrue(expandMap.waitForExistence(timeout: 4))
        expandMap.tap()
        let expandedMapDone = app.buttons["expandedRouteMapDone"].firstMatch
        XCTAssertTrue(expandedMapDone.waitForExistence(timeout: 4))
        expandedMapDone.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 4))

        scrollIntoComfortableTapPosition(app.buttons["tripDetailDelete"])
        app.buttons["tripDetailDelete"].tap()
        let confirmDelete = app.buttons["confirmTripDelete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 4))
        confirmDelete.tap()

        XCTAssertFalse(app.staticTexts["World Trade Center → Grand Central Terminal"].waitForExistence(timeout: 2))

        // Deleting pops back to the month the trip lived in, so the seeded May
        // trip is a screen away now rather than in the same flat list. Check it
        // through All Trips, which spans every month.
        popToMailboxRoot()
        openAllTrips()
        XCTAssertTrue(app.staticTexts["Home → Client"].waitForExistence(timeout: 6))
    }
}

extension TripEditingUITests {
    func testDetailMapWarmsBeforeOpeningAndReusesSnapshot() {
        relaunch(arguments: ["--uitesting", "--uitesting-mapkit-fixtures", "--reset-data",
            "--reset-preferences", "--seed-unresolved-mix", "--skip-onboarding",
            "--uitesting-map-warming-probe", "--test-store-suffix=foreground-map-warming"])
        waitForTripsScreen()
        openAllTrips()
        let status = app.staticTexts["mapWarmingStatus"]
        func value(_ name: String) -> Int {
            let field = status.label.split(separator: ";").first { $0.hasPrefix("\(name)=") }
            return field.flatMap { Int($0.split(separator: "=").last ?? "") } ?? 0
        }
        let warmed = NSPredicate { _, _ in
            status.exists && status.label.contains("ready=true") && value("prepared") > 0
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: warmed, object: nil)], timeout: 90), .completed, status.exists ? status.label : "No warming probe")
        let rendersBeforeOpening = value("renders")
        XCTAssertEqual(value("hits"), 0, "No detail map has appeared yet")
        let card = driveCards.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 6))
        tapDriveCard(card)
        XCTAssertTrue(waitForTripDetail(timeout: 6))
        XCTAssertEqual(value("navigationHits"), 1, "A disk-cached detail image must be prepared before the stack push")
        let hit = NSPredicate { _, _ in value("hits") > 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hit, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(app.images["routeMapSnapshot"].firstMatch.exists)
        XCTAssertEqual(value("renders"), rendersBeforeOpening, "Opening a warmed detail must not render another hero")
    }
}
