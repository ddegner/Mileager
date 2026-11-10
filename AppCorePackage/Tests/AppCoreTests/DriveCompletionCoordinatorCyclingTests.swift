import CoreData
import XCTest
@testable import AppCore

final class DriveCompletionCoordinatorCyclingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testBracketedRideIsDiscardedBeforePersistence() throws {
        let harness = try makeHarness()
        let draft = rideDraft()

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID)

        guard case .discardedAutomaticCapture(let source, let reason) = outcome else {
            return XCTFail("Expected an automatic discard, got \(outcome)")
        }
        XCTAssertEqual(source, .autoCycling)
        XCTAssertTrue(reason.contains("Cycling bracket"), reason)
        XCTAssertNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
        XCTAssertEqual(try harness.tripStore.rawSampleCount(tripID: draft.id), 0)
    }

    func testDiscardNeedsNoStores() throws {
        // The evidence rides on the draft; a coordinator without diagnostic or
        // hint stores still recognizes the ride.
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context)
        )

        let outcome = try coordinator.complete(rideDraft(), monitoringSessionID: nil)

        guard case .discardedAutomaticCapture(let source, _) = outcome else {
            return XCTFail("Expected an automatic discard, got \(outcome)")
        }
        XCTAssertEqual(source, .autoCycling)
    }

    func testRideWithInFlightUserDecisionIsSaved() throws {
        let harness = try makeHarness()
        var draft = rideDraft()
        draft.classification = .personal

        guard case .saved(let result) = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertEqual(result.trip.classification, .personal)
    }

    func testDraftVehicleAttributionKeepsTheTrip() throws {
        let harness = try makeHarness()
        var draft = rideDraft()
        draft.vehicleID = try harness.vehicleStore.createVehicle(name: "Prius").id
        draft.vehicleAssignmentSource = .shortcut

        guard case .saved(let result) = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertNil(result.trip.classification)
        XCTAssertEqual(result.trip.vehicleID, draft.vehicleID)
    }

    func testReducerVehicleFlagKeepsTheTrip() throws {
        let harness = try makeHarness()
        var draft = rideDraft()
        draft.vehicleConnectionObserved = true

        guard case .saved(let result) = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertNil(result.trip.classification)
    }

    func testMappedCarObservedNearStartKeepsTheTrip() throws {
        let harness = try makeHarness()
        let vehicleID = try harness.vehicleStore.createVehicle(name: "Prius").id
        let observation = try harness.hintStore.recordObservation(
            identifier: "car-multimedia",
            displayName: "CAR MULTIMEDIA",
            source: .audioRoute,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(-30)
        )
        _ = try harness.hintStore.assignVehicle(identifierHash: observation.identifierHash, vehicleID: vehicleID)

        guard case .saved(let result) = try harness.coordinator.complete(rideDraft(), monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertNil(result.trip.classification)
        XCTAssertEqual(result.trip.vehicleID, vehicleID)
    }

    func testUnmappedHeadphonesNearStartDoNotKeepTheTrip() throws {
        // An unreviewed audio route (AirPods) is not a car.
        let harness = try makeHarness()
        _ = try harness.hintStore.recordObservation(
            identifier: "airpods",
            displayName: "David’s AirPods Pro",
            source: .audioRoute,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(-30)
        )

        guard case .discardedAutomaticCapture(let source, _) = try harness.coordinator.complete(rideDraft(), monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected an automatic discard")
        }
        XCTAssertEqual(source, .autoCycling)
    }

    func testTrustedHintOnDiagnosticsKeepsTheTrip() throws {
        let harness = try makeHarness()
        try harness.diagnosticStore.save(diagnosticSample(harness, at: 10, trustedVehicle: true))

        guard case .saved(let result) = try harness.coordinator.complete(rideDraft(), monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertNil(result.trip.classification)
    }

    func testUntrustedDiagnosticsDoNotKeepTheTrip() throws {
        let harness = try makeHarness()
        for offset in stride(from: 0.0, through: 150, by: 2) {
            try harness.diagnosticStore.save(diagnosticSample(harness, at: offset, trustedVehicle: false))
        }

        guard case .discardedAutomaticCapture(let source, _) = try harness.coordinator.complete(rideDraft(), monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected an automatic discard")
        }
        XCTAssertEqual(source, .autoCycling)
    }

    func testCarSpeedKeepsTheTrip() throws {
        let harness = try makeHarness()
        var draft = rideDraft()
        draft.samples[40].speedMetersPerSecond = 18.7

        guard case .saved(let result) = try harness.coordinator.complete(draft, monitoringSessionID: harness.sessionID) else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertNil(result.trip.classification)
        XCTAssertNil(result.trip.classificationSource)
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
        return Harness(
            tripStore: tripStore,
            diagnosticStore: diagnosticStore,
            hintStore: hintStore,
            vehicleStore: VehicleStore(context: context),
            coordinator: DriveCompletionCoordinator(
                tripStore: tripStore,
                activeDriveStore: ActiveDriveStore(context: context),
                diagnosticSampleStore: diagnosticStore,
                bluetoothHintStore: hintStore
            ),
            sessionID: UUID()
        )
    }

    /// A 153-second capture labeled automotive at bicycle speed, with
    /// cycling reports before the start and one second after the end.
    private func rideDraft() -> TripDraft {
        let samples = stride(from: 0.0, through: 153, by: 2).map { offset in
            LocationSample(
                timestamp: start.addingTimeInterval(offset),
                latitude: 40.7090 + offset * 5 / 111_111,
                longitude: -39.0040,
                horizontalAccuracy: 8,
                speedMetersPerSecond: offset == 76 ? 7.1 : 4.5,
                motionHint: .automotive
            )
        }
        return TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(153),
            samples: samples,
            distanceMeters: 386,
            cyclingMotionDates: [-753, -256, 154].map { start.addingTimeInterval($0) }
        )
    }

    private func diagnosticSample(_ harness: Harness, at offset: TimeInterval, trustedVehicle: Bool) -> DiagnosticLocationSample {
        let timestamp = start.addingTimeInterval(offset)
        return DiagnosticLocationSample(
            monitoringSessionID: harness.sessionID,
            receivedAt: timestamp,
            sample: LocationSample(
                timestamp: timestamp,
                latitude: 40.7090 + offset * 5 / 111_111,
                longitude: -39.0040,
                horizontalAccuracy: 8
            ),
            trackingPhase: "recording",
            powerConnected: false,
            recentPowerConnected: false,
            recentPowerDisconnected: false,
            trustedBluetoothVehicleHint: trustedVehicle,
            acceptedForDetection: true,
            expiresAt: timestamp.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }
}
