import AppCore
import CoreData
import Foundation
import UIKit
import XCTest
@testable import MileageTracker

@MainActor
final class MileageAppModelLaunchTests: XCTestCase {
    func testMapKitFixturesRequireExplicitUITestOptIn() {
        XCTAssertFalse(MapKitTestFixturePolicy.isEnabled(arguments: ["MileageTracker"]))
        XCTAssertFalse(MapKitTestFixturePolicy.isEnabled(arguments: ["MileageTracker", "--uitesting"]))
        XCTAssertFalse(MapKitTestFixturePolicy.isEnabled(
            arguments: ["MileageTracker", MapKitTestFixturePolicy.optInArgument]
        ))
        XCTAssertTrue(MapKitTestFixturePolicy.isEnabled(arguments: [
            "MileageTracker",
            "--uitesting",
            MapKitTestFixturePolicy.optInArgument
        ]))
    }

    func testPersistentFixtureArgumentsRequireUITestingMode() {
        for argument in [
            "--seed-mileage-data",
            "--seed-vehicles",
            "--seed-app-store-screenshot-data",
            "--seed-unresolved-mix",
            "--debug-seed-suggestion-demo"
        ] {
            XCTAssertFalse(MileageAppModel.allowsFixtureSeeding(
                previewMode: false,
                arguments: ["MileageTracker", argument]
            ))
            XCTAssertTrue(MileageAppModel.allowsFixtureSeeding(
                previewMode: false,
                arguments: ["MileageTracker", "--uitesting", argument]
            ))
            XCTAssertFalse(MileageAppModel.allowsFixtureSeeding(
                previewMode: true,
                arguments: ["MileageTracker", "--uitesting", argument]
            ))
        }
    }

