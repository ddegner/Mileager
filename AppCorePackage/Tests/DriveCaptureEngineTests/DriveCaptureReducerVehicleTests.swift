import XCTest
import AppCoreModels
@testable import DriveCaptureEngine

final class DriveCaptureReducerVehicleTests: XCTestCase {
    private func vehicleStartSignal(vehicleID: UUID, at start: Date) -> DriveStartSignal {
        DriveStartSignal(
            source: .externalVehicleAutomation,
            confidence: .strong,
            startedAt: start,
            expiresAt: start.addingTimeInterval(300),
            vehicleID: vehicleID
        )
    }

    func testStartVehicleHintCapturedInIdle() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let vehicle = UUID()
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(vehicleStartSignal(vehicleID: vehicle, at: start), receivedAt: start))
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.startVehicleHint, vehicle)
    }

    private func sample(
        at date: Date,
        metersNorth: Double,
        speed: Double?,
        hint: MotionHint = .automotive
    ) -> LocationSample {
        LocationSample(
            timestamp: date,
            latitude: 40 + metersNorth / 111_111,
            longitude: -73,
            horizontalAccuracy: 10,
            speedMetersPerSecond: speed,
            motionHint: hint
        )
    }

    /// The short-trip rescue path bypasses completeRecording, whose hint clear
    /// keeps a Shortcut's vehicle from leaking into the next capture. A leak
    /// here tagged the NEXT (location-armed) drive with the wrong vehicle at
    /// `.shortcut` precedence, which also blocks Bluetooth re-attribution.
    func testShortTripRescueClearsStartVehicleHint() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let vehicle = UUID()
        var state = DriveCaptureState()
        state.phase = .candidate
        state.candidateStartedAt = start
        state.candidateHadBluetoothHint = true
        state.pendingTripID = UUID()
        state.startVehicleHint = vehicle
        state.startSignal = DriveStartSignal(
            source: .trustedBluetooth,
            confidence: .strong,
            startedAt: start,
            expiresAt: start.addingTimeInterval(3_600)
        )
        let candidateSamples = [
            sample(at: start, metersNorth: 0, speed: 8),
            sample(at: start.addingTimeInterval(20), metersNorth: 300, speed: 8)
        ]
        state.candidateSamples = candidateSamples
        state.lastAcceptedSample = candidateSamples.last
        var reducer = DriveCaptureReducer(state: state)

        // A stationary sample contradicts the candidate and rescues the short trip.
        let parkedAtEnd = sample(at: start.addingTimeInterval(24), metersNorth: 300, speed: 0, hint: .stationary)
        let outputs = reducer.apply(.location(
            parkedAtEnd,
            receivedAt: parkedAtEnd.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        let draft = try XCTUnwrap(outputs.compactMap { output -> TripDraft? in
            if case .tripCompleted(let draft) = output { return draft }
            return nil
        }.first)
        // The rescued trip keeps its vehicle...
        XCTAssertEqual(draft.vehicleID, vehicle)
        XCTAssertEqual(draft.vehicleAssignmentSource, .shortcut)
        // ...but the in-flight hint must not survive into the next capture.
        XCTAssertNil(reducer.state.startVehicleHint)
    }

    /// "New Leg" completes the current recording (which clears the hint) and
    /// immediately starts the next one — in the same car, so the continuing
    /// leg must keep the Shortcut vehicle rather than fall back to nothing.
    func testSplitCarriesVehicleHintToContinuingLeg() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let vehicle = UUID()
        var state = DriveCaptureState()
        state.phase = .recording
        state.startedAt = start
        state.startVehicleHint = vehicle
        state.samples = [
            sample(at: start, metersNorth: 0, speed: 12),
            sample(at: start.addingTimeInterval(120), metersNorth: 1_500, speed: 12)
        ]
        state.lastMovingAt = start.addingTimeInterval(120)
        var reducer = DriveCaptureReducer(state: state)

        let outputs = reducer.splitCurrentRecording(at: start.addingTimeInterval(150))

        let draft = try XCTUnwrap(outputs.compactMap { output -> TripDraft? in
            if case .tripCompleted(let draft) = output { return draft }
            return nil
        }.first)
        XCTAssertEqual(draft.vehicleID, vehicle)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startVehicleHint, vehicle, "continuing leg keeps the vehicle")
    }

    func testStartVehicleHintRoundTripsThroughState() throws {
        let vehicle = UUID()
        let state = DriveCaptureState(startVehicleHint: vehicle, startVehicleIsManual: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DriveCaptureState.self, from: encoder.encode(state))
        XCTAssertEqual(restored.startVehicleHint, vehicle)
        XCTAssertTrue(restored.startVehicleIsManual)
        // Legacy state without the keys decodes to nil / false.
        XCTAssertNil(DriveCaptureState().startVehicleHint)
        XCTAssertFalse(DriveCaptureState().startVehicleIsManual)
    }

    private func recordingState(vehicleHint: UUID? = nil, at start: Date) -> DriveCaptureState {
        var state = DriveCaptureState()
        state.phase = .recording
        state.startedAt = start
        state.pendingTripID = UUID()
        state.startVehicleHint = vehicleHint
        state.samples = [
            sample(at: start, metersNorth: 0, speed: 12),
            sample(at: start.addingTimeInterval(120), metersNorth: 1_500, speed: 12)
        ]
        state.lastMovingAt = start.addingTimeInterval(120)
        return state
    }

    private func completedDraft(_ outputs: [DriveCaptureOutput]) -> TripDraft? {
        outputs.compactMap { output -> TripDraft? in
            if case .tripCompleted(let draft) = output { return draft }
            return nil
        }.first
    }

    /// A live-bar pick overrides the Shortcut's vehicle and stamps the trip
    /// `.manual`, so automatic re-attribution can never undo the user's choice.
    func testLiveBarVehiclePickOverridesShortcutAndTagsManual() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let shortcutVehicle = UUID()
        let pickedVehicle = UUID()
        var reducer = DriveCaptureReducer(state: recordingState(vehicleHint: shortcutVehicle, at: start))

        _ = reducer.setCurrentDriveVehicle(pickedVehicle)
        let outputs = reducer.completeCurrentRecording(at: start.addingTimeInterval(180))

        let draft = try XCTUnwrap(completedDraft(outputs))
        XCTAssertEqual(draft.vehicleID, pickedVehicle)
        XCTAssertEqual(draft.vehicleAssignmentSource, .manual)
        // The next capture starts clean.
        XCTAssertNil(reducer.state.startVehicleHint)
        XCTAssertFalse(reducer.state.startVehicleIsManual)
    }

    /// Picking "Automatic" reverts to completion-time resolution: no vehicle on
    /// the draft, so Bluetooth mapping can attribute it.
    func testLiveBarAutomaticRevertsToUnattributedDraft() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: recordingState(vehicleHint: UUID(), at: start))

        _ = reducer.setCurrentDriveVehicle(UUID())
        _ = reducer.setCurrentDriveVehicle(nil)
        let outputs = reducer.completeCurrentRecording(at: start.addingTimeInterval(180))

        let draft = try XCTUnwrap(completedDraft(outputs))
        XCTAssertNil(draft.vehicleID)
        XCTAssertNil(draft.vehicleAssignmentSource)
    }

    func testSplitCarriesManualVehiclePickToContinuingLeg() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let picked = UUID()
        var reducer = DriveCaptureReducer(state: recordingState(at: start))

        _ = reducer.setCurrentDriveVehicle(picked)
        let outputs = reducer.splitCurrentRecording(at: start.addingTimeInterval(150))

        let draft = try XCTUnwrap(completedDraft(outputs))
        XCTAssertEqual(draft.vehicleID, picked)
        XCTAssertEqual(draft.vehicleAssignmentSource, .manual)
        XCTAssertEqual(reducer.state.startVehicleHint, picked)
        XCTAssertTrue(reducer.state.startVehicleIsManual, "continuing leg keeps the manual pick")
    }

    func testVehiclePickIgnoredWhenNoDriveInFlight() {
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        XCTAssertTrue(reducer.setCurrentDriveVehicle(UUID()).isEmpty)
        XCTAssertNil(reducer.state.startVehicleHint)
    }
}
