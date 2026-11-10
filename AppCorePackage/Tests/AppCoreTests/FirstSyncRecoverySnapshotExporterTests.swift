import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class FirstSyncRecoverySnapshotExporterTests: XCTestCase {
    func testSnapshotCopiesCompleteCloudAndLocalLibraryWithoutMutatingSource() async throws {
        let source = try PersistenceController(inMemory: true)
        let context = source.container.viewContext
        let tripStore = TripStore(context: context)
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Work Van")
        _ = try BusinessPurposePresetStore(context: context).savePurposes([
            "Client meeting",
            "Site visit"
        ])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
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
                timestamp: start.addingTimeInterval(900),
                latitude: 42.3701,
                longitude: -71.0489,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 0,
                motionHint: .stationary
            )
        ]
        let trip = try tripStore.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(900),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples),
            classification: .business,
            businessPurpose: "Client meeting",
            fees: [TripFee(
                tripID: UUID(),
                category: .parking,
                amount: 8,
                occurredAt: start.addingTimeInterval(600)
            )],
            notes: "Bring signed plans",
            vehicleID: vehicle.id,
            vehicleAssignmentSource: .manual
        ))
        let sourceTripCount = try tripStore.fetchTrips().count
        let sourceRawCount = try tripStore.rawSampleCount()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FirstSyncRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try await FirstSyncRecoverySnapshotExporter.makeSnapshot(
            from: source.container,
            destinationRootURL: root,
            generatedAt: start.addingTimeInterval(1_800)
        )

        XCTAssertEqual(snapshot.rowCounts["TripEntity"], 1)
        XCTAssertEqual(snapshot.rowCounts["RawSampleEntity"], samples.count)
        XCTAssertEqual(snapshot.rowCounts["TripFeeEntity"], 1)
        XCTAssertEqual(snapshot.rowCounts["VehicleEntity"], 1)
        XCTAssertEqual(snapshot.rowCounts["PreferenceEntity"], 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: snapshot.directoryURL
                .appendingPathComponent(FirstSyncRecoverySnapshotExporter.manifestFileName)
                .path
        ))
        XCTAssertEqual(try tripStore.fetchTrips().count, sourceTripCount)
        XCTAssertEqual(try tripStore.rawSampleCount(), sourceRawCount)

        let recovered = try PersistenceController(
            mode: .localOnly,
            storeDirectory: snapshot.directoryURL
        )
        let recoveredTripStore = TripStore(context: recovered.container.viewContext)
        let recoveredTrip = try recoveredTripStore.fetchTrip(id: trip.id)
        XCTAssertEqual(recoveredTrip.businessPurpose, "Client meeting")
        XCTAssertEqual(recoveredTrip.notes, "Bring signed plans")
        XCTAssertEqual(recoveredTrip.vehicleID, vehicle.id)
        XCTAssertNotNil(recoveredTrip.routePolyline)
        XCTAssertEqual(try recoveredTripStore.rawSampleCount(tripID: trip.id), samples.count)
        XCTAssertEqual(
            try BusinessPurposePresetStore(context: recovered.container.viewContext).fetchPurposes(),
            ["Client meeting", "Site visit"]
        )
        XCTAssertEqual(
            try VehicleStore(context: recovered.container.viewContext).fetchVehicles().map(\.name),
            ["Work Van"]
        )
    }

    func testNewSnapshotReplacesOlderRecoveryDirectory() async throws {
        let source = try PersistenceController(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FirstSyncRecoveryRetentionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await FirstSyncRecoverySnapshotExporter.makeSnapshot(
            from: source.container,
            destinationRootURL: root
        )
        let second = try await FirstSyncRecoverySnapshotExporter.makeSnapshot(
            from: source.container,
            destinationRootURL: root
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directoryURL.path))
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        XCTAssertEqual(
            directories.map { $0.standardizedFileURL.path },
            [second.directoryURL.standardizedFileURL.path]
        )
    }

    func testConcurrentSourceSaveRejectsAndRemovesMixedTimeSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FirstSyncConcurrentMutationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let snapshotDirectory = root.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try PersistenceController(
            mode: .localOnly,
            storeDirectory: sourceDirectory
        )
        let store = TripStore(context: source.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            distanceMeters: 1_000
        ))
        let injector = SnapshotMutationInjector(
            container: source.container,
            startDate: start.addingTimeInterval(3_600)
        )

        do {
            _ = try await FirstSyncRecoverySnapshotExporter.makeSnapshot(
                from: source.container,
                destinationRootURL: snapshotDirectory,
                beforeCopyEntity: injector.mutateBeforeCopy
            )
            XCTFail("A source save during export must reject the recovery copy")
        } catch FirstSyncRecoverySnapshotError.sourceChangedDuringSnapshot {
            // Expected: the caller can retry without enabling sync.
        }

        XCTAssertEqual(try store.fetchTrips().count, 2)
        let retainedSnapshots = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        XCTAssertTrue(retainedSnapshots.isEmpty)
    }
}

private final class SnapshotMutationInjector: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let startDate: Date

    init(container: NSPersistentContainer, startDate: Date) {
        self.container = container
        self.startDate = startDate
    }

    func mutateBeforeCopy(entityName: String) throws {
        guard entityName == ActiveDriveEntity.entityName else { return }
        let writer = container.newBackgroundContext()
        try writer.performAndWait {
            _ = try TripStore(context: writer).createManualTrip(ManualTripInput(
                startDate: startDate,
                endDate: startDate.addingTimeInterval(600),
                distanceMeters: 2_000
            ))
        }
    }
}
