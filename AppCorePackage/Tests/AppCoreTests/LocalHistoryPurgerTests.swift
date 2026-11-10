import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

/// The Local store's persistent history has no consumer and must be purged
/// without ever touching the Cloud store's history (which
/// `NSPersistentCloudKitContainer` owns and `PersistentHistoryMonitor` reads).
@MainActor
final class LocalHistoryPurgerTests: XCTestCase {
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

    func testPurgeDeletesLocalStoreHistoryAndPreservesCloudHistory() async throws {
        let persistence = try makePersistence()
        for offset in 0..<5 {
            try saveLocalSample(in: persistence, timestamp: Date().addingTimeInterval(Double(offset) - 10))
        }
        try saveCloudTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_000_000))
        try saveCloudTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        XCTAssertGreaterThan(try historyTransactionCount(in: persistence, configurationName: PersistenceController.localConfigurationName), 0)

        let slices = try await LocalHistoryPurger(interSliceDelay: .milliseconds(1))
            .purgeAllLocalHistory(on: persistence)

        XCTAssertGreaterThan(slices, 0)
        XCTAssertEqual(
            try historyTransactionCount(in: persistence, configurationName: PersistenceController.localConfigurationName),
            0,
            "All Local-store history must be gone"
        )
        XCTAssertEqual(
            try historyTransactionCount(in: persistence, configurationName: PersistenceController.cloudConfigurationName),
            2,
            "Cloud-store history must be untouched"
        )
    }

    func testPurgeSlicesOldestFirst() async throws {
        let persistence = try makePersistence()
        try saveLocalSample(in: persistence, timestamp: Date())
        try saveLocalSample(in: persistence, timestamp: Date())
        // Real wall-clock separation: history slicing keys off the recorded
        // transaction timestamps, which cannot be injected.
        try await Task.sleep(for: .milliseconds(250))
        try saveLocalSample(in: persistence, timestamp: Date())

        let slices = try await LocalHistoryPurger(sliceLength: 0.1, interSliceDelay: .milliseconds(1))
            .purgeAllLocalHistory(on: persistence)

        XCTAssertGreaterThanOrEqual(slices, 2, "Groups 250 ms apart cannot fit one 100 ms slice")
        XCTAssertEqual(
            try historyTransactionCount(in: persistence, configurationName: PersistenceController.localConfigurationName),
            0
        )
    }

    func testPurgeNoOpsOnInMemoryStores() async throws {
        let persistence = try PersistenceController(inMemory: true)
        persistences.append(persistence)

        let slices = try await LocalHistoryPurger().purgeAllLocalHistory(on: persistence)

        XCTAssertEqual(slices, 0)
    }

    func testPurgeNoOpsWhenLocalStoreAbsent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalHistoryPurgerTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let persistence = try PersistenceController(
            mode: .localOnly,
            scope: .cloudOnly,
            inMemory: false,
            storeDirectory: directory
        )
        persistences.append(persistence)

        let slices = try await LocalHistoryPurger().purgeAllLocalHistory(on: persistence)

        XCTAssertEqual(slices, 0)
    }

    func testSchedulePurgeRunsOncePerController() throws {
        // A long initial delay keeps the scheduled task from ever running
        // inside the test; only the scheduling decision is under test.
        let purger = LocalHistoryPurger(initialDelay: .seconds(600))
        let first = try makePersistence()
        let second = try makePersistence()

        XCTAssertTrue(purger.schedulePurgeIfNeeded(on: first))
        XCTAssertFalse(purger.schedulePurgeIfNeeded(on: first))
        XCTAssertTrue(purger.schedulePurgeIfNeeded(on: second))
        XCTAssertFalse(purger.schedulePurgeIfNeeded(on: second))
    }

    func testPurgeLeavesMonitorCloudTokenUsable() async throws {
        let persistence = try makePersistence()
        let suite = "LocalHistoryPurgerTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let monitor = PersistentHistoryMonitor(
            containerIdentifier: "iCloud.example.purger-tests",
            tokenKeyPrefix: "PurgerTests.token",
            defaults: defaults,
            foreignMaintenance: { _ in }
        )

        try saveCloudTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_000_000))
        let beforePurge = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(beforePurge)

        try saveLocalSample(in: persistence, timestamp: Date())
        _ = try await LocalHistoryPurger(interSliceDelay: .milliseconds(1))
            .purgeAllLocalHistory(on: persistence)

        try saveCloudTrip(in: persistence, start: Date(timeIntervalSince1970: 1_800_010_000))
        let afterPurge = await monitor.processForeignTransactions(in: persistence)
        XCTAssertTrue(afterPurge, "The saved token must survive a Local-store purge")
        let quiet = await monitor.processForeignTransactions(in: persistence)
        XCTAssertFalse(quiet)
    }

    // MARK: - Fixtures

    private func makePersistence() throws -> PersistenceController {
        // Persistent history requires SQLite-backed stores; in-memory stores
        // don't record transactions.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalHistoryPurgerTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let persistence = try PersistenceController(
            mode: .localOnly,
            inMemory: false,
            storeDirectory: directory
        )
        persistences.append(persistence)
        return persistence
    }

    private func historyTransactionCount(
        in persistence: PersistenceController,
        configurationName: String
    ) throws -> Int {
        let context = persistence.container.viewContext
        guard let store = persistence.container.persistentStoreCoordinator.persistentStores.first(where: {
            $0.configurationName == configurationName
        }) else {
            return 0
        }
        let fetch = NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)
        fetch.affectedStores = [store]
        guard let result = try context.execute(fetch) as? NSPersistentHistoryResult else {
            return 0
        }
        return (result.result as? [NSPersistentHistoryTransaction])?.count ?? 0
    }

    private func saveLocalSample(in persistence: PersistenceController, timestamp: Date) throws {
        let background = persistence.container.newBackgroundContext()
        background.transactionAuthor = "Test.Capture"
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

    private func saveCloudTrip(in persistence: PersistenceController, start: Date) throws {
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
