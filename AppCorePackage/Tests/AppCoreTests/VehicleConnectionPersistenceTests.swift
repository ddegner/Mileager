import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class VehicleConnectionPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testObservationPersistsConnectionKindAndIdentityQuality() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)

        let observation = try store.recordObservation(
            identifier: "carplay-port",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )

        XCTAssertEqual(observation.connectionKind, .carPlay)
        XCTAssertEqual(observation.identityQuality, .stablePortIdentifier)
        let hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(hint.connectionKind, .carPlay)
        XCTAssertEqual(hint.identityQuality, .stablePortIdentifier)
        XCTAssertEqual(hint.mappingDisposition, .unreviewed)
        let fetched = try XCTUnwrap(try store.observations(near: now).first)
        XCTAssertEqual(fetched.connectionKind, .carPlay)
        XCTAssertEqual(fetched.identityQuality, .stablePortIdentifier)
    }

    func testAssignmentCreatesCloudAliasWithoutLocalIdentifier() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let vehicle = try vehicles.createVehicle(name: "Forester")
        let observation = try store.recordObservation(
            identifier: "private-port-uid",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )

        let assigned = try store.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: vehicle.id,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(assigned.vehicleID, vehicle.id)
        XCTAssertEqual(assigned.mappingDisposition, .assigned)
        XCTAssertNotNil(assigned.connectionAliasID)
        let alias = try XCTUnwrap(try store.fetchConnectionAliases().first)
        XCTAssertEqual(alias.id, assigned.connectionAliasID)
        XCTAssertEqual(alias.vehicleID, vehicle.id)
        XCTAssertEqual(alias.displayName, "SUBARU BT")
        XCTAssertEqual(alias.connectionKind, .bluetooth)

        let aliasAttributes = try XCTUnwrap(
            persistence.container.managedObjectModel.entitiesByName["VehicleConnectionAliasEntity"]
        ).attributesByName
        XCTAssertNil(aliasAttributes["identifierHash"])
        XCTAssertNil(aliasAttributes["rawIdentifier"])
        XCTAssertNil(aliasAttributes["salt"])
    }

    func testOnlyStableConfirmedIdentityCanAttributeSilently() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let vehicle = try vehicles.createVehicle(name: "Forester")
        let stable = try store.recordHashedObservation(
            identifierHash: "stable-hash",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        let fallback = try store.recordHashedObservation(
            identifierHash: "fallback-hash",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .fallbackPortName,
            observedAt: now
        )

        let stableAssigned = try store.assignVehicle(
            identifierHash: stable.identifierHash,
            vehicleID: vehicle.id
        )
        let fallbackAssigned = try store.assignVehicle(
            identifierHash: fallback.identifierHash,
            vehicleID: vehicle.id
        )

        XCTAssertTrue(stableAssigned.canIdentifyVehicleSilently)
        XCTAssertFalse(fallbackAssigned.canIdentifyVehicleSilently)
        XCTAssertEqual(
            try store.fetchReviewCandidates(startHintHashes: [stable.identifierHash, fallback.identifierHash])
                .map(\.identifierHash),
            [fallback.identifierHash]
        )
    }

    func testVehicleChoiceRollsBackMappingAndAliasWhenAdditionalMutationFails() throws {
        enum ExpectedFailure: Error { case failed }

        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let vehicle = try vehicles.createVehicle(name: "Forester")
        let observation = try store.recordHashedObservation(
            identifierHash: "atomic-choice-hash",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )

        XCTAssertThrowsError(try store.resolveVehicleChoice(
            identifierHash: observation.identifierHash,
            vehicleID: vehicle.id
        ) { () throws -> Void in
            throw ExpectedFailure.failed
        })

        let preserved = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertNil(preserved.vehicleID)
        XCTAssertNil(preserved.connectionAliasID)
        XCTAssertEqual(preserved.mappingDisposition, .unreviewed)
        XCTAssertTrue(try store.fetchConnectionAliases().isEmpty)
        XCTAssertFalse(context.hasChanges)
    }

    func testSyncedAliasIsSuggestedButNeverBindsUntilConfirmed() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let vehicle = try vehicles.createVehicle(name: "Forester")
        let first = try store.recordHashedObservation(
            identifierHash: "phone-a-hash",
            displayName: " SÚBARU   BT ",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        _ = try store.assignVehicle(identifierHash: first.identifierHash, vehicleID: vehicle.id)
        let second = try store.recordHashedObservation(
            identifierHash: "phone-b-hash",
            displayName: "subaru bt",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now.addingTimeInterval(60)
        )

        let suggestion = try XCTUnwrap(store.suggestedAlias(for: second.identifierHash))
        XCTAssertEqual(suggestion.vehicleID, vehicle.id)
        XCTAssertNil(try store.fetchHints(matching: [second.identifierHash]).first?.vehicleID)

        let confirmed = try store.confirmSuggestion(
            identifierHash: second.identifierHash,
            aliasID: suggestion.alias.id
        )
        XCTAssertEqual(confirmed.vehicleID, vehicle.id)
        XCTAssertEqual(confirmed.connectionAliasID, suggestion.alias.id)
        XCTAssertEqual(confirmed.mappingDisposition, .assigned)
    }

    func testAliasOnlyReassignmentUpdatesCloudAliasAndLocalBindings() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let original = try vehicles.createVehicle(name: "Forester")
        let replacement = try vehicles.createVehicle(name: "Outback")
        let observation = try store.recordHashedObservation(
            identifierHash: "local-binding",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        let assigned = try store.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: original.id
        )
        let aliasID = try XCTUnwrap(assigned.connectionAliasID)

        let alias = try store.assignConnectionAlias(
            id: aliasID,
            vehicleID: replacement.id,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(alias.vehicleID, replacement.id)
        XCTAssertEqual(try store.fetchConnectionAliases().first?.vehicleID, replacement.id)
        XCTAssertEqual(try store.fetchHints().first?.vehicleID, replacement.id)
    }

    func testAliasReassignmentMergesSameConnectionAlreadyOnTargetVehicle() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let original = try vehicles.createVehicle(name: "Forester")
        let replacement = try vehicles.createVehicle(name: "Outback")
        let first = try store.recordHashedObservation(
            identifierHash: "source-phone",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        let second = try store.recordHashedObservation(
            identifierHash: "target-phone",
            displayName: " subaru   bt ",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        let source = try store.assignVehicle(identifierHash: first.identifierHash, vehicleID: original.id)
        _ = try store.assignVehicle(identifierHash: second.identifierHash, vehicleID: replacement.id)
        XCTAssertEqual(try store.fetchConnectionAliases().count, 2)

        let merged = try store.assignConnectionAlias(
            id: try XCTUnwrap(source.connectionAliasID),
            vehicleID: replacement.id,
            now: now.addingTimeInterval(60)
        )

        let aliases = try store.fetchConnectionAliases()
        XCTAssertEqual(aliases, [merged])
        XCTAssertEqual(merged.vehicleID, replacement.id)
        let hints = try store.fetchHints().filter {
            [first.identifierHash, second.identifierHash].contains($0.identifierHash)
        }
        XCTAssertEqual(Set(hints.compactMap(\.vehicleID)), [replacement.id])
        XCTAssertEqual(Set(hints.compactMap(\.connectionAliasID)), [merged.id])
    }

    func testRemoteAliasReassignmentAndDeletionReconcileLocalBinding() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let original = try vehicles.createVehicle(name: "Forester")
        let replacement = try vehicles.createVehicle(name: "Outback")
        let observation = try store.recordHashedObservation(
            identifierHash: "remote-alias-binding",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        let assigned = try store.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: original.id
        )
        let aliasID = try XCTUnwrap(assigned.connectionAliasID)
        let aliasRequest = VehicleConnectionAliasEntity.fetchRequest()
        aliasRequest.predicate = NSPredicate(format: "id == %@", aliasID as CVarArg)
        let aliasEntity = try XCTUnwrap(context.fetch(aliasRequest).first)

        // Simulate a CloudKit merge instead of the local public API, which
        // deliberately updates local bindings in the same transaction.
        aliasEntity.vehicleID = replacement.id
        aliasEntity.updatedAt = now.addingTimeInterval(60)
        try context.save()

        XCTAssertEqual(try store.reconcileLocalBindingsWithAliases(), 1)
        XCTAssertEqual(try store.fetchHints().first?.vehicleID, replacement.id)

        context.delete(aliasEntity)
        try context.save()

        XCTAssertEqual(try store.reconcileLocalBindingsWithAliases(), 1)
        let unlinked = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertNil(unlinked.vehicleID)
        XCTAssertNil(unlinked.connectionAliasID)
        XCTAssertEqual(unlinked.mappingDisposition, .unreviewed)
    }

    func testConflictingSyncedAliasesDoNotSuggestVehicle() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let firstVehicle = try vehicles.createVehicle(name: "Forester")
        let secondVehicle = try vehicles.createVehicle(name: "Outback")

        for (hash, vehicleID) in [("one", firstVehicle.id), ("two", secondVehicle.id)] {
            _ = try store.recordHashedObservation(
                identifierHash: hash,
                displayName: "Shared CarPlay",
                source: .audioRoute,
                connectionKind: .carPlay,
                identityQuality: .stablePortIdentifier,
                observedAt: now
            )
            _ = try store.assignVehicle(identifierHash: hash, vehicleID: vehicleID)
        }
        _ = try store.recordHashedObservation(
            identifierHash: "third-phone",
            displayName: "shared carplay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now.addingTimeInterval(60)
        )

        XCTAssertNil(try store.suggestedAlias(for: "third-phone"))
    }

    func testDeferredCandidateWaitsForNewObservationAndIgnoredNeverReturns() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let deferred = try store.recordHashedObservation(
            identifierHash: "deferred",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        let ignored = try store.recordHashedObservation(
            identifierHash: "ignored",
            displayName: "Passenger Car",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )

        _ = try store.deferReview(identifierHash: deferred.identifierHash, now: now.addingTimeInterval(1))
        _ = try store.markIgnored(identifierHash: ignored.identifierHash, now: now.addingTimeInterval(1))
        XCTAssertTrue(try store.fetchReviewCandidates().isEmpty)

        _ = try store.recordHashedObservation(
            identifierHash: deferred.identifierHash,
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: now.addingTimeInterval(120)
        )
        _ = try store.recordHashedObservation(
            identifierHash: ignored.identifierHash,
            displayName: "Passenger Car",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now.addingTimeInterval(120)
        )

        XCTAssertEqual(try store.fetchReviewCandidates().map(\.identifierHash), [deferred.identifierHash])
    }

    func testDeferringAssignedFallbackConnectionPreservesMappingAndAlias() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Forester")
        let store = BluetoothDriveHintStore(context: context)
        let observation = try store.recordHashedObservation(
            identifierHash: "fallback-assignment",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .fallbackPortName,
            observedAt: now
        )
        let assigned = try store.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: vehicle.id,
            now: now
        )
        let aliasID = try XCTUnwrap(assigned.connectionAliasID)

        let deferred = try store.deferReview(
            identifierHash: observation.identifierHash,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(deferred.mappingDisposition, .deferred)
        XCTAssertEqual(deferred.vehicleID, vehicle.id)
        XCTAssertEqual(deferred.connectionAliasID, aliasID)
        XCTAssertTrue(try store.fetchReviewCandidates().isEmpty)

        _ = try store.recordHashedObservation(
            identifierHash: observation.identifierHash,
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .fallbackPortName,
            observedAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            try store.fetchReviewCandidates().map(\.identifierHash),
            [observation.identifierHash]
        )
        let reobserved = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(reobserved.vehicleID, vehicle.id)
        XCTAssertEqual(reobserved.connectionAliasID, aliasID)
    }

    func testAliasFilterUsesNewestLogicalRevisionBeforeVehiclePredicate() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let original = try vehicles.createVehicle(name: "Forester")
        let replacement = try vehicles.createVehicle(name: "Outback")
        let store = BluetoothDriveHintStore(context: context)
        let aliasID = UUID()

        let stale = VehicleConnectionAliasEntity.insert(into: context)
        stale.id = aliasID
        stale.vehicleID = original.id
        stale.displayName = "SUBARU BT"
        stale.connectionKindRaw = VehicleConnectionKind.carPlay.rawValue
        stale.createdAt = now
        stale.updatedAt = now

        let current = VehicleConnectionAliasEntity.insert(into: context)
        current.id = aliasID
        current.vehicleID = replacement.id
        current.displayName = "SUBARU BT"
        current.connectionKindRaw = VehicleConnectionKind.carPlay.rawValue
        current.createdAt = now
        current.updatedAt = now.addingTimeInterval(60)
        try context.save()

        XCTAssertTrue(try store.fetchConnectionAliases(vehicleID: original.id).isEmpty)
        XCTAssertEqual(
            try store.fetchConnectionAliases(vehicleID: replacement.id).map(\.id),
            [aliasID]
        )
    }

    func testRemoteSemanticAliasDuplicatesConvergeDuringReconciliation() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Forester")
        let store = BluetoothDriveHintStore(context: context)

        for (id, offset) in [(UUID(), 0.0), (UUID(), 60.0)] {
            let alias = VehicleConnectionAliasEntity.insert(into: context)
            alias.id = id
            alias.vehicleID = vehicle.id
            alias.displayName = offset == 0 ? "SUBARU BT" : " subaru   bt "
            alias.connectionKindRaw = VehicleConnectionKind.bluetooth.rawValue
            alias.createdAt = now
            alias.updatedAt = now.addingTimeInterval(offset)
        }
        try context.save()
        XCTAssertEqual(try store.fetchConnectionAliases().count, 2)

        XCTAssertGreaterThan(try store.reconcileLocalBindingsWithAliases(now: now.addingTimeInterval(120)), 0)

        let aliases = try store.fetchConnectionAliases()
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases.first?.vehicleID, vehicle.id)
    }

    func testIgnoredConnectionKeepsLearningHistoryButCannotSeedDetection() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let observation = try store.recordHashedObservation(
            identifierHash: "ignored-trusted-car",
            displayName: "Toyota Camry",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        _ = try store.applyReviewOutcome(
            identifierHashes: [observation.identifierHash],
            outcome: .confirmedDrive
        )
        _ = try store.applyReviewOutcome(
            identifierHashes: [observation.identifierHash],
            outcome: .confirmedDrive
        )
        XCTAssertTrue(try store.trustedVehicleHint(now: now))

        let ignored = try store.markIgnored(
            identifierHash: observation.identifierHash,
            now: now.addingTimeInterval(1)
        )

        XCTAssertTrue(ignored.trusted, "historical trust is retained")
        XCTAssertEqual(ignored.correlationCount, 2)
        XCTAssertFalse(ignored.contributesDriveDetection)
        XCTAssertFalse(try store.trustedVehicleHint(now: now.addingTimeInterval(1)))

        let restored = try store.clearVehicleAssignment(
            identifierHash: observation.identifierHash,
            now: now.addingTimeInterval(2)
        )
        XCTAssertTrue(restored.trusted)
        XCTAssertTrue(restored.contributesDriveDetection)
        XCTAssertTrue(try store.trustedVehicleHint(now: now.addingTimeInterval(2)))
    }

    func testLegacyExplicitMappingCreatesAliasOnlyWhenKnownKindIsReobserved() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Forester")
        let store = BluetoothDriveHintStore(context: context)
        let observation = try store.recordHashedObservation(
            identifierHash: "legacy-hash",
            displayName: "SUBARU BT",
            source: .audioRoute,
            observedAt: now
        )
        let assigned = try store.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: vehicle.id
        )
        XCTAssertNil(assigned.connectionAliasID)
        XCTAssertTrue(try store.fetchConnectionAliases().isEmpty)

        _ = try store.recordHashedObservation(
            identifierHash: observation.identifierHash,
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now.addingTimeInterval(60)
        )

        let migrated = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(migrated.mappingDisposition, .assigned)
        XCTAssertNotNil(migrated.connectionAliasID)
        XCTAssertEqual(try store.fetchConnectionAliases().count, 1)
    }

    func testVehicleDeletionRemovesAliasesAndUnlinksLocalBindings() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicles = VehicleStore(context: context)
        let store = BluetoothDriveHintStore(context: context)
        let vehicle = try vehicles.createVehicle(name: "Forester")
        let observation = try store.recordHashedObservation(
            identifierHash: "delete-me",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now
        )
        _ = try store.assignVehicle(identifierHash: observation.identifierHash, vehicleID: vehicle.id)

        let result = try vehicles.deleteVehicleAndAssociatedData(id: vehicle.id)

        XCTAssertEqual(result.deletedConnectionAliasCount, 1)
        XCTAssertEqual(result.unlinkedBluetoothHintCount, 1)
        XCTAssertTrue(try store.fetchConnectionAliases().isEmpty)
        let hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertNil(hint.vehicleID)
        XCTAssertNil(hint.connectionAliasID)
        XCTAssertEqual(hint.mappingDisposition, .unreviewed)
    }

    func testCompletionPreservesLatchedVehicleConnectionSource() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Forester")
        let tripStore = TripStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context)
        )
        let draft = TripDraft(
            startDate: now,
            endDate: now.addingTimeInterval(600),
            samples: [
                LocationSample(
                    timestamp: now,
                    latitude: 40,
                    longitude: -73,
                    horizontalAccuracy: 5
                ),
                LocationSample(
                    timestamp: now.addingTimeInterval(600),
                    latitude: 40.05,
                    longitude: -73,
                    horizontalAccuracy: 5
                )
            ],
            distanceMeters: 5_000,
            vehicleID: vehicle.id,
            vehicleAssignmentSource: .vehicleConnection
        )

        let outcome = try coordinator.complete(draft, monitoringSessionID: nil)
        guard case .saved(let result) = outcome else {
            return XCTFail("Expected completion to be saved")
        }
        XCTAssertEqual(result.trip.vehicleID, vehicle.id)
        XCTAssertEqual(result.trip.vehicleAssignmentSource, .vehicleConnection)
        XCTAssertEqual(try tripStore.fetchTrip(id: draft.id).vehicleAssignmentSource, .vehicleConnection)
    }

    func testVehicleConnectionsModelMigratesCloudAndLocalStores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VehicleConnectionMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldModelURL = try XCTUnwrap(
            PersistenceController.managedObjectModelURL(versionName: "MileageTrackerVehicles")
        )
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: oldModelURL))
        let oldContainer = NSPersistentContainer(name: "MileageTracker", managedObjectModel: oldModel)
        oldContainer.persistentStoreDescriptions = [
            description(
                url: directory.appendingPathComponent("MileageTracker.sqlite"),
                configuration: PersistenceController.cloudConfigurationName
            ),
            description(
                url: directory.appendingPathComponent("MileageTrackerRaw.sqlite"),
                configuration: PersistenceController.localConfigurationName
            )
        ]
        try load(oldContainer)

        let vehicleID = UUID()
        let vehicle = NSEntityDescription.insertNewObject(forEntityName: "VehicleEntity", into: oldContainer.viewContext)
        vehicle.setValue(vehicleID, forKey: "id")
        vehicle.setValue("Forester", forKey: "name")
        vehicle.setValue(now, forKey: "createdAt")
        vehicle.setValue(now, forKey: "updatedAt")
        vehicle.setValue(Int64(0), forKey: "sortOrder")
        vehicle.setValue(false, forKey: "isArchived")

        let hint = NSEntityDescription.insertNewObject(forEntityName: "BluetoothHintEntity", into: oldContainer.viewContext)
        hint.setValue(UUID(), forKey: "id")
        hint.setValue("legacy-local-hash", forKey: "identifierHash")
        hint.setValue("SUBARU BT", forKey: "displayName")
        hint.setValue(BluetoothSignalSource.audioRoute.rawValue, forKey: "sourceRaw")
        hint.setValue(now, forKey: "firstSeenAt")
        hint.setValue(now, forKey: "lastSeenAt")
        hint.setValue(Int64(2), forKey: "correlationCount")
        hint.setValue(Int64(0), forKey: "notADriveCount")
        hint.setValue(true, forKey: "trusted")
        hint.setValue(vehicleID, forKey: "vehicleID")
        try oldContainer.viewContext.save()
        try close(oldContainer)

        let migrated = try PersistenceController(mode: .localOnly, storeDirectory: directory)
        let store = BluetoothDriveHintStore(context: migrated.container.viewContext)
        let migratedHint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(migratedHint.vehicleID, vehicleID)
        XCTAssertEqual(migratedHint.mappingDisposition, .assigned)
        XCTAssertEqual(migratedHint.connectionKind, .unknown)
        XCTAssertNil(migratedHint.connectionAliasID)

        _ = try store.recordHashedObservation(
            identifierHash: migratedHint.identifierHash,
            displayName: migratedHint.displayName,
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(try store.fetchConnectionAliases().first?.vehicleID, vehicleID)
        try close(migrated.container)
    }

    private func description(url: URL, configuration: String) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = configuration
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        return description
    }

    private func load(_ container: NSPersistentContainer) throws {
        var errors: [Error] = []
        container.loadPersistentStores { _, error in
            if let error { errors.append(error) }
        }
        if let error = errors.first { throw error }
    }

    private func close(_ container: NSPersistentContainer) throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
