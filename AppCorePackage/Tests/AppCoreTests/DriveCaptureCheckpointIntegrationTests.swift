import AppCoreModels
import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence
@testable import DriveCaptureEngine

/// Checkpoint round-trips and DriveCompletionCoordinator integration:
/// the capture tests that legitimately need Core Data. The pure reducer
/// replay suite lives in DriveCaptureEngineTests, which never links
/// persistence.
final class DriveCaptureCheckpointIntegrationTests: XCTestCase {
    func testRecordingStateSurvivesStoreReloadAndFinalizesAtStopDeadline() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = ActiveDriveStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)

        try store.save(reducer.state)
        var restored = DriveCaptureReducer(state: try XCTUnwrap(store.load()))
        let stationary = sample(at: start.addingTimeInterval(130), metersNorth: 2_000, speed: 0, hint: .stationary)
        _ = restored.apply(.location(
            stationary,
            receivedAt: stationary.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        let stopDueAt = try XCTUnwrap(restored.state.stopDueAt)
        let outputs = restored.apply(.stopTimerFired(stopDueAt.addingTimeInterval(1)))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.endDate, stopDueAt)
        XCTAssertEqual(restored.state.pendingCompletionDraft?.id, draft.id)
    }

    func testCompletionCoordinatorKeepsIdleParkedAnchorCheckpoint() throws {
        let persistence = try PersistenceController(inMemory: true)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeStore,
            configuration: .automatic
        )
        let anchor = sample(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            metersNorth: 0,
            speed: 0,
            hint: .stationary
        )
        var state = DriveCaptureState()
        state.parkedStartAnchor = anchor

        try coordinator.clearActiveStateIfIdle(state)

        let restored = try XCTUnwrap(activeStore.load())
        XCTAssertEqual(restored.phase, .idle)
        XCTAssertEqual(restored.parkedStartAnchor, anchor)
    }

    func testCompletionCoordinatorKeepsIdleVehicleParkingAnchorCheckpoint() throws {
        let persistence = try PersistenceController(inMemory: true)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeStore,
            configuration: .automatic
        )
        let anchor = sample(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            metersNorth: 0,
            speed: 0,
            hint: .stationary
        )
        var state = DriveCaptureState()
        state.vehicleParkingAnchor = anchor

        try coordinator.clearActiveStateIfIdle(state)

        let restored = try XCTUnwrap(activeStore.load())
        XCTAssertEqual(restored.phase, .idle)
        XCTAssertNil(restored.parkedStartAnchor)
        XCTAssertEqual(restored.vehicleParkingAnchor, anchor)
    }

    func testCompletionCoordinatorKeepsRecordingCheckpoint() throws {
        // Pins the new-leg split invariant: after a mid-drive split the state handed
        // to clearActiveStateIfIdle is a live recording, which must be re-saved —
        // never cleared — or the new leg's checkpoint would be wiped.
        let persistence = try PersistenceController(inMemory: true)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeStore,
            configuration: .automatic
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            pendingTripID: UUID(),
            phase: .recording,
            startedAt: start,
            samples: [sample(at: start, metersNorth: 0)]
        )

        try coordinator.clearActiveStateIfIdle(state)

        let restored = try XCTUnwrap(activeStore.load())
        XCTAssertEqual(restored.phase, .recording)
        XCTAssertEqual(restored.startedAt, start)
        XCTAssertEqual(restored.samples.count, 1)
    }

    func testCompletionCoordinatorClearsIdleCheckpointWithoutParkedAnchor() throws {
        let persistence = try PersistenceController(inMemory: true)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeStore,
            configuration: .automatic
        )
        try activeStore.save(DriveCaptureState())

        try coordinator.clearActiveStateIfIdle(DriveCaptureState())

        XCTAssertNil(try activeStore.load())
    }

    func testCompletionCoordinatorPersistsOverlappingAutomaticTripsWithDifferentUUIDs() throws {
        let persistence = try PersistenceController(inMemory: true)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeStore,
            configuration: .automatic
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TripDraft(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(300),
            samples: [sample(at: start, metersNorth: 0), sample(at: start.addingTimeInterval(300), metersNorth: 1_000)],
            distanceMeters: 1_000
        )
        let second = TripDraft(
            id: UUID(),
            startDate: start.addingTimeInterval(20),
            endDate: start.addingTimeInterval(280),
            samples: [sample(at: start.addingTimeInterval(20), metersNorth: 20), sample(at: start.addingTimeInterval(280), metersNorth: 980)],
            distanceMeters: 980
        )

        let firstResult = try XCTUnwrap(try coordinator.complete(first, monitoringSessionID: nil).savedResult)
        let secondResult = try XCTUnwrap(try coordinator.complete(second, monitoringSessionID: nil).savedResult)

        XCTAssertEqual(firstResult.trip.id, first.id)
        XCTAssertEqual(secondResult.trip.id, second.id)
        XCTAssertNotEqual(firstResult.trip.id, secondResult.trip.id)
        XCTAssertEqual(Set(try tripStore.fetchTrips().map(\.id)), [first.id, second.id])
    }

    func testCommittedReviewSurvivesReloadAndTripFinalization() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = ActiveDriveStore(context: persistence.container.viewContext)
        let trips = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let id = try XCTUnwrap(reducer.state.pendingTripID)
        try reducer.commitCurrentDriveEdit(.classification(.business, purpose: "Client visit"), expectedID: id) {
            try store.save($0)
        }
        var restored = DriveCaptureReducer(state: try XCTUnwrap(store.load()))
        let outputs = restored.completeCurrentRecording(at: start.addingTimeInterval(600))
        let draft = try XCTUnwrap(outputs.completedDraft)
        let coordinator = DriveCompletionCoordinator(tripStore: trips, activeDriveStore: store, configuration: .automatic)
        _ = try coordinator.complete(draft, monitoringSessionID: nil)
        let saved = try trips.fetchTrip(id: id)
        XCTAssertEqual(saved.classification, .business)
        XCTAssertEqual(saved.businessPurpose, "Client visit")
    }

    func testActiveDriveStorePersistsPendingCompletion() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = ActiveDriveStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let conflictingVehicleID = UUID()
        let draft = TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(300),
            samples: [sample(at: start, metersNorth: 0), sample(at: start.addingTimeInterval(300), metersNorth: 1_000)],
            distanceMeters: 1_000,
            vehicleID: UUID(),
            vehicleAssignmentSource: .vehicleConnection,
            conflictingVehicleIDs: [conflictingVehicleID]
        )
        var state = DriveCaptureState()
        state.pendingCompletionDraft = draft

        try store.save(state)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored.pendingCompletionDraft?.id, draft.id)
        XCTAssertEqual(restored.pendingCompletionDraft?.conflictingVehicleIDs, [conflictingVehicleID])
    }

    func testTagSamplesFailureDoesNotBlockCompletionAndRecompletionIsIdempotent() throws {
        // The trip row is committed before tagging runs; a tagging throw used
        // to abort complete() *after* the save, so the runtime's pending draft
        // was never cleared and retried the poisoned completion forever.
        let persistence = try PersistenceController(inMemory: true)
        let activeStore = ActiveDriveStore(context: persistence.container.viewContext)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let throwingDiagnostics = ThrowingDiagnosticSampleStore()
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeStore,
            diagnosticSampleStore: throwingDiagnostics,
            configuration: .automatic
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = TripDraft(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(300),
            samples: [sample(at: start, metersNorth: 0), sample(at: start.addingTimeInterval(300), metersNorth: 1_000)],
            distanceMeters: 1_000
        )

        let first = try XCTUnwrap(try coordinator.complete(draft, monitoringSessionID: UUID()).savedResult)
        XCTAssertEqual(first.trip.id, draft.id)
        XCTAssertGreaterThan(throwingDiagnostics.tagAttempts, 0, "tagging must still be attempted")

        // A retry of the same draft (the runtime's recovery path) must also
        // resolve as saved rather than duplicating or throwing.
        let second = try XCTUnwrap(try coordinator.complete(draft, monitoringSessionID: UUID()).savedResult)
        XCTAssertEqual(second.trip.id, draft.id)
        XCTAssertEqual(try tripStore.fetchTrips().map(\.id), [draft.id])
    }
}

