import XCTest
@testable import AppCore

final class ActiveDriveStoreTests: XCTestCase {
    func testLoadRepairsIdleStateWithCompletedPendingTripID() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        let activeDriveStore = ActiveDriveStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try tripStore.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(60),
            samples: [
                LocationSample(timestamp: start, latitude: 40.0, longitude: -73.0, horizontalAccuracy: 8),
                LocationSample(timestamp: start.addingTimeInterval(60), latitude: 40.01, longitude: -73.0, horizontalAccuracy: 8)
            ],
            distanceMeters: 1_100
        ))
        let anchor = LocationSample(
            timestamp: start.addingTimeInterval(300),
            latitude: 40.01,
            longitude: -73.0,
            horizontalAccuracy: 8,
            speedMetersPerSecond: 0,
            motionHint: .stationary
        )
        var state = DriveCaptureState()
        state.phase = .idle
        state.pendingTripID = trip.id
        state.parkedStartAnchor = anchor
        state.vehicleParkingAnchor = anchor
        try activeDriveStore.save(state)

        let loaded = try XCTUnwrap(activeDriveStore.load())
        let persisted = try XCTUnwrap(activeDriveStore.load())

        XCTAssertNil(loaded.pendingTripID)
        XCTAssertEqual(loaded.parkedStartAnchor, anchor)
        XCTAssertEqual(loaded.vehicleParkingAnchor, anchor)
        XCTAssertNil(persisted.pendingTripID)
        XCTAssertEqual(persisted.parkedStartAnchor, anchor)
        XCTAssertEqual(persisted.vehicleParkingAnchor, anchor)
    }

    func testLegacyCheckpointAnchorDecodesAsWakeOnly() throws {
        let anchor = LocationSample(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            latitude: 40.0,
            longitude: -73.0,
            horizontalAccuracy: 8,
            speedMetersPerSecond: 0,
            motionHint: .stationary
        )
        let legacy = DriveCaptureState(parkedStartAnchor: anchor)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DriveCaptureState.self, from: encoder.encode(legacy))

        XCTAssertEqual(restored.parkedStartAnchor, anchor)
        XCTAssertNil(restored.vehicleParkingAnchor)
    }

    func testLoadRepairsLegacyRecentCandidateKilledBeforeItStarted() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = ActiveDriveStore(context: persistence.container.viewContext)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState()
        state.recentCandidate = RecentCandidateSnapshot(
            candidateStartedAt: startedAt,
            samples: [],
            startSignal: nil,
            hadBluetoothHint: false,
            hadPowerHint: false,
            contradictionCount: 0,
            lastContradiction: nil,
            killedAt: startedAt.addingTimeInterval(-51),
            firstMovementAt: nil
        )
        try store.save(state)

        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.recentCandidate?.killedAt, startedAt)
        XCTAssertEqual(try store.load()?.recentCandidate?.killedAt, startedAt)
    }
}
