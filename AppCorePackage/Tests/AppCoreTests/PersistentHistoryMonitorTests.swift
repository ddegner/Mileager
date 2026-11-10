import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

/// Behavioral suite for the shared sync core, ported from the app-hosted
/// `SyncAndResetCoordinatorTests` (retry ladder, coalescing, store-swap
/// generations, token scoping) and `MacSyncCoordinatorTests`, plus the
/// token-policy trio that neither platform could test before the
/// `fetchHistoryOverride` seam existed.
@MainActor
final class PersistentHistoryMonitorTests: XCTestCase {
    private final class MonitorReference {
        weak var value: PersistentHistoryMonitor?
    }

    private enum MonitorTestError: Error {
        case expectedMaintenanceFailure
        case expectedFetchFailure
    }

    nonisolated(unsafe) private var temporaryDirectories: [URL] = []
    nonisolated(unsafe) private var persistences: [PersistenceController] = []
    nonisolated(unsafe) private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for persistence in persistences {
            let coordinator = persistence.container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        persistences.removeAll()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        for suite in defaultsSuiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    // MARK: - Foreign-author detection and token advancement

    func testOwnAuthorTransactionsDoNotReportForeignChanges() async throws {
        let persistence = try makePersistence()
        let store = TripStore(context: persistence.container.viewContext)
        var maintenanceCalls = 0
        let monitor = try makeMonitor(foreignMaintenance: { _ in maintenanceCalls += 1 })

        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 5)
        ))

        let firstProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(firstProcessed)
        XCTAssertEqual(maintenanceCalls, 0)
        // Token advanced past our own transactions; a second pass stays quiet.
        let secondProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(secondProcessed)
        XCTAssertEqual(maintenanceCalls, 0)
    }

    func testForeignAuthorTransactionsReportOnceAndAdvanceToken() async throws {
        let persistence = try makePersistence()
        let store = TripStore(context: persistence.container.viewContext)
        let monitor = try makeMonitor(foreignMaintenance: { _ in })

        _ = try store.createManualTrip(ManualTripInput(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 5)
        ))
        let ownProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(ownProcessed)

        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))

        let foreignProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(foreignProcessed)
        // Token advanced past the foreign transaction too.
        let afterProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(afterProcessed)
    }

    func testHistoryTokensAreIsolatedByCloudKitContainer() async throws {
        let persistence = try makePersistence()
        let defaults = try makeDefaults()
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let first = PersistentHistoryMonitor(
            containerIdentifier: "iCloud.example.first",
            tokenKeyPrefix: "MonitorTests.token",
            defaults: defaults,
            foreignMaintenance: { _ in }
        )
        let second = PersistentHistoryMonitor(
            containerIdentifier: "iCloud.example.second",
            tokenKeyPrefix: "MonitorTests.token",
            defaults: defaults,
            foreignMaintenance: { _ in }
        )

        let firstProcessed = await first.processForeignTransactions(in: persistence)
        XCTAssertTrue(firstProcessed)
        let secondProcessed = await second.processForeignTransactions(in: persistence)
        XCTAssertTrue(
            secondProcessed,
            "A different CloudKit container must start from its own history namespace"
        )
    }

    func testMismatchedStoreTokenIsClearedAndHistoryIsReplayed() async throws {
        let firstPersistence = try makePersistence()
        let secondPersistence = try makePersistence()
        let defaults = try makeDefaults()
        let containerIdentifier = "iCloud.example.history-recovery"
        let monitor = PersistentHistoryMonitor(
            containerIdentifier: containerIdentifier,
            tokenKeyPrefix: "MonitorTests.token",
            defaults: defaults,
            foreignMaintenance: { _ in }
        )
        let tokens = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "MonitorTests.token",
            containerIdentifier: containerIdentifier
        )
        try saveForeignTrip(in: firstPersistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let firstProcessed = await monitor.processForeignTransactions(in: firstPersistence)
        XCTAssertTrue(firstProcessed)
        let foreignStoreToken = try XCTUnwrap(tokens.token(for: firstPersistence))
        tokens.save(foreignStoreToken, for: secondPersistence)
        try saveForeignTrip(in: secondPersistence, start: Date(timeIntervalSince1970: 1_800_020_000))

        let replayProcessed = await monitor.processForeignTransactions(in: secondPersistence)
        XCTAssertTrue(
            replayProcessed,
            "An opaque token from another store must fall back to retained history"
        )
        let afterProcessed = await monitor.processForeignTransactions(in: secondPersistence)
        XCTAssertFalse(afterProcessed)
    }

    func testLocalStoreForeignChurnDoesNotReportForeignChanges() async throws {
        let persistence = try makePersistence()
        var maintenanceCalls = 0
        let monitor = try makeMonitor(foreignMaintenance: { _ in maintenanceCalls += 1 })

        // Capture writes land in the Local store thousands of times per drive;
        // even a foreign-authored one must never read as a CloudKit import.
        try saveLocalSample(
            in: persistence,
            author: "Test.CloudKitImport",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let firstProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(firstProcessed, "Local-store churn must be invisible to sync detection")
        XCTAssertEqual(maintenanceCalls, 0)
        let secondProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(secondProcessed)
        XCTAssertEqual(maintenanceCalls, 0)
    }

    func testLocalStoreChurnDoesNotHideForeignCloudChanges() async throws {
        let persistence = try makePersistence()
        var maintenanceCalls = 0
        let monitor = try makeMonitor(foreignMaintenance: { _ in maintenanceCalls += 1 })

        try saveLocalSample(
            in: persistence,
            author: "Test.CloudKitImport",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        try saveLocalSample(
            in: persistence,
            author: "Test.CloudKitImport",
            timestamp: Date(timeIntervalSince1970: 1_800_020_000)
        )

        let foreignProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(foreignProcessed, "Cloud-store foreign imports must still be detected")
        XCTAssertEqual(maintenanceCalls, 1)
        let afterProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(afterProcessed)
        XCTAssertEqual(maintenanceCalls, 1)
    }

    // MARK: - Maintenance ordering and the retry ladder

    func testMaintenanceFailureRetainsTokenUntilRetrySucceeds() async throws {
        let persistence = try makePersistence()
        var maintenanceCalls = 0
        let monitor = try makeMonitor(foreignMaintenance: { _ in
            maintenanceCalls += 1
            if maintenanceCalls == 1 {
                throw MonitorTestError.expectedMaintenanceFailure
            }
        })

        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))

        let failedAttemptProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(failedAttemptProcessed)
        XCTAssertEqual(maintenanceCalls, 1)
        let retryProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(retryProcessed)
        XCTAssertEqual(maintenanceCalls, 2)
        let afterTokenCommitProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(afterTokenCommitProcessed)
        XCTAssertEqual(maintenanceCalls, 2)
    }

    func testScheduledProcessingAutomaticallyRetriesFailedMaintenance() async throws {
        let persistence = try makePersistence()
        var maintenanceCalls = 0
        let monitor = try makeMonitor(
            maintenanceRetryDelays: [.milliseconds(10), .milliseconds(10)],
            foreignMaintenance: { _ in
                maintenanceCalls += 1
                if maintenanceCalls < 3 {
                    throw MonitorTestError.expectedMaintenanceFailure
                }
            }
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_020_000))
        let refreshed = expectation(description: "foreign history refreshed after automatic retry")
        refreshed.assertForOverFulfill = true
        monitor.observe(on: persistence, onForeignChange: {
            refreshed.fulfill()
        })

        monitor.checkForRemoteChanges()

        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(maintenanceCalls, 3)
        let remainingHistory = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(remainingHistory)
        XCTAssertEqual(maintenanceCalls, 3)
    }

    func testScheduledProcessingStopsAfterConfiguredMaintenanceRetries() async throws {
        let persistence = try makePersistence()
        var maintenanceCalls = 0
        let retriesExhausted = expectation(description: "configured retry attempts exhausted")
        let monitor = try makeMonitor(
            maintenanceRetryDelays: [.milliseconds(10), .milliseconds(10)],
            foreignMaintenance: { _ in
                maintenanceCalls += 1
                if maintenanceCalls == 3 {
                    retriesExhausted.fulfill()
                }
                throw MonitorTestError.expectedMaintenanceFailure
            }
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_025_000))
        var refreshCalls = 0
        monitor.observe(on: persistence, onForeignChange: {
            refreshCalls += 1
        })

        monitor.checkForRemoteChanges()

        await fulfillment(of: [retriesExhausted], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(maintenanceCalls, 3)
        XCTAssertEqual(refreshCalls, 0)

        // Exhausting the automatic retry budget leaves the token unadvanced,
        // so a later foreground check or remote notification can try again.
        let laterAttemptProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(laterAttemptProcessed)
        XCTAssertEqual(maintenanceCalls, 4)
    }

    // MARK: - Scheduling: activation fallback, coalescing, store swap

    func testExplicitHistoryCheckProcessesImportWithoutRemoteNotification() async throws {
        let persistence = try makePersistence()
        let monitor = try makeMonitor(foreignMaintenance: { _ in })
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_030_000))
        let refreshed = expectation(description: "foreign history refreshed")
        monitor.observe(on: persistence, onForeignChange: {
            refreshed.fulfill()
        })

        monitor.checkForRemoteChanges()

        await fulfillment(of: [refreshed], timeout: 2)
        let remainingHistory = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(remainingHistory)
    }

    func testRemoteChangeArrivingDuringProcessingForcesSecondHistoryPass() async throws {
        let persistence = try makePersistence()
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_040_000))
        var maintenanceCalls = 0
        var refreshCalls = 0
        let monitorReference = MonitorReference()
        let monitor = try makeMonitor(foreignMaintenance: { _ in
            maintenanceCalls += 1
            if maintenanceCalls == 1 {
                try self.saveForeignTrip(
                    in: persistence,
                    start: Date(timeIntervalSince1970: 1_800_050_000)
                )
                monitorReference.value?.checkForRemoteChanges()
            }
        })
        monitorReference.value = monitor
        let refreshed = expectation(description: "both foreign batches refreshed")
        refreshed.expectedFulfillmentCount = 2
        monitor.observe(on: persistence, onForeignChange: {
            refreshCalls += 1
            refreshed.fulfill()
        })

        monitor.checkForRemoteChanges()

        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(maintenanceCalls, 2)
        XCTAssertEqual(refreshCalls, 2)
        let remainingHistory = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(remainingHistory)
    }

    func testReobservingNewStorePreventsOldTaskFromCallingNewObserver() async throws {
        let firstPersistence = try makePersistence()
        let secondPersistence = try makePersistence()
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
        let monitorReference = MonitorReference()
        let newStoreRefreshed = expectation(description: "new store history refreshed once")
        newStoreRefreshed.assertForOverFulfill = true
        let monitor = try makeMonitor(foreignMaintenance: { persistence in
            maintenanceCalls += 1
            guard maintenanceCalls == 1 else { return }
            XCTAssertTrue(persistence === firstPersistence)
            monitorReference.value?.observe(on: secondPersistence, onForeignChange: {
                newStoreRefreshCalls += 1
                newStoreRefreshed.fulfill()
            })
            monitorReference.value?.checkForRemoteChanges()
        })
        monitorReference.value = monitor
        monitor.observe(on: firstPersistence, onForeignChange: {
            oldStoreRefreshCalls += 1
        })

        monitor.checkForRemoteChanges()

        await fulfillment(of: [newStoreRefreshed], timeout: 2)
        XCTAssertEqual(maintenanceCalls, 2)
        XCTAssertEqual(oldStoreRefreshCalls, 0)
        XCTAssertEqual(newStoreRefreshCalls, 1)
        let firstRemaining = await monitor.processForeignTransactions(in: firstPersistence)
        let secondRemaining = await monitor.processForeignTransactions(in: secondPersistence)
        XCTAssertFalse(firstRemaining)
        XCTAssertFalse(secondRemaining)
    }

    // MARK: - Token policy on history-fetch failure (the adopted hardening)

    func testFetchFailureAfterSavedTokenReplaysAndProcessesForeignHistory() async throws {
        let persistence = try makePersistence()
        let defaults = try makeDefaults()
        let containerIdentifier = "iCloud.example.fetch-failure-replay"
        let monitor = PersistentHistoryMonitor(
            containerIdentifier: containerIdentifier,
            tokenKeyPrefix: "MonitorTests.token",
            defaults: defaults,
            foreignMaintenance: { _ in }
        )
        let tokens = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "MonitorTests.token",
            containerIdentifier: containerIdentifier
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let seeded = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(seeded)
        XCTAssertNotNil(tokens.token(for: persistence))
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_020_000))

        // The saved-token fetch throws; the nil-token replay hits the real
        // store and succeeds, so the pass still reports the foreign change.
        monitor.fetchHistoryOverride = { token, context in
            guard token == nil else {
                throw MonitorTestError.expectedFetchFailure
            }
            let request = NSPersistentHistoryChangeRequest.fetchHistory(
                after: nil as NSPersistentHistoryToken?
            )
            let result = try context.execute(request) as? NSPersistentHistoryResult
            return result?.result as? [NSPersistentHistoryTransaction]
        }

        let replayProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(replayProcessed)
        XCTAssertNotNil(
            tokens.token(for: persistence),
            "The replayed pass must commit a fresh token after maintenance succeeds"
        )
        monitor.fetchHistoryOverride = nil
        let afterProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(afterProcessed)
    }

    func testFetchFailureWithFailingReplayRetainsSavedToken() async throws {
        let persistence = try makePersistence()
        let defaults = try makeDefaults()
        let containerIdentifier = "iCloud.example.fetch-failure-retained"
        let monitor = PersistentHistoryMonitor(
            containerIdentifier: containerIdentifier,
            tokenKeyPrefix: "MonitorTests.token",
            defaults: defaults,
            foreignMaintenance: { _ in }
        )
        let tokens = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "MonitorTests.token",
            containerIdentifier: containerIdentifier
        )
        try saveForeignTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let seeded = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(seeded)
        let savedToken = try XCTUnwrap(tokens.token(for: persistence))

        var surfacedErrors: [Error] = []
        monitor.observe(
            on: persistence,
            onForeignChange: { XCTFail("A failed pass must not report a foreign change") },
            onProcessingError: { surfacedErrors.append($0) }
        )
        monitor.fetchHistoryOverride = { _, _ in
            throw MonitorTestError.expectedFetchFailure
        }

        let failedProcessed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(failedProcessed)
        XCTAssertEqual(surfacedErrors.count, 1)
        XCTAssertEqual(
            tokens.token(for: persistence),
            savedToken,
            "A transient store failure must never erase sync progress"
        )
    }

    func testFetchFailureWithoutSavedTokenSurfacesErrorWithoutClearing() async throws {
        let persistence = try makePersistence()
        let monitor = try makeMonitor(foreignMaintenance: { _ in })
        var surfacedErrors: [Error] = []
        monitor.observe(
            on: persistence,
            onForeignChange: { XCTFail("A failed pass must not report a foreign change") },
            onProcessingError: { surfacedErrors.append($0) }
        )
        monitor.fetchHistoryOverride = { _, _ in
            throw MonitorTestError.expectedFetchFailure
        }

        let processed = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(processed)
        XCTAssertEqual(surfacedErrors.count, 1)
    }

    // MARK: - Fixtures

    private func makeMonitor(
        maintenanceRetryDelays: [Duration] = [
            .seconds(1),
            .seconds(3),
            .seconds(10)
        ],
        foreignMaintenance: @escaping @MainActor (PersistenceController) async throws -> Void
    ) throws -> PersistentHistoryMonitor {
        PersistentHistoryMonitor(
            containerIdentifier: "iCloud.example.monitor-tests",
            tokenKeyPrefix: "MonitorTests.token",
            defaults: try makeDefaults(),
            maintenanceRetryDelays: maintenanceRetryDelays,
            foreignMaintenance: foreignMaintenance
        )
    }

    private func makePersistence() throws -> PersistenceController {
        // Persistent history requires SQLite-backed stores; in-memory stores
        // don't record transactions.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentHistoryMonitorTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let persistence = try PersistenceController(
            mode: .localOnly,
            inMemory: false,
            storeDirectory: directory
        )
        persistences.append(persistence)
        return persistence
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "PersistentHistoryMonitorTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func saveLocalSample(
        in persistence: PersistenceController,
        author: String,
        timestamp: Date
    ) throws {
        let background = persistence.container.newBackgroundContext()
        background.transactionAuthor = author
        try background.performAndWait {
            let sample = NSEntityDescription.insertNewObject(forEntityName: "RawSampleEntity", into: background)
            sample.setValue(UUID(), forKey: "id")
            sample.setValue(UUID(), forKey: "tripID")
            sample.setValue(timestamp, forKey: "timestamp")
            sample.setValue(40.6892, forKey: "latitude")
            sample.setValue(-74.0445, forKey: "longitude")
            sample.setValue(5.0, forKey: "horizontalAccuracy")
            sample.setValue("automotive", forKey: "motionHintRaw")
            sample.setValue(timestamp.addingTimeInterval(86_400), forKey: "expiresAt")
            try background.save()
        }
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
}
