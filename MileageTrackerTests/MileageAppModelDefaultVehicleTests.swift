import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// Covers the "every configured iPhone/iPad install owns at least one vehicle"
/// invariant: the default-vehicle backfill at launch, onboarding completion,
/// and the protected-data (locked launch) path.
@MainActor
final class MileageAppModelDefaultVehicleTests: XCTestCase {
    private func makeModel(_ extra: [String], override: Bool? = nil) throws -> MileageAppModel {
        MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting"] + extra),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: override
        )
    }

    func testIOSSkipOnboardingBackfillsSingleDefaultVehicle() async throws {
        let model = try makeModel(["--reset-data", "--reset-preferences", "--skip-onboarding"])

        await model.startup()

        XCTAssertEqual(model.vehicles.count, 1)
        XCTAssertEqual(model.vehicles.first?.name, "My Car")
        XCTAssertEqual(model.primaryVehicleID, model.vehicles.first?.id)

        // A second launch pass must not create a duplicate.
        await model.startup()
        XCTAssertEqual(model.vehicles.count, 1)
    }

    func testSeededVehiclesWinOverDefaultBackfill() async throws {
        let model = try makeModel([
            "--reset-data", "--reset-preferences", "--skip-onboarding", "--seed-vehicles"
        ])

        await model.startup()

        XCTAssertEqual(model.vehicles.count, 2)
        XCTAssertFalse(model.vehicles.contains { $0.name == "My Car" })
    }

    func testOnboardingCompletionCreatesVehicleAndAdoptsReading() async throws {
        let model = try makeModel(["--reset-data", "--reset-preferences", "--reset-onboarding"])

        await model.startup()
        // Onboarding not complete → no vehicle yet.
        XCTAssertTrue(model.vehicles.isEmpty)

        // The onboarding odometer field saves with a nil vehicleID before the
        // vehicle exists; completing onboarding must create the primary and the
        // reading must resolve to it.
        model.addOdometerCheckpoint(50_000)
        model.completeOnboarding()

        XCTAssertEqual(model.vehicles.count, 1)
        let primary = try XCTUnwrap(model.primaryVehicleID)
        XCTAssertEqual(model.latestOdometerCheckpoint(for: primary)?.odometerMiles, 50_000)
    }

    func testDefaultVehicleDeferredUntilProtectedDataUnlocks() async throws {
        let model = try makeModel(["--skip-onboarding"], override: false)

        // Awaiting protected data: no vehicle is created on the in-memory
        // placeholder store (it would vanish when the real store loads).
        XCTAssertTrue(model.isAwaitingProtectedData)
        XCTAssertTrue(model.vehicles.isEmpty)

        // Simulates protectedDataDidBecomeAvailable — the real store opens and
        // the backfill runs.
        await model.reloadPersistenceForProtectedData()
        XCTAssertFalse(model.isAwaitingProtectedData)
        XCTAssertEqual(model.vehicles.count, 1)
        XCTAssertEqual(model.vehicles.first?.name, "My Car")
    }
}
