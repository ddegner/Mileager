import CoreData
import XCTest
@testable import AppCore

final class PersistentHistoryTokenStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var persistences: [PersistenceController] = []
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for persistence in persistences {
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try? persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        for suite in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        persistences.removeAll()
        temporaryDirectories.removeAll()
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testKeysAreIsolatedByContainerAndCloudStoreGeneration() throws {
        let defaults = try makeDefaults()
        let firstPersistence = try makePersistence()
        let secondPersistence = try makePersistence()
        let firstContainer = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "history",
            containerIdentifier: "iCloud.example.one"
        )
        let secondContainer = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "history",
            containerIdentifier: "iCloud.example.two"
        )

        let firstKey = try XCTUnwrap(firstContainer.defaultsKey(for: firstPersistence))
        let secondStoreKey = try XCTUnwrap(firstContainer.defaultsKey(for: secondPersistence))
        let secondContainerKey = try XCTUnwrap(secondContainer.defaultsKey(for: firstPersistence))

        XCTAssertNotEqual(firstKey, secondStoreKey)
        XCTAssertNotEqual(firstKey, secondContainerKey)
        XCTAssertTrue(firstKey.contains("iCloud.example.one"))
        XCTAssertTrue(firstKey.contains(try XCTUnwrap(
            PersistentHistoryTokenStore.cloudStoreUUID(for: firstPersistence)
        )))
    }

    func testSavedTokenCannotLeakToAnotherStoreOrContainer() throws {
        let defaults = try makeDefaults()
        let firstPersistence = try makePersistence()
        let secondPersistence = try makePersistence()
        let firstContainer = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "history",
            containerIdentifier: "iCloud.example.one"
        )
        let secondContainer = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "history",
            containerIdentifier: "iCloud.example.two"
        )
        let token = try makeHistoryToken(in: firstPersistence)

        firstContainer.save(token, for: firstPersistence)

        XCTAssertNotNil(firstContainer.token(for: firstPersistence))
        XCTAssertNil(firstContainer.token(for: secondPersistence))
        XCTAssertNil(secondContainer.token(for: firstPersistence))
    }

    func testCorruptArchiveFailsClosedAndCanBeCleared() throws {
        let defaults = try makeDefaults()
        let persistence = try makePersistence()
        let tokens = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: "history",
            containerIdentifier: "iCloud.example"
        )
        let key = try XCTUnwrap(tokens.defaultsKey(for: persistence))
        defaults.set(Data("not-a-token".utf8), forKey: key)

        XCTAssertNil(tokens.token(for: persistence))
        tokens.clear(for: persistence)
        XCTAssertNil(defaults.data(forKey: key))
    }

    private func makePersistence() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentHistoryTokenStoreTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let persistence = try PersistenceController(
            mode: .localOnly,
            inMemory: false,
            storeDirectory: directory
        )
        persistences.append(persistence)
        return persistence
    }

    private func makeHistoryToken(in persistence: PersistenceController) throws -> NSPersistentHistoryToken {
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            distanceMeters: 1_000
        ))
        let request = NSPersistentHistoryChangeRequest.fetchHistory(
            after: nil as NSPersistentHistoryToken?
        )
        let result = try XCTUnwrap(
            try persistence.container.viewContext.execute(request) as? NSPersistentHistoryResult
        )
        let transactions = try XCTUnwrap(result.result as? [NSPersistentHistoryTransaction])
        return try XCTUnwrap(transactions.last?.token)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "PersistentHistoryTokenStoreTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
