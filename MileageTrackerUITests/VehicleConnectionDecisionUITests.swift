import XCTest

@MainActor
final class VehicleConnectionDecisionUITests: MileageTrackerUITestCase {
    override var launchArguments: [String] {
        super.launchArguments + [
            "--seed-vehicles",
            "--seed-vehicle-connection-decision"
        ]
    }

    func testConnectionDecisionIsConciseAndUsesSwipeForNotNow() {
        let sheet = app.otherElements["vehicleConnectionDecisionSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 12))
        XCTAssertLessThan(
            sheet.frame.height,
            app.frame.height * 0.5,
            "The iOS 26 fitted sheet should hug its controls instead of leaving a large empty tail"
        )
        XCTAssertTrue(app.staticTexts["Which car is “SUBARU BT”?"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Mileager will recognize this car automatically on future drives."
            ].exists
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SUBARU BT")).count,
            1
        )
        XCTAssertTrue(app.staticTexts["Home → Client"].exists)

        let choices = app.buttons.matching(identifier: "vehicleConnectionDecisionVehicleChoice")
        XCTAssertEqual(choices.count, 2)
        XCTAssertFalse(app.buttons["Not now"].exists)

        app.buttons["vehicleConnectionDecisionNotMyCar"].tap()
        let ignoreAlert = app.alerts["Ignore “SUBARU BT”?"]
        XCTAssertTrue(ignoreAlert.waitForExistence(timeout: 4))
        XCTAssertTrue(
            ignoreAlert.staticTexts[
                "Mileager will stop using this connection to help detect drives. You can restore it later in Settings › Vehicles."
            ].exists
        )
        ignoreAlert.buttons["Go Back"].tap()
        XCTAssertTrue(sheet.exists)

        sheet.swipeDown(velocity: .fast)
        XCTAssertFalse(sheet.waitForExistence(timeout: 2))
    }

    func testAutomaticVehicleProvenanceRowStaysCompact() {
        let sheet = app.otherElements["vehicleConnectionDecisionSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 12))

        let firstVehicle = app.buttons
            .matching(identifier: "vehicleConnectionDecisionVehicleChoice")
            .firstMatch
        XCTAssertTrue(firstVehicle.waitForExistence(timeout: 4))
        firstVehicle.tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 4))

        waitForTripsScreen()
        openAllTrips()
        let trip = app.staticTexts["Home → Client"]
        XCTAssertTrue(trip.waitForExistence(timeout: 6))
        trip.tap()
        XCTAssertTrue(waitForTripDetail(timeout: 6))

        let provenance = app.descendants(matching: .any)["tripDetailVehicleSource"].firstMatch
        scrollUntilVisible(provenance)
        XCTAssertEqual(
            provenance.label,
            "Assigned automatically from your car connection"
        )
        XCTAssertLessThan(
            provenance.frame.height,
            app.frame.height * 0.15,
            "The automatic vehicle note should use a compact form row"
        )
    }
}
