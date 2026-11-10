import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// Covers the Mac (Designed for iPhone) review/report role: capture stays
/// suppressed, tracking can never activate, and the override plumbing that
/// makes the mode testable off-Mac.
@MainActor
final class MileageAppModelPlatformTests: XCTestCase {
    private func makeModel(
        _ extra: [String] = [],
        platformOverride: RunningPlatform? = nil,
        preferences: Preferences? = nil,
        skipOnboarding: Bool = true,
        protectedDataAvailableOverride: Bool? = nil
    ) throws -> MileageAppModel {
        let onboardingArgument = skipOnboarding ? "--skip-onboarding" : "--reset-onboarding"
        return MileageAppModel(
            arguments: appModelArguments(
                ["MileageTracker", "--uitesting", "--reset-data", "--reset-preferences", onboardingArgument] + extra
            ),
            preferences: try preferences ?? Preferences(defaults: makeTestDefaults()),
            protectedDataAvailableOverride: protectedDataAvailableOverride,
            platformOverride: platformOverride
        )
    }

    func testMacModeOverrideHonored() throws {
        let macModel = try makeModel(platformOverride: .mac)
        XCTAssertEqual(macModel.platform, .mac)
        XCTAssertTrue(macModel.driveCaptureSuppressed)

        let phoneModel = try makeModel(platformOverride: .iOS)
        XCTAssertEqual(phoneModel.platform, .iOS)
        // Still suppressed under --uitesting; the predicate is the union.
        XCTAssertTrue(phoneModel.driveCaptureSuppressed)
    }

    func testStartTrackingIsNoOpInMacMode() async throws {
        // Differential: startTracking() has no isUITesting guard, so on a
        // non-Mac model it activates tracking even in automated runs. The Mac
        // guard is what must keep it inert.
        let macModel = try makeModel(platformOverride: .mac)
        await macModel.startup()
        macModel.startTracking()
        XCTAssertFalse(macModel.trackingActive)
        XCTAssertNil(macModel.bluetoothSignalService)

        let phoneModel = try makeModel(platformOverride: .iOS)
        await phoneModel.startup()
        phoneModel.startTracking()
        XCTAssertTrue(phoneModel.trackingActive)
    }

    func testMacPermissionKindsAreNotificationsOnly() throws {
        let macModel = try makeModel(platformOverride: .mac)
        XCTAssertEqual(macModel.availableTrackingPermissionKinds, [.notifications])

        let phoneModel = try makeModel(platformOverride: .iOS)
        XCTAssertEqual(phoneModel.availableTrackingPermissionKinds, TrackingPermissionKind.allCases)
    }

    func testMacCapturePermissionRequestsReturnUnavailable() async throws {
        let model = try makeModel(platformOverride: .mac)
        await model.startup()

        for kind in [TrackingPermissionKind.location, .motion, .bluetooth] {
            XCTAssertEqual(model.requestPermission(kind), .unavailable)
        }
        // The unavailable short-circuit must fire before the system-prompt
        // flag is set — otherwise the privacy cover stays suppressed for a
        // prompt that never appears.
        XCTAssertFalse(model.appLock.isPresentingSystemPermissionPrompt)
    }

    func testMacOnboardingWithSyncSkipsDefaultVehicle() async throws {
        // A Mac that enabled sync during onboarding must not mint "My Car":
        // the iPhone's vehicles arrive via the CloudKit import after relaunch,
        // and a backfilled default racing that import becomes a duplicate.
        let model = try makeModel(platformOverride: .mac, skipOnboarding: false)
        await model.startup()
        XCTAssertTrue(model.vehicles.isEmpty)

        model.syncEnabled = true
        model.completeOnboarding()
        XCTAssertTrue(model.vehicles.isEmpty)

        // The every-launch backfill must also stay quiet (simulated relaunch
        // before the import lands).
        await model.startup()
        XCTAssertTrue(model.vehicles.isEmpty)
    }

    func testMacOnboardingWithoutSyncStaysVehicleFreeUntilExplicitAdd() async throws {
        let model = try makeModel(platformOverride: .mac, skipOnboarding: false)
        await model.startup()

        model.completeOnboarding()
        XCTAssertTrue(model.vehicles.isEmpty)

        // Every automatic launch backfill remains off on Mac, even without
        // sync. Settings -> Vehicles -> Add Vehicle is the intentional path.
        await model.startup()
        XCTAssertTrue(model.vehicles.isEmpty)

        let explicitVehicle = try XCTUnwrap(model.createVehicle(name: "Roadster"))
        XCTAssertEqual(model.vehicles.map(\.id), [explicitVehicle.id])
        await model.startup()
        XCTAssertEqual(model.vehicles.map(\.id), [explicitVehicle.id])
        XCTAssertFalse(model.vehicles.contains { $0.name == "My Car" })
    }

