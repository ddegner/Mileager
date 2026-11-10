import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class BluetoothDriveHintStoreTests: XCTestCase {
    func testVehicleNameMatcherAcceptsCommonCarRoutes() {
        let accepted = [
            "CAR MULTIMEDIA",
            "CarPlay",
            "Uconnect",
            "SYNC",
            "Toyota Camry",
            "Honda HandsFreeLink",
            "BMW 330i",
            "Mercedes COMAND",
            "Chevrolet MyLink",
            "Audi MMI"
        ]

        for name in accepted {
            XCTAssertTrue(BluetoothVehicleNameMatcher.matches(name), name)
        }
    }

    func testVehicleNameMatcherRejectsObviousNonCarRoutes() {
        let rejected = [
            "David's AirPods",
            "Bose Headphones",
            "JBL Speaker",
            "Magic Keyboard",
            "HomePod Living Room",
            "Sonos Soundbar",
            "Apple Watch"
        ]

        for name in rejected {
            XCTAssertFalse(BluetoothVehicleNameMatcher.matches(name), name)
        }
    }

    func testTwoReviewConfirmationsPromoteVehicleNamedHintToTrusted() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try store.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: now.addingTimeInterval(-60)
        )

        _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .confirmedDrive)
        var hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertFalse(hint.trusted)

        _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .confirmedDrive)
        hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 2)
        XCTAssertTrue(hint.trusted)
        XCTAssertTrue(try store.trustedVehicleHint(now: now))
    }

    func testRecordObservationRollsBackFailedSave() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = BluetoothDriveHintStore(context: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = BluetoothObservationEntity.insert(into: context)

        XCTAssertThrowsError(try store.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: now
        ))
        XCTAssertFalse(context.hasChanges)

        let observation = try store.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: now
        )
        XCTAssertEqual(try store.fetchHints().map(\.identifierHash), [observation.identifierHash])
    }

    func testPurgeExpiredObservationsRollsBackFailedSave() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = BluetoothDriveHintStore(context: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredDate = now.addingTimeInterval(-BluetoothDriveHintStore.defaultObservationRetention - 1)

        _ = try store.recordObservation(
            identifier: "old-car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: expiredDate
        )
        _ = BluetoothObservationEntity.insert(into: context)

        XCTAssertThrowsError(try store.purgeExpiredObservations(now: now))
        XCTAssertFalse(context.hasChanges)

        XCTAssertEqual(try store.purgeExpiredObservations(now: now), 1)
        XCTAssertTrue(try context.fetch(BluetoothObservationEntity.fetchRequest()).isEmpty)
    }

    func testUnknownNamedHintNeedsThreeConfirmations() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try store.recordObservation(
            identifier: "mystery",
            displayName: "Pioneer Deck",
            source: .audioRoute,
            observedAt: now
        )

        for _ in 0..<2 {
            _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .confirmedDrive)
        }
        XCTAssertEqual(try store.fetchHints().first?.trusted, false)

        _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .confirmedDrive)
        XCTAssertEqual(try store.fetchHints().first?.trusted, true)
    }

    func testMarkNotADriveTwiceBlocksHintAndDemotesTrust() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try store.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: now
        )
        for _ in 0..<2 {
            _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .confirmedDrive)
        }
        XCTAssertEqual(try store.fetchHints().first?.trusted, true)

        for _ in 0..<2 {
            _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .notADrive)
        }

        let hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(hint.notADriveCount, 2)
        XCTAssertTrue(hint.blocked)
        XCTAssertFalse(hint.trusted)
        XCTAssertFalse(try store.trustedVehicleHint(now: now))
    }

    func testUndoNotADriveDecrementsCounterAndRestoresTrust() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try store.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: now
        )
        for _ in 0..<2 {
            _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .confirmedDrive)
        }
        for _ in 0..<2 {
            _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .notADrive)
        }
        XCTAssertEqual(try store.fetchHints().first?.blocked, true)

        _ = try store.applyReviewOutcome(identifierHashes: [observation.identifierHash], outcome: .undoNotADrive)

        let hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(hint.notADriveCount, 1)
        XCTAssertFalse(hint.blocked)
        XCTAssertTrue(hint.trusted)
    }

    func testManualOverrideMigrationSeedsCountersOnceAndClearsOverride() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = BluetoothDriveHintStore(context: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let trustedCar = try store.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: now
        )
        let untrustedSpeaker = try store.recordObservation(
            identifier: "speaker",
            displayName: "JBL Speaker",
            source: .audioRoute,
            observedAt: now
        )

        let hints = try context.fetch(BluetoothHintEntity.fetchRequest())
        let carEntity = try XCTUnwrap(hints.first { $0.identifierHash == trustedCar.identifierHash })
        carEntity.manualTrustOverride = NSNumber(value: true)
        let speakerEntity = try XCTUnwrap(hints.first { $0.identifierHash == untrustedSpeaker.identifierHash })
        speakerEntity.manualTrustOverride = NSNumber(value: false)
        speakerEntity.correlationCount = 3
        speakerEntity.trusted = true
        try context.save()

        try store.migrateManualTrustOverridesIfNeeded()

        let migrated = try store.fetchHints()
        let car = try XCTUnwrap(migrated.first { $0.identifierHash == trustedCar.identifierHash })
        XCTAssertNil(car.manualTrustOverride)
        XCTAssertEqual(car.correlationCount, 2)
        XCTAssertTrue(car.trusted)

        let speaker = try XCTUnwrap(migrated.first { $0.identifierHash == untrustedSpeaker.identifierHash })
        XCTAssertNil(speaker.manualTrustOverride)
        XCTAssertEqual(speaker.notADriveCount, 3)
        XCTAssertTrue(speaker.blocked)
        XCTAssertFalse(speaker.trusted)

        // A second run is a no-op even if overrides reappear.
        speakerEntity.manualTrustOverride = NSNumber(value: true)
        try context.save()
        try store.migrateManualTrustOverridesIfNeeded()
        XCTAssertEqual(
            try store.fetchHints().first { $0.identifierHash == untrustedSpeaker.identifierHash }?.manualTrustOverride,
            true
        )
    }

    func testCompletionStampsStartBluetoothHintHashesFromObservations() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let hintStore = BluetoothDriveHintStore(context: context)
        let tripStore = TripStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context),
            bluetoothHintStore: hintStore
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try hintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-120)
        )
        let samples = [
            LocationSample(timestamp: start, latitude: 40.0, longitude: -73.0, horizontalAccuracy: 5),
            LocationSample(timestamp: start.addingTimeInterval(600), latitude: 40.05, longitude: -73.0, horizontalAccuracy: 5)
        ]
        let result = try XCTUnwrap(try coordinator.complete(
            TripDraft(
                startDate: start,
                endDate: start.addingTimeInterval(600),
                samples: samples,
                distanceMeters: 5_000
            ),
            monitoringSessionID: nil
        ).savedResult)

        XCTAssertEqual(result.trip.startBluetoothHintHashes, [observation.identifierHash])
        XCTAssertEqual(try tripStore.fetchTrip(id: result.trip.id).startBluetoothHintHashes, [observation.identifierHash])
    }

    func testObservationsIncludeLookaheadAfterBackdatedStart() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // The June 9 failure mode: the car's route observation lands seconds
        // AFTER the backdated trip start, so a backward-only window missed it.
        let justAfterStart = try store.recordObservation(
            identifier: "car-audio",
            displayName: "CAR MULTIMEDIA",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(2)
        )
        _ = try store.recordObservation(
            identifier: "late-speaker",
            displayName: "JBL Speaker",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(BluetoothDriveHintStore.defaultStartLookahead + 60)
        )
        _ = try store.recordObservation(
            identifier: "stale-device",
            displayName: "Old Device",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-BluetoothDriveHintStore.defaultObservationWindow - 60)
        )

        let observations = try store.observations(near: start)

        XCTAssertEqual(observations.map(\.identifierHash), [justAfterStart.identifierHash])
    }

    func testObservationsDeduplicateDeviceAcrossWindowAndLookahead() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let before = try store.recordObservation(
            identifier: "car-audio",
            displayName: "CAR MULTIMEDIA",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        _ = try store.recordObservation(
            identifier: "car-audio",
            displayName: "CAR MULTIMEDIA",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(30)
        )

        let observations = try store.observations(near: start)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.identifierHash, before.identifierHash)
    }

    func testZeroLookaheadKeepsBackwardOnlyWindow() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try store.recordObservation(
            identifier: "car-audio",
            displayName: "CAR MULTIMEDIA",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(2)
        )

        XCTAssertTrue(try store.observations(near: start, lookahead: 0).isEmpty)
    }

    func testCompletionStampsObservationRecordedJustAfterStart() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let hintStore = BluetoothDriveHintStore(context: context)
        let tripStore = TripStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context),
            bluetoothHintStore: hintStore
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try hintStore.recordObservation(
            identifier: "car-audio",
            displayName: "CAR MULTIMEDIA",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(2)
        )
        let samples = [
            LocationSample(timestamp: start, latitude: 40.0, longitude: -73.0, horizontalAccuracy: 5),
            LocationSample(timestamp: start.addingTimeInterval(600), latitude: 40.05, longitude: -73.0, horizontalAccuracy: 5)
        ]
        let result = try XCTUnwrap(try coordinator.complete(
            TripDraft(
                startDate: start,
                endDate: start.addingTimeInterval(600),
                samples: samples,
                distanceMeters: 5_000
            ),
            monitoringSessionID: nil
        ).savedResult)

        XCTAssertEqual(result.trip.startBluetoothHintHashes, [observation.identifierHash])
    }

    func testNonDrivingObservationDoesNotPromoteHint() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try store.recordObservation(
            identifier: "headphones",
            displayName: "Headphones",
            source: .audioRoute,
            observedAt: now
        )

        let hint = try XCTUnwrap(try store.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 0)
        XCTAssertFalse(hint.trusted)
        XCTAssertFalse(try store.trustedVehicleHint(now: now))
    }

    func testFetchHintsMatchingCurrentRouteHashesOnlyReturnsConnectedHints() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BluetoothDriveHintStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let connected = try store.recordObservation(
            identifier: "car-audio",
            displayName: "Car Audio",
            source: .audioRoute,
            observedAt: now
        )
        _ = try store.recordObservation(
            identifier: "old-headphones",
            displayName: "Old Headphones",
            source: .audioRoute,
            observedAt: now.addingTimeInterval(-60)
        )

        let hints = try store.fetchHints(matching: [connected.identifierHash])

        XCTAssertEqual(hints.map(\.displayName), ["Car Audio"])
    }

}