    func testDemoFixtureWithSavedSyncEnabledUsesOnlyIsolatedLocalStore() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.syncEnabled = true
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker", "--uitesting", "--reset-data",
                "--skip-onboarding", "--debug-seed-suggestion-demo"
            ]),
            preferences: preferences
        )
        XCTAssertFalse(model.syncRunningThisLaunch)
        XCTAssertFalse(model.syncToggleAvailable)
        XCTAssertTrue(model.driveCaptureSuppressed)
        XCTAssertFalse(model.persistence.container is NSPersistentCloudKitContainer)
        for store in model.persistence.container.persistentStoreCoordinator.persistentStores {
            XCTAssertTrue(try XCTUnwrap(store.url).path.contains("MileageTracker-UITesting-"))
        }
        await model.startup()
        #if DEBUG
        XCTAssertFalse(model.trips.isEmpty)
        #endif
    }

    func testUITestLaunchArgumentsResetSkipOnboardingAndSeedTrips() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-preferences",
                "--seed-mileage-data",
                "--skip-onboarding"
            ]),
            preferences: Preferences(defaults: defaults)
        )

        await model.startup()

        XCTAssertTrue(model.hasCompletedOnboarding)
        XCTAssertEqual(model.trips.count, 2)
        XCTAssertTrue(model.trips.contains { $0.startAddress == "Home" && $0.endAddress == "Client" })
        XCTAssertTrue(model.trips.contains { $0.startAddress == "Gym" && $0.endAddress == "Home" })
    }

    /// The store properties are implicitly unwrapped and assigned in
    /// wireStores() during init (see MileageAppModel.swift). This guards the
    /// contract every other code path relies on: after init returns, the
    /// externally visible stores are non-nil, even before startup() runs.
    func testStoresAreWiredImmediatelyAfterInit() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data"]),
            preferences: Preferences(defaults: defaults)
        )

        XCTAssertNotNil(model.tripStore)
        XCTAssertNotNil(model.bluetoothHintStore)
        XCTAssertNotNil(model.vehicleStore)
    }

    func testOnboardingResetAndSyncOverrideExposeSetupStateForUITests() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-preferences",
                "--reset-onboarding",
                "--enable-sync-for-uitesting"
            ]),
            preferences: Preferences(defaults: defaults)
        )

        XCTAssertFalse(model.hasCompletedOnboarding)
        XCTAssertTrue(model.syncToggleAvailable)
        XCTAssertFalse(model.syncRunningThisLaunch)
    }

    /// Regression guard for the ObservableObject → @Observable migration: the
    /// property `didSet` side effects must keep writing through to Preferences.
    func testSettingsPropertiesPersistToPreferences() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-preferences"
            ]),
            preferences: preferences
        )

        model.hasCompletedOnboarding = true
        XCTAssertTrue(preferences.hasCompletedOnboarding)

        model.currentDriveLiveActivitiesEnabled = false
        XCTAssertFalse(preferences.currentDriveLiveActivitiesEnabled)

        XCTAssertFalse(model.detailedDiagnosticsEnabled)
        model.detailedDiagnosticsEnabled = true
        XCTAssertTrue(preferences.detailedDiagnosticsEnabled)
    }

    func testTurningOffDetailedDiagnosticsImmediatelyDeletesCaptureJournal() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.detailedDiagnosticsEnabled = true
        let suffix = UUID().uuidString
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let persistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let eventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        try eventStore.save(DriveCaptureJournalEntry(
            date: Date(),
            category: "test",
            message: "sensitive journal detail",
            expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60)
        ))

        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--test-store-suffix=\(suffix)"
            ],
            preferences: preferences
        )
        XCTAssertEqual(try eventStore.fetchEvents(since: nil, until: nil).count, 1)

        model.detailedDiagnosticsEnabled = false

        persistence.container.viewContext.refreshAllObjects()
        XCTAssertTrue(try eventStore.fetchEvents(since: nil, until: nil).isEmpty)
    }

    func testCompletingOnboardingStartsTrackingByDefaultWhenHealthIsReady() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-preferences",
                "--reset-onboarding"
            ]),
            preferences: preferences
        )
        model.health = readyTrackingHealth()

        XCTAssertNil(preferences.automaticTrackingEnabled)
        XCTAssertFalse(model.trackingActive)

        model.completeOnboarding()

        XCTAssertTrue(model.trackingActive)
        XCTAssertEqual(preferences.automaticTrackingEnabled, true)
    }

    func testPermissionReadinessAfterOnboardingStartsTrackingByDefault() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-preferences",
                "--reset-onboarding"
            ]),
            preferences: preferences
        )

        model.completeOnboarding()
        XCTAssertFalse(model.trackingActive)

        model.health = readyTrackingHealth()

        XCTAssertTrue(model.trackingActive)
        XCTAssertEqual(preferences.automaticTrackingEnabled, true)
    }

    func testCompletingOnboardingDoesNotOverrideExplicitTrackingOptOut() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.automaticTrackingEnabled = false
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-onboarding"
            ]),
            preferences: preferences
        )
        model.health = readyTrackingHealth()

        model.completeOnboarding()

        XCTAssertFalse(model.trackingActive)
        XCTAssertEqual(preferences.automaticTrackingEnabled, false)
    }

    func testResetLeavesAutomaticTrackingPreferenceUnset() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.automaticTrackingEnabled = true
        preferences.recordVehicleAutomationReceipt(trigger: .vehicleBluetooth, at: Date())
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding"
            ]),
            preferences: preferences
        )
        model.trackingActive = true

        await model.resetApp()

        // Reset must leave the preference unset (nil) so a fresh launch /
        // re-onboarding falls back to default-on behavior. The `trackingActive`
        // didSet writes `false` during reset, so the model has to restore nil.
        XCTAssertFalse(model.trackingActive)
        XCTAssertNil(preferences.automaticTrackingEnabled)
        XCTAssertNil(preferences.lastVehicleAutomationReceivedAt)
        XCTAssertNil(model.lastVehicleAutomationReceivedAt)
    }

    func testAppInfoPlistIncludesBluetoothUsageDescription() throws {
        let value = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String)

        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testAppInfoPlistIncludesFaceIDUsageDescription() throws {
        let value = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String)

        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testUITestingResetPreferencesDoesNotClearStandardDefaults() throws {
        let standardPreferences = Preferences(defaults: .standard)
        standardPreferences.automaticTrackingEnabled = true
        standardPreferences.syncEnabled = true
        standardPreferences.vehicleBluetoothHintsEnabled = true
        standardPreferences.appLockEnabled = true
        addTeardownBlock {
            standardPreferences.clearAll()
        }

        _ = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-preferences",
                "--skip-onboarding"
            ])
        )

        XCTAssertEqual(standardPreferences.automaticTrackingEnabled, true)
        XCTAssertTrue(standardPreferences.syncEnabled)
        XCTAssertTrue(standardPreferences.vehicleBluetoothHintsEnabled)
        XCTAssertTrue(standardPreferences.appLockEnabled)
    }

    func testDriveSelfTestLaunchArgumentSavesDeterministicTripAndStatus() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--reset-preferences",
                "--skip-onboarding",
                "--drive-self-test"
            ]),
            preferences: Preferences(defaults: defaults)
        )

        await model.startup()

        let status = try XCTUnwrap(model.driveSelfTestStatus)
        XCTAssertTrue(status.hasPrefix("Drive self-test complete"), status)
        XCTAssertEqual(model.trips.count, 1)
        XCTAssertEqual(model.trips.first?.captureSource, "automatic")
        XCTAssertGreaterThan(model.trips.first?.distanceMeters ?? 0, 0)
        let diagnostics = try decodeDiagnostics(from: model)
        XCTAssertGreaterThanOrEqual(diagnostics.diagnosticSamples.filter(\.acceptedForDetection).count, 3)
        XCTAssertTrue(diagnostics.captureEvents.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Wake bootstrap started"
        })
    }

    func testAppDelegatePreservesLocationLaunchOption() {
        let locationDelegate = AppDelegate()
        XCTAssertTrue(locationDelegate.application(
            UIApplication.shared,
            didFinishLaunchingWithOptions: [.mileageLocationWake: true]
        ))
        XCTAssertTrue(locationDelegate.launchedForLocation)

        let remoteNotificationDelegate = AppDelegate()
        XCTAssertTrue(remoteNotificationDelegate.application(
            UIApplication.shared,
            didFinishLaunchingWithOptions: [.mileageRemoteNotificationWake: ["aps": [:]]]
        ))
        XCTAssertFalse(remoteNotificationDelegate.launchedForLocation)
    }

    func testLaunchCoordinatorConsumesLocationWakeOnce() {
        let coordinator = AppLaunchCoordinator()
        coordinator.recordLaunchOptions([.mileageLocationWake: true])

        XCTAssertEqual(coordinator.consumeLaunchReason(applicationState: .background), .locationWake)
        XCTAssertEqual(coordinator.consumeLaunchReason(applicationState: .background), .nonLocationBackground)
        XCTAssertEqual(coordinator.consumeLaunchReason(applicationState: .active), .foreground)
    }

    func testLaunchCoordinatorStartsOnlyOnceAfterLaunchOptionsAreKnown() async {
        let coordinator = AppLaunchCoordinator()
        var reasons: [MileageAppLaunchReason] = []

        XCTAssertFalse(coordinator.startIfNeeded(applicationState: .background) { reason in
            reasons.append(reason)
        })

        coordinator.recordLaunchOptions([.mileageLocationWake: true])

        XCTAssertTrue(coordinator.startIfNeeded(applicationState: .background) { reason in
            reasons.append(reason)
        })
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(coordinator.startIfNeeded(applicationState: .active) { reason in
            reasons.append(reason)
        })
        XCTAssertEqual(reasons, [.locationWake])
    }

    /// An App-Intent (Shortcut automation) launch arrives as
    /// `.nonLocationBackground` right as a drive begins. It must run the full
    /// wake bootstrap: a fresh process that skips arming its CoreLocation
    /// clients becomes a suspended zombie no SLC/visit/geofence event can wake,
    /// losing the entire drive (2026-07-01 two-phone comparison).
    func testNonLocationBackgroundStartupBootstrapsTracking() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding"
            ]),
            preferences: Preferences(defaults: defaults)
        )
        model.trackingActive = true

        await model.startup(launchReason: .nonLocationBackground)

        XCTAssertTrue(model.trackingActive)
        // `--uitesting` models never build a real tracker, so assert the launch
        // path taken via its lifecycle record; the bootstrap behavior itself
        // (arming + pending-signal consumption) is covered by
        // `DriveCaptureRuntimePolicyTests.testBackgroundLaunchBootstrapConsumesPendingIntentSignal`.
        let diagnostics = try decodeDiagnostics(from: model)
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Resumed drive capture during non-location background launch"
        })
        XCTAssertFalse(diagnostics.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Deferred tracking start for non-location background launch"
        })
    }

    func testStartupMaintenancePurgesExpiredRawSamplesAndResolvedPendingSignals() async throws {
        let defaults = try makeTestDefaults()
        let suffix = UUID().uuidString
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let now = Date()
        let persistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        try seedExpiredRawSample(in: context, now: now)
        XCTAssertEqual(try tripStore.rawSampleCount(), 1)

        let pendingStore = PendingDriveStartSignalStore(context: context)
        let old = now.addingTimeInterval(-Double(PendingDriveStartSignal.retentionDays + 1) * 24 * 60 * 60)
        let consumed = try pendingStore.save(trigger: .vehicleBluetooth, at: old, policy: .balanced)
        try pendingStore.markConsumed(id: consumed.id, consumedAt: old.addingTimeInterval(1), captureID: UUID())
        let expired = try pendingStore.save(trigger: .charger, at: old.addingTimeInterval(10), policy: .balanced)
        XCTAssertEqual(try pendingStore.markExpired(now: expired.expiresAt.addingTimeInterval(1)), 1)
        let pendingToKeep = try pendingStore.save(trigger: .manual, at: old.addingTimeInterval(20), policy: .balanced)
        XCTAssertEqual(try pendingStore.fetchSignals(since: nil, until: nil).count, 3)

        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--test-store-suffix=\(suffix)"
            ],
            preferences: Preferences(defaults: defaults)
        )
        await model.startup()

        let verification = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let verificationContext = verification.container.viewContext
        XCTAssertEqual(try TripStore(context: verificationContext).rawSampleCount(), 0)

        let remaining = try PendingDriveStartSignalStore(context: verificationContext).fetchSignals(since: nil, until: nil)
        XCTAssertEqual(remaining.map(\.id), [pendingToKeep.id])
        XCTAssertEqual(remaining.first?.status, .pending)
    }

    /// Before first unlock after a reboot the intent's stores cannot open.
    /// The signal must fall back to the unprotected spool instead of throwing —
    /// a thrown intent marks the user's automation failed for a condition they
    /// cannot act on, and loses the drive-start signal entirely.
    func testArmDriveStartIntentSpoolsSignalWhenPersistenceStackFails() async throws {
        enum IntentTestError: Error {
            case expected
        }

        IntentDataProvider.stackFactory = {
            throw IntentTestError.expected
        }
        defer { IntentDataProvider.resetFactoryForTesting() }
        _ = PendingSignalSpool().drain()
        addTeardownBlock { _ = PendingSignalSpool().drain() }

        _ = try await ArmDriveStartIntent(trigger: .charger).perform()

        let drained = try XCTUnwrap(PendingSignalSpool().drain(), "store failure must spool the signal")
        XCTAssertEqual(drained.trigger, .charger)
    }

    func testStartupDrainsSpooledStartSignalIntoStore() async throws {
        _ = PendingSignalSpool().drain()
        try PendingSignalSpool().save(trigger: .charger, at: Date())
        addTeardownBlock { _ = PendingSignalSpool().drain() }

        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding"
            ]),
            preferences: Preferences(defaults: defaults)
        )
        await model.startup()

        let diagnostics = try decodeDiagnostics(from: model)
        XCTAssertTrue(diagnostics.pendingDriveStartSignals.contains { $0.trigger == .charger })
        XCTAssertNil(PendingSignalSpool().drain(), "drain must consume the spool")
    }

    func testArmDriveStartIntentSavesPendingSignalToLocalStore() async throws {
        let suffix = UUID().uuidString
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        IntentDataProvider.stackFactory = {
            try IntentDataStack(mode: .localOnly, storeDirectory: storeDirectory)
        }
        defer { IntentDataProvider.resetFactoryForTesting() }

        _ = try await ArmDriveStartIntent(trigger: .charger).perform()

        let initialPersistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let initialSignals = try PendingDriveStartSignalStore(
            context: initialPersistence.container.viewContext
        ).fetchSignals(since: nil, until: nil)
        let pendingSignal = try XCTUnwrap(initialSignals.first)
        XCTAssertEqual(pendingSignal.status, .pending)
        XCTAssertEqual(pendingSignal.trigger, .charger)
    }

    func testLocationWakeStartupUsesLocationWakePathWhenTrackingEnabled() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding"
            ]),
            preferences: Preferences(defaults: defaults)
        )
        model.trackingActive = true

        await model.startup(launchReason: .locationWake)

        let diagnostics = try decodeDiagnostics(from: model)
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Resumed drive capture during location wake"
        })
        XCTAssertFalse(diagnostics.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Deferred tracking start for non-location background launch"
        })
    }

    func testLocationWakeDoesNotEnableTrackingWhenTrackingDisabled() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding"
            ]),
            preferences: Preferences(defaults: defaults)
        )

        XCTAssertFalse(model.trackingActive)
        await model.startup(launchReason: .locationWake)

        XCTAssertFalse(model.trackingActive)
        let diagnostics = try decodeDiagnostics(from: model)
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Ignored location wake while tracking disabled"
        })
    }

    func testDiagnosticsExportIncludesActiveDriveCheckpoint() async throws {
        let defaults = try makeTestDefaults()
        let suffix = UUID().uuidString
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let persistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState(phase: .recording)
        state.startedAt = start
        state.pendingTripID = UUID()
        state.samples = [
            LocationSample(
                timestamp: start,
                latitude: 40,
                longitude: -73,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 12,
                motionHint: .automotive
            )
        ]
        state.parkingEvidence = ParkingEvidence(
            signal: .vehicleConnectionDisconnected,
            source: .bluetoothAudio,
            confidence: .hard,
            signalAt: start.addingTimeInterval(300),
            inferredEndAt: start.addingTimeInterval(300),
            anchorSample: state.samples.first
        )
        try activeStore.save(state)

        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--test-store-suffix=\(suffix)"
            ],
            preferences: Preferences(defaults: defaults)
        )

        await model.startup()

        let diagnostics = try decodeDiagnostics(from: model)
        XCTAssertEqual(diagnostics.activeDriveState?.phase, .recording)
        XCTAssertEqual(diagnostics.activeDriveState?.startedAt, start)
        XCTAssertEqual(diagnostics.activeDriveState?.parkingEvidence?.signal, .vehicleConnectionDisconnected)
    }

    private func decodeDiagnostics(from model: MileageAppModel) throws -> DiagnosticsExport {
        let data = try XCTUnwrap(model.exportDiagnostics())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticsExport.self, from: data)
    }

    private func makeModelWithPendingStartSignal(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (model: MileageAppModel, pending: PendingDriveStartSignal) {
        let defaults = try makeTestDefaults(file: file, line: line)
        let suffix = UUID().uuidString
        let storeDirectory = try XCTUnwrap(
            ResetCoordinator.storeDirectoryForUITesting(suffix: suffix),
            file: file,
            line: line
        )
        try? FileManager.default.removeItem(at: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let persistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let pendingStore = PendingDriveStartSignalStore(context: persistence.container.viewContext)
        let pending = try pendingStore.save(
            trigger: .vehicleBluetooth,
            at: Date(),
            policy: .balanced
        )
        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--test-store-suffix=\(suffix)"
            ],
            preferences: Preferences(defaults: defaults)
        )
        return (model, pending)
    }

    private func seedExpiredRawSample(in context: NSManagedObjectContext, now: Date) throws {
        let sample = NSEntityDescription.insertNewObject(forEntityName: "RawSampleEntity", into: context)
        sample.setValue(UUID(), forKey: "id")
        sample.setValue(UUID(), forKey: "tripID")
        sample.setValue(now.addingTimeInterval(-60), forKey: "timestamp")
        sample.setValue(40.0, forKey: "latitude")
        sample.setValue(-73.0, forKey: "longitude")
        sample.setValue(10.0, forKey: "horizontalAccuracy")
        sample.setValue(MotionHint.automotive.rawValue, forKey: "motionHintRaw")
        sample.setValue(now.addingTimeInterval(-1), forKey: "expiresAt")
        try context.save()
    }

    private func readyTrackingHealth() -> TrackingHealth {
        var health = TrackingHealth.unknown
        health.alwaysLocationAuthorized = true
        health.preciseLocationEnabled = true
        health.motionAuthorized = true
        health.backgroundRefreshAvailable = true
        health.issues = []
        return health
    }
}
