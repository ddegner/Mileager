import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
private final class SyncCoordinatorReference {
    weak var value: SyncCoordinator?
}

@MainActor
final class SyncAndResetCoordinatorTests: XCTestCase {
    nonisolated(unsafe) private var temporaryStoreDirectories: [URL] = []
    nonisolated(unsafe) private var openPersistences: [PersistenceController] = []

    override func setUp() {
        super.setUp()
        Self.clearStandardHistoryTokens()
    }

    override func tearDown() {
        Self.clearStandardHistoryTokens()
        for persistence in openPersistences {
            try? Self.removePersistentStores(in: persistence.container)
        }
        openPersistences.removeAll()
        for directory in temporaryStoreDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryStoreDirectories.removeAll()
        super.tearDown()
    }

    nonisolated private static func clearStandardHistoryTokens() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key == "SyncRemoteChangeHistoryToken"
            || key.hasPrefix("SyncRemoteChangeHistoryToken.v2.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testSyncConfigurationResolverKeepsUITestingLocalOnly() {
        let configuration = SyncConfigurationResolver.resolve(isUITesting: true, storedSyncEnabled: true)

        XCTAssertEqual(configuration.persistenceMode, .localOnly)
        XCTAssertFalse(configuration.isAvailableInThisBuild)
        XCTAssertFalse(configuration.isEnabledThisLaunch)
        XCTAssertFalse(configuration.containerIdentifier.isEmpty)
    }

    func testSyncConfigurationResolverKeepsDisabledPreferenceLocalOnly() {
        let configuration = SyncConfigurationResolver.resolve(isUITesting: false, storedSyncEnabled: false)

        XCTAssertEqual(configuration.persistenceMode, .localOnly)
        XCTAssertFalse(configuration.isEnabledThisLaunch)
        XCTAssertFalse(configuration.containerIdentifier.isEmpty)
    }

    func testUITestingSyncCoordinatorKeepsCloudKitUnavailableButToggleVisibleWhenOverridden() {
        let coordinator = SyncCoordinator(isUITesting: true, storedSyncEnabled: true)

        XCTAssertEqual(coordinator.persistenceMode(), .localOnly)
        XCTAssertFalse(coordinator.isAvailableInThisBuild)
        XCTAssertFalse(coordinator.isEnabledThisLaunch)
        XCTAssertFalse(coordinator.requiresRelaunch(forNewPreference: true))
        XCTAssertEqual(coordinator.initialStatus(syncEnabledPreference: true)?.state, .unavailable)
    }