private final class ThrowingDiagnosticSampleStore: DiagnosticSamplePersisting {
    private(set) var tagAttempts = 0

    func save(_ sample: DiagnosticLocationSample) throws -> DiagnosticLocationSample { sample }
    func fetchSamples(since startDate: Date?, until endDate: Date?) throws -> [DiagnosticLocationSample] { [] }
    func tagSamples(monitoringSessionID: UUID, tripID: UUID, from startDate: Date, to endDate: Date) throws -> Int {
        tagAttempts += 1
        throw DiagnosticSampleStoreError.invalidDateRange
    }
    func tagSamples(tripID: UUID, from startDate: Date, to endDate: Date) throws -> Int {
        tagAttempts += 1
        throw DiagnosticSampleStoreError.invalidDateRange
    }
    func purgeExpiredSamples(now: Date) throws -> Int { 0 }
    func applyRetentionPolicy(retentionDays: Int, now: Date, preservingFrom: Date?) throws -> Int { 0 }
}

private extension DriveCaptureCheckpointIntegrationTests {
    func startRecording(_ reducer: inout DriveCaptureReducer, start: Date) {
        let first = sample(at: start, metersNorth: 0, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(45), metersNorth: 1_000, speed: 12, hint: .automotive)
        let context = TripDetectionContext(trustedBluetoothVehicleHint: true)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: context, options: .normal))
        _ = reducer.apply(.location(second, receivedAt: second.timestamp, context: context, options: .normal))
    }

    func enterTrafficStopHold(_ reducer: inout DriveCaptureReducer, start: Date) -> [DriveCaptureOutput] {
        let highway = sample(at: start.addingTimeInterval(120), metersNorth: 2_200, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(highway, receivedAt: highway.timestamp, context: TripDetectionContext(), options: .normal))

        let disconnectAt = start.addingTimeInterval(165)
        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .usbPower, at: disconnectAt))
        let slowAfterPower = sample(at: start.addingTimeInterval(166), metersNorth: 2_205, speed: 0.2, hint: .automotive)
        _ = reducer.apply(.location(slowAfterPower, receivedAt: slowAfterPower.timestamp, context: TripDetectionContext(), options: .normal))

        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .bluetoothAudio, at: start.addingTimeInterval(167)))
        let slowAfterBluetooth = sample(at: start.addingTimeInterval(180), metersNorth: 2_208, speed: 0.2, hint: .automotive)
        _ = reducer.apply(.location(slowAfterBluetooth, receivedAt: slowAfterBluetooth.timestamp, context: TripDetectionContext(), options: .normal))

        let falseWalking = sample(at: start.addingTimeInterval(188), metersNorth: 2_212, speed: 0.5, hint: .walking)
        return reducer.apply(.location(falseWalking, receivedAt: falseWalking.timestamp, context: TripDetectionContext(), options: .normal))
    }

    func completeWithConfirmedWalkAway(
        _ reducer: inout DriveCaptureReducer,
        start: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (dropoff: LocationSample, draft: TripDraft) {
        let dropoff = sample(at: start.addingTimeInterval(600), metersNorth: 5_000, speed: 10, hint: .automotive)
        _ = reducer.apply(.location(
            dropoff,
            receivedAt: dropoff.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        let firstWalking = sample(at: start.addingTimeInterval(640), metersNorth: 5_040, speed: 1.4, hint: .walking)
        let firstOutputs = reducer.apply(.location(
            firstWalking,
            receivedAt: firstWalking.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        XCTAssertNil(firstOutputs.completedDraft, file: file, line: line)

        let confirmedWalking = sample(at: start.addingTimeInterval(651), metersNorth: 5_060, speed: 1.4, hint: .walking)
        let endOutputs = reducer.apply(.location(
            confirmedWalking,
            receivedAt: confirmedWalking.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let draft = try XCTUnwrap(endOutputs.completedDraft, file: file, line: line)
        return (dropoff, draft)
    }

    func sample(
        at date: Date,
        metersNorth: Double,
        speed: Double? = 12,
        hint: MotionHint = .automotive,
        horizontalAccuracy: Double = 10
    ) -> LocationSample {
        LocationSample(
            timestamp: date,
            latitude: 40 + metersNorth / 111_111,
            longitude: -73,
            horizontalAccuracy: horizontalAccuracy,
            speedMetersPerSecond: speed,
            motionHint: hint
        )
    }
}

private extension Array where Element == DriveCaptureOutput {
    var completedDraft: TripDraft? {
        compactMap { output in
            if case .tripCompleted(let draft) = output {
                return draft
            }
            return nil
        }.first
    }

    var containsCandidateStarted: Bool {
        contains { output in
            if case .candidateStarted = output {
                return true
            }
            return false
        }
    }

    var containsTripStarted: Bool {
        contains { output in
            if case .tripStarted = output {
                return true
            }
            return false
        }
    }

    func containsIgnored(containing text: String) -> Bool {
        contains { output in
            if case .ignored(let reason) = output {
                return reason.contains(text)
            }
            return false
        }
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
