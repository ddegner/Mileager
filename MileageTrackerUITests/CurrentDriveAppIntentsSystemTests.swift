// AppIntentsTesting itself loads iOS 27-only private support frameworks.
// Keep this opt-in system suite out of the iOS 26-compatible UI runner.
// Enable with -D APP_INTENTS_SYSTEM_TESTS when targeting an iOS 27 simulator.
#if canImport(AppIntentsTesting) && APP_INTENTS_SYSTEM_TESTS
import AppIntentsTesting
import XCTest

/// iOS 27 system-level coverage. These tests do not link Mileager's intent
/// types; they discover and execute the installed app's metadata out of process,
/// matching Siri and Shortcuts much more closely than the hosted unit tests.
@available(iOS 27.0, *)
@MainActor
final class CurrentDriveAppIntentsSystemTests: MileageTrackerUITestCase {
    private let definitions = IntentDefinitions(
        bundleIdentifier: "com.daviddegner.MileageTracker"
    )

    override var launchArguments: [String] {
        super.launchArguments + ["--seed-current-drive", "--test-store-suffix=siri-system-contracts"]
    }

    private func appIntentsOperation<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            let error = error as NSError
            guard error.domain == "AppIntentsServicesSecurityErrorDomain", error.code == 803 else {
                throw error
            }
            throw XCTSkip(
                "This OS build blocks AppIntentsTesting on Customer OS builds. "
                    + "Run this suite on a build where Apple enables the testing service."
            )
        }
    }

    func testCurrentDriveEntityIsQueryableAndAnnotatesVisibleBar() async throws {
        waitForTripsScreen()
        XCTAssertTrue(app.buttons["currentDriveBarToll"].waitForExistence(timeout: 8))

        let entityDefinition = definitions.entities["CurrentDriveAppEntity"]
        let suggested = try await appIntentsOperation {
            try await entityDefinition.suggestedEntities()
        }
        XCTAssertEqual(suggested.count, 1)

        let optedOutAnnotations = try await appIntentsOperation {
            try await entityDefinition.viewAnnotations()
        }
        XCTAssertTrue(optedOutAnnotations.isEmpty)

        // UI fixtures start with Siri & Search disabled, just like a new
        // install. Exercise the actual opt-in before expecting annotations.
        openSettingsFromTripsList()
        let siriToggle = app.switches["settingsSiriIndexingToggle"].firstMatch
        scrollUntilVisible(siriToggle)
        XCTAssertEqual(siriToggle.value as? String, "0")
        siriToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(siriToggle.value as? String, "1")
        app.buttons["settingsDone"].tap()
        waitForTripsScreen()

        let annotations = try await appIntentsOperation {
            try await entityDefinition.viewAnnotations()
        }
        XCTAssertTrue(
            annotations.contains { $0.entity.identifier == suggested[0].identifier },
            "The visible current-drive bar must expose its active-drive entity to Siri."
        )

        popToMailboxRoot()
        openAllTrips()
        let tripAnnotations = try await appIntentsOperation {
            try await definitions.entities["TripAppEntity"].viewAnnotations()
        }
        XCTAssertFalse(tripAnnotations.isEmpty, "Visible completed trips must expose their entities after opt-in.")
    }

    func testCurrentDriveIntentsExecuteOutOfProcess() async throws {
        waitForTripsScreen()
        XCTAssertTrue(app.buttons["currentDriveBarToll"].waitForExistence(timeout: 8))

        let entityDefinition = definitions.entities["CurrentDriveAppEntity"]
        let suggested = try await appIntentsOperation {
            try await entityDefinition.suggestedEntities()
        }
        let drive = try XCTUnwrap(suggested.first)
        let business = definitions.enums["TripClassificationAppEnum"].makeCase("business")
        let parking = definitions.enums["TripFeeCategoryAppEnum"].makeCase("parking")

        let classify = definitions.intents["ClassifyCurrentDriveIntent"].makeIntent(
            drive: drive,
            classification: business,
            businessPurpose: "System test client visit"
        )
        _ = try await appIntentsOperation {
            try await classify.run()
        }

        let note = definitions.intents["AddCurrentDriveNoteIntent"].makeIntent(
            drive: drive,
            note: "Garage level two"
        )
        _ = try await appIntentsOperation {
            try await note.run()
        }

        let fee = definitions.intents["AddCurrentDriveFeeIntent"].makeIntent(
            drive: drive,
            category: parking,
            amount: 12.5,
            label: "Garage"
        )
        _ = try await appIntentsOperation {
            try await fee.run()
        }

        let updatedSuggestions = try await appIntentsOperation {
            try await entityDefinition.suggestedEntities()
        }
        let updated = try XCTUnwrap(updatedSuggestions.first)
        let classification: AnyAppEnum? = try updated.classification
        let purpose: String? = try updated.businessPurpose
        let notes: String? = try updated.notes
        let feeCount: Int = try updated.feeCount

        XCTAssertEqual(classification?.rawValue, "business")
        XCTAssertEqual(purpose, "System test client visit")
        XCTAssertEqual(notes, "Garage level two")
        XCTAssertEqual(feeCount, 1)
    }

    func testExpiredEntityCannotFallBackToTheNewCurrentDrive() async throws {
        waitForTripsScreen()
        let entity = definitions.entities["CurrentDriveAppEntity"]
        let before = try await appIntentsOperation { try await entity.suggestedEntities() }
        let current = try XCTUnwrap(before.first)
        let stale = entity.makeReference(identifier: UUID().uuidString)
        let category = definitions.enums["TripClassificationAppEnum"].makeCase("business")
        var returnedEntityID: String?
        do {
            let result = try await definitions.intents["ClassifyCurrentDriveIntent"].makeIntent(
                drive: stale, classification: category
            ).run()
            let returned: AnyAppEntity? = try result.value
            returnedEntityID = returned?.identifier.instanceIdentifier
        } catch {
            let error = error as NSError
            if error.domain == "AppIntentsServicesSecurityErrorDomain", error.code == 803 {
                throw XCTSkip("This OS build blocks the AppIntentsTesting service")
            }
        }
        let after = try await appIntentsOperation { try await entity.suggestedEntities() }
        let updated = try XCTUnwrap(after.first)
        let savedCategory: AnyAppEnum? = try updated.classification
        XCTAssertEqual(updated.identifier, current.identifier)
        XCTAssertNil(savedCategory, "An unresolved explicit entity must not edit the live drive")
        XCTAssertNil(returnedEntityID, "An expired reference must not return a newly classified drive")
    }

    func testCurrentDriveQueryIsEmptyWhenNoDriveIsActive() async throws {
        relaunch(arguments: [
            "--uitesting",
            "--reset-data",
            "--reset-preferences",
            "--seed-mileage-data",
            "--skip-onboarding"
        ])
        waitForTripsScreen()

        let entities = try await appIntentsOperation {
            try await definitions.entities["CurrentDriveAppEntity"].suggestedEntities()
        }
        XCTAssertTrue(entities.isEmpty)
    }

    func testSchemaOpenActionsExecuteThroughSystem() async throws {
        waitForTripsScreen()
        let current = try await appIntentsOperation {
            try await self.definitions.entities["CurrentDriveAppEntity"].suggestedEntities()
        }
        let drive = try XCTUnwrap(current.first)
        _ = try await appIntentsOperation {
            try await self.definitions.intents["OpenCurrentDriveIntent"].makeIntent(target: drive).run()
        }
        XCTAssertTrue(app.buttons["currentDriveBarToll"].waitForExistence(timeout: 8))
        let trips = try await appIntentsOperation {
            try await self.definitions.entities["TripAppEntity"].suggestedEntities()
        }
        _ = try await appIntentsOperation {
            try await self.definitions.intents["OpenTripWithSiriIntent"].makeIntent(target: XCTUnwrap(trips.first)).run()
        }
        XCTAssertTrue(waitForTripDetail(timeout: 8))
    }

    func testLastDriveDurationIntentCompletesOutOfProcess() async throws {
        waitForTripsScreen()

        _ = try await appIntentsOperation {
            try await definitions.intents["LastDriveDurationIntent"]
                .makeIntent()
                .run()
        }
    }
}
#endif