    func testSyncEnablementRequiresExplicitConfirmationWithoutChangingPreference() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--enable-sync-for-uitesting"
            ]),
            preferences: preferences
        )
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        let secondStart = Date(timeIntervalSince1970: 1_710_000_000)
        _ = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: firstStart,
            endDate: firstStart.addingTimeInterval(1_800),
            distanceMeters: 1_000
        ))
        _ = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: secondStart,
            endDate: secondStart.addingTimeInterval(3_600),
            distanceMeters: 2_000
        ))
        _ = try model.vehicleStore.createVehicle(name: "Roadster")

        let result = try model.requestSyncPreferenceChange(to: true)
        guard case .confirmationRequired(let preflight) = result else {
            return XCTFail("Enabling a local-only library must require confirmation")
        }

        XCTAssertEqual(preflight.tripCount, 2)
        XCTAssertEqual(preflight.earliestTripDate, firstStart)
        XCTAssertEqual(preflight.latestTripDate, secondStart.addingTimeInterval(3_600))
        XCTAssertEqual(preflight.rawSampleCount, 0)
        XCTAssertEqual(preflight.vehicleCount, 1)
        XCTAssertFalse(model.syncEnabled)
        XCTAssertFalse(preferences.syncEnabled)
        XCTAssertFalse(model.syncChangeRequiresRelaunch)
    }

    func testConfirmSyncEnablementCreatesRecoveryCopyPersistsPreferenceAndRequiresRelaunch() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--enable-sync-for-uitesting"
            ]),
            preferences: preferences
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let samples = [
            LocationSample(
                timestamp: start,
                latitude: 42.3601,
                longitude: -71.0589,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 12,
                motionHint: .automotive
            ),
            LocationSample(
                timestamp: start.addingTimeInterval(600),
                latitude: 42.3701,
                longitude: -71.0489,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 0,
                motionHint: .stationary
            )
        ]
        let trip = try model.tripStore.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))

        let request = try model.requestSyncPreferenceChange(to: true)
        guard case .confirmationRequired(let preflight) = request else {
            return XCTFail("Enabling must produce the non-destructive preflight")
        }
        XCTAssertEqual(preflight.rawSampleCount, samples.count)
        XCTAssertEqual(preflight.vehicleCount, 0)
        defer { try? FileManager.default.removeItem(at: model.firstSyncRecoveryRootURL) }
        try await model.confirmSyncEnablement()

        XCTAssertTrue(model.syncEnabled)
        XCTAssertTrue(preferences.syncEnabled)
        XCTAssertTrue(model.syncChangeRequiresRelaunch)
        XCTAssertEqual(try model.tripStore.fetchTrip(id: trip.id).id, trip.id)
        XCTAssertEqual(try model.tripStore.rawSampleCount(tripID: trip.id), samples.count)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: model.firstSyncRecoveryRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        XCTAssertEqual(recoveryDirectories.count, 1)
        let recovery = try PersistenceController(
            mode: .localOnly,
            storeDirectory: try XCTUnwrap(recoveryDirectories.first)
        )
        let recoveryStore = TripStore(context: recovery.container.viewContext)
        XCTAssertEqual(try recoveryStore.fetchTrip(id: trip.id).id, trip.id)
        XCTAssertEqual(try recoveryStore.rawSampleCount(tripID: trip.id), samples.count)
        let recoveryCoordinator = recovery.container.persistentStoreCoordinator
        recovery.container.viewContext.reset()
        for store in recoveryCoordinator.persistentStores {
            try recoveryCoordinator.remove(store)
        }

        XCTAssertEqual(try model.requestSyncPreferenceChange(to: false), .applied)
        XCTAssertFalse(model.syncEnabled)
        XCTAssertFalse(preferences.syncEnabled)
        XCTAssertFalse(model.syncChangeRequiresRelaunch)
    }

    func testSyncEnablementIsRejectedWhileDriveIsRecording() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data",
                "--enable-sync-for-uitesting",
                "--seed-current-drive"
            ]),
            preferences: preferences
        )
        await model.startup()
        XCTAssertNotNil(model.currentDrive)

        XCTAssertThrowsError(try model.requestSyncPreferenceChange(to: true)) { error in
            XCTAssertEqual(error as? SyncEnablementError, .activeDrive)
        }
        do {
            try await model.confirmSyncEnablement()
            XCTFail("A recording drive must block sync enablement")
        } catch {
            XCTAssertEqual(error as? SyncEnablementError, .activeDrive)
        }
        XCTAssertFalse(model.syncEnabled)
        XCTAssertFalse(preferences.syncEnabled)
    }

    func testResetAppRemovesFirstSyncRecoverySnapshots() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        let model = MileageAppModel(
            arguments: appModelArguments([
                "MileageTracker",
                "--uitesting",
                "--reset-data"
            ]),
            preferences: preferences
        )
        let recoveryDirectory = model.firstSyncRecoveryRootURL
            .appendingPathComponent("snapshot-test", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        try Data("recovery".utf8).write(
            to: recoveryDirectory.appendingPathComponent("marker")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryDirectory.path))

        await model.resetApp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: model.firstSyncRecoveryRootURL.path))
        XCTAssertNotNil(model.resetStatusMessage)
    }

    func testResetCoordinatorDeletesDataAndResettablePreferences() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.automaticTrackingEnabled = true
        preferences.syncEnabled = true
        preferences.vehicleBluetoothHintsEnabled = true
        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "Client"
        ))

        let reset = ResetCoordinator(
            persistence: persistence,
            sync: SyncCoordinator(isUITesting: true, storedSyncEnabled: false),
            preferences: preferences
        )
        let result = await reset.run()

        if case .failure(let message) = result {
            XCTFail(message)
        }
        XCTAssertTrue(try store.fetchTrips().isEmpty)
        XCTAssertNil(preferences.automaticTrackingEnabled)
        XCTAssertFalse(preferences.syncEnabled)
        XCTAssertFalse(preferences.vehicleBluetoothHintsEnabled)
    }

    func testResetCoordinatorSkipsCloudPurgeWhenSyncIsAvailableButDisabledThisLaunch() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.automaticTrackingEnabled = true
        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "Client"
        ))

        let reset = ResetCoordinator(
            persistence: persistence,
            sync: SyncCoordinator(configuration: SyncConfiguration(
                containerIdentifier: "iCloud.com.daviddegner.MileageTracker",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: false
            )),
            preferences: preferences
        )
        let result = await reset.run()

        if case .failure(let message) = result {
            XCTFail(message)
        }
        XCTAssertTrue(try store.fetchTrips().isEmpty)
        XCTAssertNil(preferences.automaticTrackingEnabled)
    }

    func testOwnAuthorTransactionsDoNotReportRemoteChanges() async throws {
        let persistence = try makeSQLitePersistence()
        let store = TripStore(context: persistence.container.viewContext)
        let coordinator = SyncCoordinator(isUITesting: true, storedSyncEnabled: false)

        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 5)
        ))

        let firstProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(firstProcessed)
        // Token advanced past our own transactions; a second pass stays quiet.
        let secondProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(secondProcessed)
    }

    func testForeignAuthorTransactionsReportRemoteChanges() async throws {
        let persistence = try makeSQLitePersistence()
        let store = TripStore(context: persistence.container.viewContext)
        let coordinator = SyncCoordinator(isUITesting: true, storedSyncEnabled: false)

        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 5)
        ))
        let ownProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(ownProcessed)

        let background = persistence.container.newBackgroundContext()
        background.transactionAuthor = "Test.CloudKitImport"
        try background.performAndWait {
            let trip = NSEntityDescription.insertNewObject(forEntityName: "TripEntity", into: background)
            let now = Date(timeIntervalSince1970: 1_800_010_000)
            trip.setValue(UUID(), forKey: "id")
            trip.setValue(now, forKey: "createdAt")
            trip.setValue(now, forKey: "updatedAt")
            trip.setValue("manual", forKey: "captureSource")
            trip.setValue(now, forKey: "startDate")
            trip.setValue(now.addingTimeInterval(600), forKey: "endDate")
            trip.setValue(1_000.0, forKey: "distanceMeters")
            trip.setValue(600.0, forKey: "durationSeconds")
            try background.save()
        }

        let foreignProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertTrue(foreignProcessed)
        // Token advanced past the foreign transaction too.
        let afterProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(afterProcessed)
    }

    func testHistoryTokensAreIsolatedByCloudKitContainer() async throws {
        let persistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let first = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.first",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults
        )
        let second = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.second",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults
        )

        let firstProcessed = await first.processRemoteTransactions(in: persistence)
        XCTAssertTrue(firstProcessed)
        let secondProcessed = await second.processRemoteTransactions(in: persistence)
        XCTAssertTrue(
            secondProcessed,
            "A different CloudKit container must start from its own history namespace"
        )
    }

    func testMismatchedStoreTokenIsClearedAndHistoryIsReplayed() async throws {
        let firstPersistence = try makeSQLitePersistence()
        let secondPersistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        let containerIdentifier = "iCloud.example.history-recovery"
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: containerIdentifier,
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults
        )
        let tokens = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: SyncCoordinator.historyTokenKeyPrefix,
            containerIdentifier: containerIdentifier
        )
        try saveForeignTrip(in: firstPersistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let firstProcessed = await coordinator.processRemoteTransactions(in: firstPersistence)
        XCTAssertTrue(firstProcessed)
        let foreignStoreToken = try XCTUnwrap(tokens.token(for: firstPersistence))
        tokens.save(foreignStoreToken, for: secondPersistence)
        try saveForeignTrip(in: secondPersistence, start: Date(timeIntervalSince1970: 1_800_020_000))

        let replayProcessed = await coordinator.processRemoteTransactions(in: secondPersistence)
        XCTAssertTrue(
            replayProcessed,
            "An opaque token from another store must fall back to retained history"
        )
        let afterProcessed = await coordinator.processRemoteTransactions(in: secondPersistence)
        XCTAssertFalse(afterProcessed)
    }

    func testLegacyUnscopedHistoryTokenIsDiscarded() throws {
        let defaults = try makeTestDefaults()
        defaults.set(Data("legacy-token".utf8), forKey: "SyncRemoteChangeHistoryToken")

        _ = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults
        )

        XCTAssertNil(defaults.data(forKey: "SyncRemoteChangeHistoryToken"))
    }

    func testRemoteProcessingAdvancesOwnAuthorTransactionsWithoutMaintenance() async throws {
        let persistence = try makeSQLitePersistence()
        let store = TripStore(context: persistence.container.viewContext)
        var maintenanceCalls = 0
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.com.daviddegner.MileageTracker",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            foreignMaintenance: { _ in
                maintenanceCalls += 1
            }
        )

        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 5)
        ))

        let firstProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(firstProcessed)
        XCTAssertEqual(maintenanceCalls, 0)
        let secondProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(secondProcessed)
        XCTAssertEqual(maintenanceCalls, 0)
    }

    func testRemoteProcessingRetriesMaintenanceBeforeAdvancingHistoryToken() async throws {
        let persistence = try makeSQLitePersistence()
        var maintenanceCalls = 0
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.com.daviddegner.MileageTracker",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            foreignMaintenance: { _ in
                maintenanceCalls += 1
                if maintenanceCalls == 1 {
                    throw SyncTestError.expectedMaintenanceFailure
                }
            }
        )

        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))

        let failedAttemptProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(failedAttemptProcessed)
        XCTAssertEqual(maintenanceCalls, 1)
        let retryProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertTrue(retryProcessed)
        XCTAssertEqual(maintenanceCalls, 2)
        let afterTokenCommitProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(afterTokenCommitProcessed)
        XCTAssertEqual(maintenanceCalls, 2)
    }

    func testScheduledRemoteProcessingAutomaticallyRetriesFailedMaintenance() async throws {
        let persistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        var maintenanceCalls = 0
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.automatic-maintenance-retry",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults,
            remoteMaintenanceRetryDelays: [.milliseconds(10), .milliseconds(10)],
            foreignMaintenance: { _ in
                maintenanceCalls += 1
                if maintenanceCalls < 3 {
                    throw SyncTestError.expectedMaintenanceFailure
                }
            }
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_020_000))
        let refreshed = expectation(description: "foreign history refreshed after automatic retry")
        refreshed.assertForOverFulfill = true
        coordinator.observeRemoteChanges(in: persistence) {
            refreshed.fulfill()
        }

        coordinator.checkForRemoteChanges()

        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(maintenanceCalls, 3)
        let remainingHistory = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(remainingHistory)
        XCTAssertEqual(maintenanceCalls, 3)
    }

    func testScheduledRemoteProcessingStopsAfterConfiguredMaintenanceRetries() async throws {
        let persistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        var maintenanceCalls = 0
        let retriesExhausted = expectation(description: "configured retry attempts exhausted")
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.bounded-maintenance-retry",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults,
            remoteMaintenanceRetryDelays: [.milliseconds(10), .milliseconds(10)],
            foreignMaintenance: { _ in
                maintenanceCalls += 1
                if maintenanceCalls == 3 {
                    retriesExhausted.fulfill()
                }
                throw SyncTestError.expectedMaintenanceFailure
            }
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_025_000))
        var refreshCalls = 0
        coordinator.observeRemoteChanges(in: persistence) {
            refreshCalls += 1
        }

        coordinator.checkForRemoteChanges()

        await fulfillment(of: [retriesExhausted], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(maintenanceCalls, 3)
        XCTAssertEqual(refreshCalls, 0)

        // Exhausting the automatic retry budget leaves the token unadvanced,
        // so a later foreground check or remote notification can try again.
        let laterAttemptProcessed = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(laterAttemptProcessed)
        XCTAssertEqual(maintenanceCalls, 4)
    }

    func testExplicitHistoryCheckProcessesImportWithoutRemoteNotification() async throws {
        let persistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.activation-fallback",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults,
            foreignMaintenance: { _ in }
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_030_000))
        let refreshed = expectation(description: "foreign history refreshed")
        coordinator.observeRemoteChanges(in: persistence) {
            refreshed.fulfill()
        }

        coordinator.checkForRemoteChanges()

        await fulfillment(of: [refreshed], timeout: 2)
        let remainingHistory = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(remainingHistory)
    }

    func testRemoteChangeArrivingDuringProcessingForcesSecondHistoryPass() async throws {
        let persistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_040_000))
        var maintenanceCalls = 0
        var refreshCalls = 0
        let coordinatorReference = SyncCoordinatorReference()
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.coalesced-imports",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults,
            foreignMaintenance: { _ in
                maintenanceCalls += 1
                if maintenanceCalls == 1 {
                    try self.saveForeignTrip(
                        in: persistence,
                        start: Date(timeIntervalSince1970: 1_800_050_000)
                    )
                    coordinatorReference.value?.checkForRemoteChanges()
                }
            }
        )
        coordinatorReference.value = coordinator
        let refreshed = expectation(description: "both foreign batches refreshed")
        refreshed.expectedFulfillmentCount = 2
        coordinator.observeRemoteChanges(in: persistence) {
            refreshCalls += 1
            refreshed.fulfill()
        }

        coordinator.checkForRemoteChanges()

        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(maintenanceCalls, 2)
        XCTAssertEqual(refreshCalls, 2)
        let remainingHistory = await coordinator.processRemoteTransactions(in: persistence)
        XCTAssertFalse(remainingHistory)
    }

    func testReobservingNewStorePreventsOldTaskFromClearingOrCallingNewObserver() async throws {
        let firstPersistence = try makeSQLitePersistence()
        let secondPersistence = try makeSQLitePersistence()
        let defaults = try makeTestDefaults()
        try saveForeignTrip(
            in: firstPersistence,
            start: Date(timeIntervalSince1970: 1_800_060_000)
        )
        try saveForeignTrip(
            in: secondPersistence,
            start: Date(timeIntervalSince1970: 1_800_070_000)
        )
        var maintenanceCalls = 0
        var oldStoreRefreshCalls = 0
        var newStoreRefreshCalls = 0
        let coordinatorReference = SyncCoordinatorReference()
        let newStoreRefreshed = expectation(description: "new store history refreshed once")
        newStoreRefreshed.assertForOverFulfill = true
        let coordinator = SyncCoordinator(
            configuration: SyncConfiguration(
                containerIdentifier: "iCloud.example.store-swap",
                isAvailableInThisBuild: true,
                isEnabledThisLaunch: true
            ),
            defaults: defaults,
            foreignMaintenance: { persistence in
                maintenanceCalls += 1
                guard maintenanceCalls == 1 else { return }
                XCTAssertTrue(persistence === firstPersistence)
                coordinatorReference.value?.observeRemoteChanges(in: secondPersistence) {
                    newStoreRefreshCalls += 1
                    newStoreRefreshed.fulfill()
                }
                coordinatorReference.value?.checkForRemoteChanges()
            }
        )
        coordinatorReference.value = coordinator
        coordinator.observeRemoteChanges(in: firstPersistence) {
            oldStoreRefreshCalls += 1
        }

        coordinator.checkForRemoteChanges()

        await fulfillment(of: [newStoreRefreshed], timeout: 2)
        XCTAssertEqual(maintenanceCalls, 2)
        XCTAssertEqual(oldStoreRefreshCalls, 0)
        XCTAssertEqual(newStoreRefreshCalls, 1)
        let firstRemaining = await coordinator.processRemoteTransactions(in: firstPersistence)
        let secondRemaining = await coordinator.processRemoteTransactions(in: secondPersistence)
        XCTAssertFalse(firstRemaining)
        XCTAssertFalse(secondRemaining)
    }

    private func makeSQLitePersistence() throws -> PersistenceController {
        // Persistent history requires SQLite-backed stores; in-memory stores
        // don't record transactions.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        temporaryStoreDirectories.append(directory)
        let persistence = try PersistenceController(mode: .localOnly, inMemory: false, storeDirectory: directory)
        openPersistences.append(persistence)
        return persistence
    }

    private func saveForeignTrip(in persistence: PersistenceController, start: Date) throws {
        let background = persistence.container.newBackgroundContext()
        background.transactionAuthor = "Test.CloudKitImport"
        try background.performAndWait {
            let trip = NSEntityDescription.insertNewObject(forEntityName: "TripEntity", into: background)
            trip.setValue(UUID(), forKey: "id")
            trip.setValue(start, forKey: "createdAt")
            trip.setValue(start, forKey: "updatedAt")
            trip.setValue("manual", forKey: "captureSource")
            trip.setValue(start, forKey: "startDate")
            trip.setValue(start.addingTimeInterval(600), forKey: "endDate")
            trip.setValue(1_000.0, forKey: "distanceMeters")
            trip.setValue(600.0, forKey: "durationSeconds")
            try background.save()
        }
    }

    nonisolated private static func removePersistentStores(in container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}

private enum SyncTestError: Error {
    case expectedMaintenanceFailure
}
