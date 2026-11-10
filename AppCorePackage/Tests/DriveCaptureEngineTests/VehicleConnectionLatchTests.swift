import XCTest
import AppCoreModels
@testable import DriveCaptureEngine

final class VehicleConnectionLatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstMappedConnectionLatchesAndDifferentConnectionOnlyConflicts() throws {
        let first = UUID()
        let second = UUID()
        var reducer = DriveCaptureReducer(state: recordingState())

        XCTAssertFalse(reducer.observeMappedVehicleConnection(first).isEmpty)
        XCTAssertEqual(reducer.state.startVehicleHint, first)
        XCTAssertEqual(reducer.state.startVehicleAssignmentSource, .vehicleConnection)
        XCTAssertTrue(reducer.state.conflictingVehicleIDs.isEmpty)

        XCTAssertTrue(reducer.observeMappedVehicleConnection(nil).isEmpty, "disconnect does not clear the latch")
        XCTAssertTrue(reducer.observeMappedVehicleConnection(first).isEmpty, "same vehicle is harmless")
        XCTAssertFalse(reducer.observeMappedVehicleConnection(second).isEmpty)
        XCTAssertEqual(reducer.state.startVehicleHint, first)
        XCTAssertEqual(reducer.state.conflictingVehicleIDs, [second])
        XCTAssertTrue(reducer.observeMappedVehicleConnection(second).isEmpty, "duplicate conflict is ignored")

        let draft = try XCTUnwrap(completedDraft(
            reducer.completeCurrentRecording(at: start.addingTimeInterval(180))
        ))
        XCTAssertEqual(draft.vehicleID, first)
        XCTAssertEqual(draft.vehicleAssignmentSource, .vehicleConnection)
    }

    func testManualSelectionWinsAndClearsConflicts() {
        let mapped = UUID()
        let conflicting = UUID()
        let manual = UUID()
        var reducer = DriveCaptureReducer(state: recordingState())
        _ = reducer.observeMappedVehicleConnection(mapped)
        _ = reducer.observeMappedVehicleConnection(conflicting)

        _ = reducer.setCurrentDriveVehicle(manual)

        XCTAssertEqual(reducer.state.startVehicleHint, manual)
        XCTAssertEqual(reducer.state.startVehicleAssignmentSource, .manual)
        XCTAssertTrue(reducer.state.conflictingVehicleIDs.isEmpty)
        XCTAssertTrue(reducer.observeMappedVehicleConnection(mapped).isEmpty)
        XCTAssertEqual(reducer.state.startVehicleHint, manual)
    }

    func testLegacyShortcutLatchIsNotRewrittenByMappedConnection() throws {
        let shortcut = UUID()
        let mapped = UUID()
        var state = recordingState()
        state.startVehicleHint = shortcut
        state.startVehicleAssignmentSource = .shortcut
        var reducer = DriveCaptureReducer(state: state)

        _ = reducer.observeMappedVehicleConnection(mapped)

        XCTAssertEqual(reducer.state.startVehicleHint, shortcut)
        XCTAssertEqual(reducer.state.startVehicleAssignmentSource, .shortcut)
        XCTAssertEqual(reducer.state.conflictingVehicleIDs, [mapped])
        let draft = try XCTUnwrap(completedDraft(
            reducer.completeCurrentRecording(at: start.addingTimeInterval(180))
        ))
        XCTAssertEqual(draft.vehicleAssignmentSource, .shortcut)
    }

    func testConnectionLatchRoundTripsAndSplitCarriesSourceAndConflict() throws {
        let latched = UUID()
        let conflict = UUID()
        var reducer = DriveCaptureReducer(state: recordingState())
        _ = reducer.observeMappedVehicleConnection(latched)
        _ = reducer.observeMappedVehicleConnection(conflict)

        let restoredState = try JSONDecoder().decode(
            DriveCaptureState.self,
            from: JSONEncoder().encode(reducer.state)
        )
        XCTAssertEqual(restoredState.startVehicleHint, latched)
        XCTAssertEqual(restoredState.startVehicleAssignmentSource, .vehicleConnection)
        XCTAssertEqual(restoredState.conflictingVehicleIDs, [conflict])

        var restored = DriveCaptureReducer(state: restoredState)
        let outputs = restored.splitCurrentRecording(at: start.addingTimeInterval(150))
        let draft = try XCTUnwrap(completedDraft(outputs))
        XCTAssertEqual(draft.vehicleAssignmentSource, .vehicleConnection)
        XCTAssertEqual(restored.state.startVehicleHint, latched)
        XCTAssertEqual(restored.state.startVehicleAssignmentSource, .vehicleConnection)
        XCTAssertEqual(restored.state.conflictingVehicleIDs, [conflict])
    }

    func testTrackingPauseWithoutActiveDriveCannotPreLatchVehicle() {
        let vehicle = UUID()
        var state = DriveCaptureState()
        state.phase = .paused
        state.pausedUntil = start.addingTimeInterval(86_400)
        var reducer = DriveCaptureReducer(state: state)

        XCTAssertTrue(reducer.observeMappedVehicleConnection(vehicle).isEmpty)
        XCTAssertNil(reducer.state.startVehicleHint)
        XCTAssertNil(reducer.state.startVehicleAssignmentSource)
    }

    func testPausedInProgressDriveCanStillLatchVehicle() {
        let vehicle = UUID()
        var reducer = DriveCaptureReducer(state: recordingState())
        _ = reducer.apply(.trackingPaused(until: start.addingTimeInterval(3_600)))

        XCTAssertFalse(reducer.observeMappedVehicleConnection(vehicle).isEmpty)
        XCTAssertEqual(reducer.state.startVehicleHint, vehicle)
        XCTAssertEqual(reducer.state.startVehicleAssignmentSource, .vehicleConnection)
    }

    private func recordingState() -> DriveCaptureState {
        var state = DriveCaptureState()
        state.phase = .recording
        state.startedAt = start
        state.pendingTripID = UUID()
        state.samples = [
            sample(at: start, metersNorth: 0),
            sample(at: start.addingTimeInterval(120), metersNorth: 1_500)
        ]
        state.lastMovingAt = start.addingTimeInterval(120)
        return state
    }

    private func sample(at date: Date, metersNorth: Double) -> LocationSample {
        LocationSample(
            timestamp: date,
            latitude: 40 + metersNorth / 111_111,
            longitude: -73,
            horizontalAccuracy: 10,
            speedMetersPerSecond: 12,
            motionHint: .automotive
        )
    }

    private func completedDraft(_ outputs: [DriveCaptureOutput]) -> TripDraft? {
        outputs.compactMap { output -> TripDraft? in
            guard case .tripCompleted(let draft) = output else { return nil }
            return draft
        }.first
    }
}
