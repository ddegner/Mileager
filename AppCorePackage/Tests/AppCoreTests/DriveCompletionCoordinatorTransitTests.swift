import CoreData
import XCTest
@testable import AppCore

final class DriveCompletionCoordinatorTransitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testSubwayLikeCompletionIsDiscardedBeforePersistence() throws {
        let harness = try makeHarness()
        try seedSubwayDiagnostics(harness)
        // A learned (non-trusted) device exists; auto-marking must not train it.
        let observation = try harness.hintStore.recordObservation(
            identifier: "headphones",
            displayName: "Headphones",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-30)
        )

        let draft = subwayDraft()
        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)

        assertDiscarded(outcome, source: .autoTransit)
        XCTAssertNil(try harness.tripStore.fetchTripIfExists(id: draft.id))

        let hint = try XCTUnwrap(harness.hintStore.fetchHints().first { $0.identifierHash == observation.identifierHash })
        XCTAssertEqual(hint.correlationCount, 0)
        XCTAssertEqual(hint.notADriveCount, 0)
    }

    func testDistanceAloneNeverDiscardsAutomaticCompletion() throws {
        let harness = try makeHarness()
        let draft = shortDraft()
        let result = try savedResult(
            harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)
        )

        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertNotNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
    }

    func testShortCaptureWithUserClassificationIsSaved() throws {
        let harness = try makeHarness()
        var draft = shortDraft()
        draft.classification = .business

        let result = try savedResult(
            harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)
        )

        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertEqual(result.trip.classification, .business)
        XCTAssertNotNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
    }

    func testShortCaptureWithUserAddedTollIsSaved() throws {
        let harness = try makeHarness()
        var draft = shortDraft()
        draft.fees = [TripFee(tripID: draft.id, category: .toll, amount: 5, occurredAt: start)]

        let result = try savedResult(
            harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)
        )

        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertEqual(try harness.tripStore.fetchTrip(id: draft.id).tollsAmount, 5)
    }

    func testShortCaptureWithManualVehicleChoiceIsSaved() throws {
        let harness = try makeHarness()
        var draft = shortDraft()
        draft.vehicleID = try harness.vehicleStore.createVehicle(name: "Forester").id
        draft.vehicleAssignmentSource = .manual

        let result = try savedResult(
            harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)
        )

        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertEqual(result.trip.vehicleID, draft.vehicleID)
        XCTAssertEqual(result.trip.vehicleAssignmentSource, .manual)
    }

    func testFallbackPortNameMappingNeverAttributesSilentlyAtCompletion() throws {
        let harness = try makeHarness()
        let vehicleID = try harness.vehicleStore.createVehicle(name: "Forester").id
        let observation = try harness.hintStore.recordObservation(
            identifier: "generic-car-name",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .fallbackPortName,
            observedAt: start.addingTimeInterval(-30)
        )
        _ = try harness.hintStore.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: vehicleID
        )

        let result = try savedResult(
            harness.coordinator.complete(
                subwayDraft(attentionReasons: []),
                monitoringSessionID: harness.sessionID
            )
        )

        XCTAssertNil(result.trip.vehicleID)
        XCTAssertNil(result.trip.vehicleAssignmentSource)
    }

    func testStablePortMappingAttributesSilentlyAtCompletion() throws {
        let harness = try makeHarness()
        let vehicleID = try harness.vehicleStore.createVehicle(name: "Forester").id
        let observation = try harness.hintStore.recordObservation(
            identifier: "stable-car-port",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(-30)
        )
        _ = try harness.hintStore.assignVehicle(
            identifierHash: observation.identifierHash,
            vehicleID: vehicleID
        )

        let result = try savedResult(
            harness.coordinator.complete(
                subwayDraft(attentionReasons: []),
                monitoringSessionID: harness.sessionID
            )
        )

        XCTAssertEqual(result.trip.vehicleID, vehicleID)
        XCTAssertEqual(result.trip.vehicleAssignmentSource, .vehicleConnection)
    }

    func testVeryShortCaptureWithoutPostParkingEvidenceIsSaved() throws {
        let harness = try makeHarness()
        var draft = shortDraft()
        draft.distanceMeters = 1

        let result = try savedResult(
            harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)
        )

        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertNil(result.trip.classification)
        XCTAssertNotNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
    }

    func testTransitClassifierFailsOpenWhenDiagnosticsAreUnavailable() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context),
            diagnosticSampleStore: nil
        )
        let draft = subwayDraft()

        let result = try savedResult(coordinator.complete(draft, monitoringSessionID: UUID()))

        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertNil(result.trip.classification)
    }

    func testCleanCarCompletionStaysUnclassified() throws {
        let harness = try makeHarness()
        for offset in stride(from: 0.0, to: 1_245, by: 2) {
            try harness.diagnosticStore.save(diagnosticSample(harness, at: offset, accuracy: 8))
        }
        try harness.diagnosticStore.save(diagnosticSample(harness, at: -1, accuracy: 8))

        let result = try savedResult(
            harness.coordinator.complete(subwayDraft(attentionReasons: []), monitoringSessionID: harness.sessionID)
        )

        XCTAssertNil(result.trip.classification)
        XCTAssertNil(result.trip.classificationSource)
    }

    func testRecompletionNeverOverridesUserClassification() throws {
        let harness = try makeHarness()
        try seedSubwayDiagnostics(harness)
        let draft = subwayDraft()

        let first = try harness.tripStore.saveCompletedTrip(draft)
        _ = try harness.tripStore.updateReview(
            tripID: first.id,
            update: ReviewUpdate(classification: .business, reviewStatus: .readyToExport)
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID))

        let persisted = try harness.tripStore.fetchTrip(id: first.id)
        XCTAssertEqual(persisted.classification, .business)
        XCTAssertNil(persisted.classificationSource)
    }

    func testShortRecompletionNeverOverridesUserClassification() throws {
        let harness = try makeHarness()
        let draft = shortDraft()

        let first = try harness.tripStore.saveCompletedTrip(draft)
        _ = try harness.tripStore.updateReview(
            tripID: first.id,
            update: ReviewUpdate(classification: .business, reviewStatus: .readyToExport)
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID))

        let persisted = try harness.tripStore.fetchTrip(id: first.id)
        XCTAssertEqual(persisted.classification, .business)
        XCTAssertNil(persisted.classificationSource)
    }

    func testRecompletionNeverDeletesAnAlreadySavedTripWithAUserAddedToll() throws {
        let harness = try makeHarness()
        let draft = shortDraft()
        let first = try harness.tripStore.saveCompletedTrip(draft)
        _ = try harness.tripStore.addFee(
            tripID: first.id,
            category: .toll,
            amount: 5,
            occurredAt: start
        )

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)

        let persisted = try harness.tripStore.fetchTrip(id: first.id)
        XCTAssertEqual(persisted.tollsAmount, 5)
        if case .discardedAutomaticCapture = outcome {
            XCTFail("A trip carrying a user-added toll must never be discarded on recompletion")
        }
    }

    func testAmbiguousVehicleOnOverlappingCaptureLeavesReviewedTripUntouched() throws {
        let harness = try makeHarness()
        // Clean GPS the whole way so the first capture stays a normal drive.
        for offset in stride(from: 0.0, to: 1_245, by: 2) {
            try harness.diagnosticStore.save(diagnosticSample(harness, at: offset, accuracy: 8))
        }

        // A prior automatic drive the user already reviewed and manually assigned.
        let firstDraft = subwayDraft(attentionReasons: [])
        let first = try savedResult(harness.coordinator.complete(firstDraft, monitoringSessionID: harness.sessionID))
        XCTAssertNil(first.trip.classification)
        let assignedVehicle = UUID()
        _ = try harness.tripStore.assignVehicle(tripID: first.trip.id, vehicleID: assignedVehicle)
        _ = try harness.tripStore.updateReview(
            tripID: first.trip.id,
            update: ReviewUpdate(
                classification: .business,
                reviewStatus: .readyToExport,
                businessPurpose: "Client visit"
            )
        )

        // Two learned devices near the shared start, mapped to two different
        // vehicles and neither trusted → the resolver reports a conflict.
        let obs1 = try harness.hintStore.recordObservation(
            identifier: "car-a",
            displayName: "Car A",
            source: .audioRoute,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(-30)
        )
        let obs2 = try harness.hintStore.recordObservation(
            identifier: "car-b",
            displayName: "Car B",
            source: .audioRoute,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(-20)
        )
        _ = try harness.hintStore.assignVehicle(identifierHash: obs1.identifierHash, vehicleID: UUID())
        _ = try harness.hintStore.assignVehicle(identifierHash: obs2.identifierHash, vehicleID: UUID())

        // A brand-new automatic capture overlaps the reviewed trip but has its
        // own UUID, so it remains a distinct drive and receives its own vehicle
        // attribution result.
        let secondDraft = subwayDraft(attentionReasons: [])
        let second = try savedResult(harness.coordinator.complete(secondDraft, monitoringSessionID: harness.sessionID))
        XCTAssertEqual(second.trip.id, secondDraft.id)
        XCTAssertNotEqual(second.trip.id, first.trip.id)

        // The reviewed trip must be left alone — not dragged back to needsAttention.
        let persisted = try harness.tripStore.fetchTrip(id: first.trip.id)
        XCTAssertEqual(persisted.reviewStatus, .readyToExport)
        XCTAssertFalse(persisted.needsAttention)
        XCTAssertFalse(persisted.attentionReasons.contains(DriveCompletionCoordinator.ambiguousVehicleAttentionReason))
        XCTAssertEqual(persisted.vehicleID, assignedVehicle)
        XCTAssertEqual(persisted.vehicleAssignmentSource, .manual)

        let overlapping = try harness.tripStore.fetchTrip(id: second.trip.id)
        XCTAssertTrue(overlapping.needsAttention)
        XCTAssertTrue(
            overlapping.attentionReasons.contains(
                DriveCompletionCoordinator.ambiguousVehicleAttentionReason
            )
        )
        XCTAssertEqual(try harness.tripStore.fetchTrips().count, 2)
    }

    // MARK: - Helpers

    private struct Harness {
        var tripStore: TripStore
        var diagnosticStore: DiagnosticSampleStore
        var hintStore: BluetoothDriveHintStore
        var vehicleStore: VehicleStore
        var coordinator: DriveCompletionCoordinator
        var sessionID: UUID
    }

    private func makeHarness() throws -> Harness {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        let diagnosticStore = DiagnosticSampleStore(context: context)
        let hintStore = BluetoothDriveHintStore(context: context)
        let vehicleStore = VehicleStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context),
            diagnosticSampleStore: diagnosticStore,
            bluetoothHintStore: hintStore
        )
        return Harness(
            tripStore: tripStore,
            diagnosticStore: diagnosticStore,
            hintStore: hintStore,
            vehicleStore: vehicleStore,
            coordinator: coordinator,
            sessionID: UUID()
        )
    }

    private func subwayDraft(attentionReasons: [String] = ["Impossible GPS jump"]) -> TripDraft {
        TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(1_245),
            samples: [
                LocationSample(timestamp: start, latitude: 40.68, longitude: -73.98, horizontalAccuracy: 20),
                LocationSample(timestamp: start.addingTimeInterval(1_245), latitude: 40.75, longitude: -73.99, horizontalAccuracy: 20)
            ],
            distanceMeters: 9_000,
            attentionReasons: attentionReasons
        )
    }

    private func shortDraft() -> TripDraft {
        TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(24),
            samples: [
                LocationSample(timestamp: start, latitude: 40.6800, longitude: -73.9800, horizontalAccuracy: 8),
                LocationSample(timestamp: start.addingTimeInterval(24), latitude: 40.6810, longitude: -73.9800, horizontalAccuracy: 8)
            ],
            distanceMeters: 111
        )
    }

    /// Mirrors the June 10 ride: usable GPS on the bridge third, junk cell
    /// fixes underground, nothing in the 45-minute pre-trip lookback.
    private func seedSubwayDiagnostics(_ harness: Harness) throws {
        for offset in stride(from: 0.0, to: 396, by: 2) {
            try harness.diagnosticStore.save(diagnosticSample(harness, at: offset, accuracy: 12))
        }
        for offset in stride(from: 396.0, to: 1_245, by: 2) {
            try harness.diagnosticStore.save(diagnosticSample(harness, at: offset, accuracy: 611))
        }
    }

    private func diagnosticSample(_ harness: Harness, at offset: TimeInterval, accuracy: Double) -> DiagnosticLocationSample {
        let timestamp = start.addingTimeInterval(offset)
        return DiagnosticLocationSample(
            monitoringSessionID: harness.sessionID,
            receivedAt: timestamp,
            sample: LocationSample(
                timestamp: timestamp,
                latitude: 40.68 + offset / 111_111,
                longitude: -73.98,
                horizontalAccuracy: accuracy
            ),
            trackingPhase: "recording",
            powerConnected: false,
            recentPowerConnected: false,
            recentPowerDisconnected: false,
            trustedBluetoothVehicleHint: false,
            acceptedForDetection: true,
            expiresAt: timestamp.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }

    private func savedResult(_ outcome: DriveCompletionOutcome) throws -> DriveCompletionResult {
        guard case .saved(let result) = outcome else {
            XCTFail("Expected a saved completion outcome")
            throw TestError.expectedSavedOutcome
        }
        return result
    }

    private enum TestError: Error {
        case expectedSavedOutcome
    }

    private func assertDiscarded(
        _ outcome: DriveCompletionOutcome,
        source: TripClassificationSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .discardedAutomaticCapture(let actualSource, let reason) = outcome else {
            return XCTFail("Expected a discarded completion outcome", file: file, line: line)
        }
        XCTAssertEqual(actualSource.rawValue, source.rawValue, file: file, line: line)
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }
}