    func testCleanMacNoSyncToSyncWaitsForSimulatedVehicleImport() async throws {
        let model = try makeModel(platformOverride: .mac, skipOnboarding: false)
        await model.startup()
        model.completeOnboarding()
        XCTAssertTrue(model.vehicles.isEmpty)

        let request = try model.requestSyncPreferenceChange(to: true)
        guard case .confirmationRequired(let preflight) = request else {
            return XCTFail("A local-only Mac must confirm before joining iCloud")
        }
        XCTAssertEqual(preflight.tripCount, 0)
        XCTAssertEqual(preflight.vehicleCount, 0)

        defer { try? FileManager.default.removeItem(at: model.firstSyncRecoveryRootURL) }
        try await model.confirmSyncEnablement()
        XCTAssertTrue(model.syncEnabled)
        XCTAssertTrue(model.vehicles.isEmpty)

        // UI-test persistence cannot run CloudKit. Inserting directly through
        // the shared store is the deterministic stand-in for its first import.
        let imported = try model.vehicleStore.createVehicle(name: "Cloud Roadster")
        model.refresh()
        await model.startup()

        XCTAssertEqual(model.vehicles.map(\.id), [imported.id])
        XCTAssertEqual(model.vehicles.map(\.name), ["Cloud Roadster"])
        XCTAssertFalse(model.vehicles.contains { $0.name == "My Car" })
    }

    func testMacProtectedDataUnlockDoesNotBackfillDefaultVehicle() async throws {
        let model = try makeModel(
            platformOverride: .mac,
            protectedDataAvailableOverride: false
        )
        XCTAssertTrue(model.isAwaitingProtectedData)
        XCTAssertTrue(model.vehicles.isEmpty)

        await model.reloadPersistenceForProtectedData()

        XCTAssertFalse(model.isAwaitingProtectedData)
        XCTAssertTrue(model.vehicles.isEmpty)
    }

    func testDriveStartIntentThrowsOnMacBeforeWritingAnything() {
        // Mac startup never bootstraps capture and the spooled-signal drain
        // sits behind the same guard, so a signal written here would report
        // success and expire unread. The guard is the performer's FIRST
        // statement — throwing proves no store was touched.
        XCTAssertThrowsError(
            try DriveStartIntentPerformer.armDriveStart(trigger: .vehicleBluetooth, platform: .mac)
        ) { error in
            XCTAssertTrue(error is DriveStartIntentError)
        }
    }

    func testCommandSurfaceAvailability() throws {
        // Menu/keyboard dispatch bypasses the lock overlay's hitTest gate, so
        // the ⌘-menu's focused values publish nil off this predicate.
        let unlockedModel = try makeModel()
        XCTAssertTrue(unlockedModel.isCommandSurfaceAvailable)

        // No --reset-preferences here: that argument clears the lock flag
        // before AppLockController reads it.
        let preferences = Preferences(defaults: try makeTestDefaults())
        preferences.appLockEnabled = true
        let lockedModel = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--skip-onboarding"]),
            preferences: preferences
        )
        XCTAssertEqual(lockedModel.appLock.lockState, .locked)
        XCTAssertFalse(lockedModel.isCommandSurfaceAvailable)
    }

    func testMacModeForcesTrackingInactiveDespiteStoredPreference() throws {
        // Asserted on the predicate, not through a model. Two suppressors sit
        // in front of the stored preference, and every model a test can build
        // carries --uitesting — whose `false` masks the platform's, so the
        // version of this test that went through a model passed with the Mac
        // guard deleted. Building a model WITHOUT --uitesting is not the
        // answer either: `storeDirectory` is nil there, so it would open the
        // app's real store.
        let preferences = Preferences(defaults: try makeTestDefaults())
        preferences.automaticTrackingEnabled = true

        func active(uiTesting: Bool, capturesDrives: Bool) -> Bool {
            MileageAppModel.initialTrackingActive(
                preferences: preferences,
                isUITesting: uiTesting,
                capturesDrives: capturesDrives
            )
        }
        XCTAssertTrue(
            active(uiTesting: false, capturesDrives: true),
            "A stored preference of true is honored on a machine that captures"
        )
        XCTAssertFalse(
            active(uiTesting: false, capturesDrives: false),
            "…and never on a Mac, whatever the preference says"
        )
        XCTAssertFalse(active(uiTesting: true, capturesDrives: true))
        XCTAssertFalse(active(uiTesting: true, capturesDrives: false))
    }

    func testCaptureBelongsToTheMachineNotToTheTestHarness() {
        // `driveCaptureSuppressed` is `isUITesting || !platform.capturesDrives`,
        // so every assertion about it made from a --uitesting model is
        // satisfied by the first disjunct alone. This pins the second one,
        // which is the half that ships.
        XCTAssertFalse(RunningPlatform.mac.capturesDrives)
        XCTAssertTrue(RunningPlatform.iOS.capturesDrives)
        XCTAssertFalse(RunningPlatform.mac.hasLockScreen)
        XCTAssertTrue(RunningPlatform.mac.exportsThroughSavePanel)
        XCTAssertFalse(RunningPlatform.iOS.exportsThroughSavePanel)
    }
}
