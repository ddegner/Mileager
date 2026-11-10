import CoreData
import SQLite3
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class TripStoreHardeningTests: XCTestCase {
    func testInvalidDateUpdateRollsBackBeforeLaterSave() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            distanceMeters: DistanceConversion.meters(fromMiles: 1)
        ))

        XCTAssertThrowsError(try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(
                startDate: start.addingTimeInterval(900),
                endDate: start.addingTimeInterval(300)
            )
        ))

        _ = try store.updateAddresses(tripID: trip.id, startAddress: "A", endAddress: "B")
        let fetched = try store.fetchTrip(id: trip.id)

        XCTAssertEqual(fetched.startDate, start)
        XCTAssertEqual(fetched.endDate, start.addingTimeInterval(600))
        XCTAssertEqual(fetched.durationSeconds, 600, accuracy: 0.01)
        XCTAssertEqual(fetched.startAddress, "A")
        XCTAssertEqual(fetched.endAddress, "B")
    }

    func testInvalidNumericInputsAreRejectedWithoutSavingPartialChanges() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertThrowsError(try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(60),
            distanceMeters: -Double.infinity
        )))
        XCTAssertTrue(try store.fetchTrips().isEmpty)

        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(60),
            distanceMeters: DistanceConversion.meters(fromMiles: 1)
        ))

        XCTAssertThrowsError(try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(tollsAmount: .nan)
        ))
        XCTAssertEqual(try store.fetchTrip(id: trip.id).tollsAmount, 0)
    }

    func testDeterministicCrudFuzzKeepsStoreConsistent() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        var rng = SeededGenerator(seed: 0x5EED)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var activeIDs: [UUID] = []

        for step in 0..<160 {
            let action = Int.random(in: 0..<6, using: &rng)
            if activeIDs.isEmpty || action == 0 {
                let start = base.addingTimeInterval(Double(step * 700))
                let trip = try store.createManualTrip(ManualTripInput(
                    startDate: start,
                    endDate: start.addingTimeInterval(Double.random(in: 60...3_600, using: &rng)),
                    startAddress: "Origin \(step)",
                    endAddress: "Destination \(step)",
                    distanceMeters: DistanceConversion.meters(fromMiles: Double.random(in: 0...120, using: &rng)),
                    classification: Bool.random(using: &rng) ? .business : .personal,
                    businessPurpose: "Purpose \(step)",
                    notes: "Note \(step)"
                ))
                activeIDs.append(trip.id)
            } else {
                let id = activeIDs[Int.random(in: activeIDs.indices, using: &rng)]
                switch action {
                case 1:
                    _ = try store.updateReview(
                        tripID: id,
                        update: ReviewUpdate(
                            tollsAmount: Double.random(in: 0...100, using: &rng),
                            parkingAmount: Double.random(in: 0...100, using: &rng),
                            manualDistanceOverrideMeters: DistanceConversion.meters(
                                fromMiles: Double.random(in: 0...150, using: &rng)
                            )
                        )
                    )
                case 2:
                    _ = try store.updateAddresses(tripID: id, startAddress: "Updated \(step)", endAddress: "End \(step)")
                case 3:
                    _ = try store.duplicateTrip(id: id, startDate: base.addingTimeInterval(Double(10_000 + step * 800)))
                    activeIDs = try store.fetchTrips().map(\.id)
                case 4 where activeIDs.count > 2:
                    try store.deleteTrip(id: id)
                    activeIDs.removeAll { $0 == id }
                default:
                    _ = try store.fetchTrip(id: id)
                }
            }

            let fetched = try store.fetchTrips()
            XCTAssertEqual(Set(fetched.map(\.id)).count, fetched.count)
            XCTAssertTrue(fetched.allSatisfy { $0.endDate > $0.startDate })
            XCTAssertTrue(fetched.allSatisfy { $0.miles.isFinite && $0.miles >= 0 })
            XCTAssertEqual(fetched, fetched.sorted { $0.startDate > $1.startDate })
        }
    }

    func testMalformedPolylineDecodeDoesNotReturnExtremeCoordinates() {
        let inputs = [
            String(repeating: "~", count: 100),
            String(repeating: "\u{7f}", count: 100),
            "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
            "?",
            "\u{00}"
        ]

        for input in inputs {
            let decoded = EncodedPolyline.decode(input)
            if let decoded {
                XCTAssertTrue(decoded.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
                XCTAssertTrue(decoded.allSatisfy { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 })
            }
        }
    }

    func testCloudConfiguredAttributesAreOptionalOrDefaulted() {
        let model = PersistenceController.loadManagedObjectModel()
        let cloudEntities = model.entities(forConfigurationName: PersistenceController.cloudConfigurationName) ?? []
        let invalidAttributes = cloudEntities.flatMap { entity in
            entity.properties.compactMap { property -> String? in
                guard let attribute = property as? NSAttributeDescription,
                      !attribute.isOptional,
                      attribute.defaultValue == nil else {
                    return nil
                }
                return "\(entity.name ?? "Unknown").\(attribute.name)"
            }
        }

        XCTAssertTrue(
            invalidAttributes.isEmpty,
            "CloudKit attributes must be optional or have defaults: \(invalidAttributes.joined(separator: ", "))"
        )
    }

    // Plain async XCTest bodies run on a cooperative-pool thread, not the main
    // queue that `viewContext` is confined to. @MainActor serializes the
    // background-context merge and direct view-context reads in this test.
    @MainActor
    func testBackgroundContextConfigurationRollbackAndSaveIsolation() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let failedID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            _ = try await persistence.performBackgroundTask(name: "FailingMaintenance") { context -> UUID in
                let trip = TripEntity.insert(into: context)
                Self.populateTrip(trip, id: failedID, start: start)
                throw BackgroundContextTestError.expected
            }
            XCTFail("Expected background task to throw")
        } catch BackgroundContextTestError.expected {
            // Expected path.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let viewStore = TripStore(context: persistence.container.viewContext)
        XCTAssertFalse(persistence.container.viewContext.hasChanges)
        XCTAssertThrowsError(try viewStore.fetchTrip(id: failedID))

        let savedID = UUID()
        let result = try await persistence.performBackgroundTask(name: "TestMaintenance") { context in
            let trip = TripEntity.insert(into: context)
            Self.populateTrip(trip, id: savedID, start: start.addingTimeInterval(3_600))
            return (
                id: savedID,
                name: context.name,
                author: context.transactionAuthor,
                isPrivateQueue: context.concurrencyType == .privateQueueConcurrencyType
            )
        }

        XCTAssertEqual(result.name, "TestMaintenance")
        XCTAssertEqual(result.author, PersistenceController.appTransactionAuthor)
        XCTAssertTrue(result.isPrivateQueue)
        persistence.container.viewContext.reset()
        XCTAssertEqual(try viewStore.fetchTrip(id: savedID).id, savedID)
    }

    func testCurrentModelIncludesPhase3FetchIndexes() throws {
        let model = PersistenceController.loadManagedObjectModel()
        let expectedIndexes: [String: Set<String>] = [
            "TripEntity": ["byID", "byDateRange", "byArchiveAndStartDate"],
            "RawSampleEntity": ["byTripID", "byExpiresAt"],
            "DiagnosticSampleEntity": ["byTripID", "bySampleTimestamp", "byExpiresAt"],
            "DriveCaptureEventEntity": ["byDate", "byExpiresAt", "byWakeReason", "byCaptureID"],
            "PendingDriveStartSignalEntity": ["byStatusAndCreatedAt", "byUpdatedAt"],
            "BluetoothObservationEntity": ["byIdentifierHash", "byObservedAt", "byExpiresAt"],
            "TripFeeEntity": ["byTripID", "bySourceTransactionID"]
        ]

        for (entityName, expected) in expectedIndexes {
            let entity = try XCTUnwrap(model.entitiesByName[entityName])
            let actual = Set(entity.indexes.map(\.name))
            XCTAssertTrue(
                actual.isSuperset(of: expected),
                "\(entityName) missing fetch indexes: \(expected.subtracting(actual))"
            )
        }
    }

    func testIndexedModelMigratesPreviousModelStore() throws {
        let storeDirectory = try makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let cloudStoreURL = storeDirectory.appendingPathComponent("MileageTracker.sqlite")
        let localStoreURL = storeDirectory.appendingPathComponent("MileageTrackerRaw.sqlite")
        let oldModelURL = try XCTUnwrap(
            PersistenceController.managedObjectModelURL(versionName: "MileageTracker")
        )
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: oldModelURL))
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let oldContainer = NSPersistentContainer(name: "MileageTracker", managedObjectModel: oldModel)
        let description = NSPersistentStoreDescription(url: cloudStoreURL)
        description.configuration = PersistenceController.cloudConfigurationName
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        oldContainer.persistentStoreDescriptions = [description]
        try loadPersistentStores(in: oldContainer)

        let trip = NSEntityDescription.insertNewObject(forEntityName: "TripEntity", into: oldContainer.viewContext)
        Self.populateTrip(trip, id: tripID, start: start)
        try oldContainer.viewContext.save()
        try removePersistentStores(in: oldContainer)
        XCTAssertFalse(try sqliteIndexNames(at: cloudStoreURL).contains("Z_TripEntity_byID"))

        do {
            let migrated = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
            let fetched = try TripStore(context: migrated.container.viewContext).fetchTrip(id: tripID)

            XCTAssertEqual(fetched.id, tripID)
            XCTAssertEqual(fetched.startDate, start)
            XCTAssertEqual(fetched.distanceMeters, DistanceConversion.meters(fromMiles: 1), accuracy: 0.01)
            try removePersistentStores(in: migrated.container)
        }

        let cloudIndexes = try sqliteIndexNames(at: cloudStoreURL)
        XCTAssertTrue(cloudIndexes.isSuperset(of: [
            "Z_TripEntity_byID",
            "Z_TripEntity_byDateRange",
            "Z_TripEntity_byArchiveAndStartDate",
            "Z_TripFeeEntity_byTripID",
            "Z_TripFeeEntity_bySourceTransactionID"
        ]))
        let localIndexes = try sqliteIndexNames(at: localStoreURL)
        XCTAssertTrue(localIndexes.isSuperset(of: [
            "Z_RawSampleEntity_byTripID",
            "Z_RawSampleEntity_byExpiresAt",
            "Z_PendingDriveStartSignalEntity_byStatusAndCreatedAt",
            "Z_PendingDriveStartSignalEntity_byUpdatedAt",
            "Z_BluetoothObservationEntity_byIdentifierHash"
        ]))

        let beforeReopen = try sqliteIndexNames(at: cloudStoreURL)
        do {
            let reopened = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
            try removePersistentStores(in: reopened.container)
        }
        XCTAssertEqual(try sqliteIndexNames(at: cloudStoreURL), beforeReopen)
    }

    func testSQLiteFetchIndexMaintenanceSkipsInMemoryStores() throws {
        _ = try PersistenceController(inMemory: true)
    }

    private static func populateTrip(
        _ trip: NSManagedObject,
        id: UUID,
        start: Date,
        duration: TimeInterval = 600,
        distanceMeters: Double = DistanceConversion.meters(fromMiles: 1)
    ) {
        trip.setValue(id, forKey: "id")
        trip.setValue(start, forKey: "createdAt")
        trip.setValue(start, forKey: "updatedAt")
        trip.setValue("automatic", forKey: "captureSource")
        trip.setValue(start, forKey: "startDate")
        trip.setValue(start.addingTimeInterval(duration), forKey: "endDate")
        trip.setValue(distanceMeters, forKey: "distanceMeters")
        trip.setValue(duration, forKey: "durationSeconds")
        trip.setValue("needsReview", forKey: "reviewStatusRaw")
        trip.setValue(0, forKey: "tollsAmount")
        trip.setValue(0, forKey: "parkingAmount")
        trip.setValue(false, forKey: "needsAttention")
    }

    private func loadPersistentStores(in container: NSPersistentContainer) throws {
        var loadErrors: [Error] = []
        container.loadPersistentStores { _, error in
            if let error {
                loadErrors.append(error)
            }
        }
        if !loadErrors.isEmpty {
            throw PersistenceError.failedToLoad(loadErrors)
        }
    }

    private func removePersistentStores(in container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    private func sqliteIndexNames(at storeURL: URL) throws -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw SQLiteTestError.openFailed
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT name FROM sqlite_master WHERE type = 'index'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteTestError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    names.insert(String(cString: text))
                }
            case SQLITE_DONE:
                return names
            default:
                throw SQLiteTestError.stepFailed
            }
        }
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileageTrackerPhase3StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

}

private enum BackgroundContextTestError: Error {
    case expected
}

private enum SQLiteTestError: Error {
    case openFailed
    case prepareFailed
    case stepFailed
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
