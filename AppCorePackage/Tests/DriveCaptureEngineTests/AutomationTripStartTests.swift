import XCTest
import AppCoreModels
@testable import DriveCaptureEngine

final class AutomationTripStartTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testBothDefaultPreservesStoredSelections() throws {
        XCTAssertEqual(DriveCaptureState().automaticTripStartMode, .both)
        XCTAssertEqual(try JSONDecoder().decode(DriveCaptureState.self, from: Data("{}".utf8)).automaticTripStartMode, .both)
        XCTAssertEqual(AutomaticTripStartMode(rawValue: "allDrives"), .motionDetection)
        XCTAssertEqual(AutomaticTripStartMode(rawValue: "savedCarsOnly"), .bluetoothOrCarPlay)
        XCTAssertEqual(AutomaticTripStartMode(rawValue: "both"), .both)
        XCTAssertEqual(AutomaticTripStartMode.allCases.count, 3)
        for mode in AutomaticTripStartMode.allCases {
            let restored = try roundTrip(DriveCaptureState(automaticTripStartMode: mode))
            XCTAssertEqual(restored.automaticTripStartMode, mode)
        }
        var reducer = DriveCaptureReducer()
        feedDrive(&reducer)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    func testThreeModesHaveDistinctPassiveAndCarAutomationAdmission() {
        for mode in AutomaticTripStartMode.allCases {
            var passive = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: mode))
            let first = sample(offset: 0)
            _ = passive.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(), options: .normal))
            XCTAssertEqual(passive.state.phase, mode == .bluetoothOrCarPlay ? .idle : .candidate, "Passive motion in \(mode)")
            for trigger in [DriveStartExternalTrigger.vehicleBluetooth, .carPlay] {
                var automated = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: mode))
                arm(&automated, trigger: trigger)
                XCTAssertEqual(automated.state.phase, mode == .motionDetection ? .idle : .candidate, "Car automation in \(mode)")
            }
            for trigger in [DriveStartExternalTrigger.manual, .charger] {
                var other = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: mode))
                arm(&other, trigger: trigger)
                XCTAssertEqual(other.state.phase, mode == .bluetoothOrCarPlay ? .idle : .candidate, "Existing \(trigger) control in \(mode)")
            }
            var unspecified = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: mode))
            _ = unspecified.apply(.startSignal(DriveStartEngine.signal(source: .externalVehicleAutomation, startedAt: start), receivedAt: start))
            XCTAssertEqual(unspecified.state.phase, mode == .both ? .candidate : .idle)
        }
    }

    func testOverlappingBluetoothAndCarPlayGrantsPreserveEarlierAuthorizedMovement() throws {
        var reducer = automationReducer()
        arm(&reducer, trigger: .vehicleBluetooth)
        let later = DriveStartEngine.signal(forExternalTrigger: .carPlay, at: start.addingTimeInterval(10))
        _ = reducer.apply(.startSignal(later, receivedAt: later.startedAt))
        XCTAssertEqual(reducer.state.vehicleAutomationStartSignal?.startedAt, start)
        XCTAssertEqual(reducer.state.vehicleAutomationStartSignal?.expiresAt, later.expiresAt)
        let delayed = sample(offset: 9)
        let outputs = reducer.apply(.location(delayed, receivedAt: start.addingTimeInterval(11), context: TripDetectionContext(), options: .normal))
        XCTAssertFalse(outputs.contains(.ignored(DriveCaptureReducer.automaticStartSuppressedReason)))
        XCTAssertTrue(reducer.state.candidateSamples.contains(delayed))
        XCTAssertNil(reducer.state.automaticStartExcludedThrough)
        let restored = DriveCaptureReducer(state: try roundTrip(reducer.state))
        XCTAssertTrue(restored.allowsAutomaticTripStart(at: start.addingTimeInterval(9)))
    }

    func testGrantAfterExpiryGapReplacesOldAdmissionWindow() {
        var reducer = automationReducer()
        arm(&reducer, trigger: .vehicleBluetooth)
        let later = DriveStartEngine.signal(forExternalTrigger: .carPlay, at: start.addingTimeInterval(400))
        _ = reducer.apply(.startSignal(later, receivedAt: later.startedAt))
        XCTAssertEqual(reducer.state.vehicleAutomationStartSignal?.startedAt, later.startedAt)
        XCTAssertFalse(reducer.allowsAutomaticTripStart(at: start.addingTimeInterval(350)))
        let gap = sample(offset: 350)
        let outputs = reducer.apply(.location(gap, receivedAt: start.addingTimeInterval(401), context: TripDetectionContext(), options: .normal))
        XCTAssertTrue(outputs.contains(.ignored(DriveCaptureReducer.automaticStartSuppressedReason)))
        XCTAssertFalse(reducer.state.candidateSamples.contains(gap))
    }

    func testIncidentalSignalsAndGenericExternalSourceCannotAuthorizeStart() {
        let sources: [DriveStartSignalSource] = [
            .motionAutomotive, .trustedBluetooth, .weakBluetoothName, .usbPower,
            .parkedAnchorExit, .acceptedVehicleLocation, .coarseLocationWake,
            .significantLocationChange, .visitDeparture, .externalVehicleAutomation, .externalChargerAutomation
        ]
        for source in sources {
            var reducer = automationReducer()
            _ = reducer.apply(.startSignal(DriveStartEngine.signal(source: source, startedAt: start), receivedAt: start))
            XCTAssertEqual(reducer.state.phase, .idle, "\(source) must not bypass trigger selection")
            XCTAssertNil(reducer.state.pendingTripID)
        }
        for trigger in [DriveStartExternalTrigger.manual, .charger] {
            var reducer = automationReducer()
            arm(&reducer, trigger: trigger)
            feedDrive(&reducer)
            XCTAssertEqual(reducer.state.phase, .idle)
        }
    }

    func testMotionAndActualTrustedAudioRouteDoNotReplaceAutomation() {
        var reducer = automationReducer()
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .carPlayAudio, at: start))
        _ = reducer.apply(.motionActivity(MotionActivitySnapshot(startDate: start, confidence: .high, hints: [.automotive]), receivedAt: start))
        feedDrive(&reducer)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.currentDriveSummary())
    }

    func testBluetoothAndCarPlayAutomationsArmWithoutMappingButRequireMovement() {
        for trigger in [DriveStartExternalTrigger.vehicleBluetooth, .carPlay] {
            var reducer = automationReducer()
            arm(&reducer, trigger: trigger)
            XCTAssertEqual(reducer.state.phase, .candidate)
            XCTAssertNil(reducer.state.currentDriveSummary())
            XCTAssertNil(reducer.state.startVehicleHint)
            feedDrive(&reducer)
            XCTAssertEqual(reducer.state.phase, .recording)
            XCTAssertNil(reducer.state.vehicleAutomationStartSignal, "A confirmed drive consumes its start permission")
        }
    }

    func testPassiveManualAndChargerSignalsCannotExtendAutomationPermission() throws {
        var reducer = automationReducer()
        arm(&reducer, trigger: .carPlay)
        let deadline = try XCTUnwrap(reducer.state.vehicleAutomationStartSignal?.expiresAt)
        let later = deadline.addingTimeInterval(-10)
        for signal in [
            DriveStartEngine.signal(source: .motionAutomotive, startedAt: later),
            DriveStartEngine.signal(source: .trustedBluetooth, startedAt: later),
            DriveStartEngine.signal(forExternalTrigger: .manual, at: later),
            DriveStartEngine.signal(forExternalTrigger: .charger, at: later)
        ] {
            _ = reducer.apply(.startSignal(signal, receivedAt: later))
        }
        XCTAssertEqual(reducer.state.vehicleAutomationStartSignal?.expiresAt, deadline)
        XCTAssertEqual(reducer.state.startSignal?.expiresAt, deadline)
        _ = reducer.finalizeIfDue(now: deadline.addingTimeInterval(1))
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertFalse(reducer.allowsAutomaticTripStart(at: deadline.addingTimeInterval(1)))
    }

    func testExpiredAutomationCannotAuthorizeAndFreshAutomationCanRearm() {
        var reducer = automationReducer()
        let signal = DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start)
        _ = reducer.apply(.startSignal(signal, receivedAt: signal.expiresAt.addingTimeInterval(1)))
        XCTAssertEqual(reducer.state.phase, .idle)
        _ = reducer.apply(.startSignal(DriveStartEngine.signal(forExternalTrigger: .carPlay, at: signal.expiresAt.addingTimeInterval(2)), receivedAt: signal.expiresAt.addingTimeInterval(2)))
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    func testActiveTripSurvivesDisconnectAndDoesNotAuthorizeNextTrip() throws {
        var reducer = automationReducer()
        arm(&reducer, trigger: .carPlay)
        feedDrive(&reducer)
        let id = reducer.state.pendingTripID
        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .carPlayAudio, at: start.addingTimeInterval(46)))
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.pendingTripID, id)
        _ = reducer.completeCurrentRecording(at: start.addingTimeInterval(60))
        let next = sample(offset: 90)
        _ = reducer.apply(.location(next, receivedAt: next.timestamp, context: TripDetectionContext(trustedBluetoothVehicleHint: true), options: .normal))
        XCTAssertEqual(reducer.state.phase, .idle)
    }

    func testCheckpointRequiresExplicitUnexpiredAutomationButPreservesRecording() throws {
        var reducer = automationReducer()
        arm(&reducer, trigger: .carPlay)
        var restored = DriveCaptureReducer(state: try roundTrip(reducer.state))
        XCTAssertTrue(restored.allowsAutomaticTripStart(at: start.addingTimeInterval(1)))
        _ = restored.refreshAutomaticStartEligibility(at: start.addingTimeInterval(1))
        XCTAssertEqual(restored.state.phase, .candidate)
        var legacy = reducer.state
        legacy.vehicleAutomationStartSignal = nil
        var legacyRestored = DriveCaptureReducer(state: try roundTrip(legacy))
        _ = legacyRestored.finalizeIfDue(now: start.addingTimeInterval(1))
        XCTAssertEqual(legacyRestored.state.phase, .idle)
        _ = restored.finalizeIfDue(now: start.addingTimeInterval(600))
        XCTAssertEqual(restored.state.phase, .idle)
        feedDrive(&reducer)
        let recording = DriveCaptureReducer(state: try roundTrip(reducer.state))
        XCTAssertEqual(recording.state.phase, .recording)
        XCTAssertEqual(recording.state.pendingTripID, reducer.state.pendingTripID)
    }

    func testModeSwitchRequiresFreshAutomationAndKeepsAlreadyRecordedDrive() {
        var candidate = DriveCaptureReducer()
        let first = sample(offset: 0)
        _ = candidate.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(), options: .normal))
        _ = candidate.setAutomaticTripStartMode(.bluetoothOrCarPlay, at: start)
        XCTAssertEqual(candidate.state.phase, .idle)
        var recording = DriveCaptureReducer()
        feedDrive(&recording)
        let id = recording.state.pendingTripID
        _ = recording.setAutomaticTripStartMode(.bluetoothOrCarPlay, at: start.addingTimeInterval(46))
        XCTAssertEqual(recording.state.phase, .recording)
        XCTAssertEqual(recording.state.pendingTripID, id)
    }

    func testAutomationCannotOverridePauseAndQueuedSampleKeepsRecoveryExclusion() {
        var reducer = automationReducer()
        _ = reducer.apply(.trackingPaused(until: start.addingTimeInterval(3_600)))
        arm(&reducer, trigger: .carPlay)
        let outputs = reducer.apply(.location(sample(offset: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))
        XCTAssertTrue(outputs.contains(.ignored(DriveCaptureReducer.automaticStartSuppressedReason)))
        XCTAssertNil(reducer.state.vehicleAutomationStartSignal)
        XCTAssertEqual(reducer.state.phase, .paused)
    }

    func testDeniedHistoryCannotBackdateLaterAutomationDriveAfterRelaunch() throws {
        var state = DriveCaptureState(automaticTripStartMode: .bluetoothOrCarPlay)
        state.vehicleParkingAnchor = sample(offset: 0)
        var reducer = DriveCaptureReducer(state: state)
        let denied = sample(offset: 10)
        _ = reducer.apply(.location(denied, receivedAt: denied.timestamp, context: TripDetectionContext(), options: .staleWake))
        XCTAssertNil(reducer.state.vehicleParkingAnchor)
        var restored = DriveCaptureReducer(state: try roundTrip(reducer.state))
        let signal = DriveStartEngine.signal(forExternalTrigger: .carPlay, at: start.addingTimeInterval(20))
        _ = restored.apply(.startSignal(signal, receivedAt: start.addingTimeInterval(20)))
        _ = restored.apply(.location(sample(offset: 0), receivedAt: start.addingTimeInterval(21), context: TripDetectionContext(), options: .normal))
        for offset in [20, 35, 50, 65] {
            let sample = sample(offset: offset)
            _ = restored.apply(.location(sample, receivedAt: sample.timestamp, context: TripDetectionContext(trustedBluetoothVehicleHint: true), options: .normal))
        }
        XCTAssertEqual(restored.state.phase, .recording)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(restored.state.startedAt), signal.startedAt)
        XCTAssertTrue(restored.state.samples.allSatisfy { $0.timestamp >= signal.startedAt })
    }

    private func automationReducer() -> DriveCaptureReducer {
        DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .bluetoothOrCarPlay))
    }

    private func arm(_ reducer: inout DriveCaptureReducer, trigger: DriveStartExternalTrigger) {
        _ = reducer.apply(.startSignal(DriveStartEngine.signal(forExternalTrigger: trigger, at: start), receivedAt: start))
    }

    private func roundTrip(_ state: DriveCaptureState) throws -> DriveCaptureState {
        try JSONDecoder().decode(DriveCaptureState.self, from: JSONEncoder().encode(state))
    }

    private func sample(offset: Int) -> LocationSample {
        LocationSample(timestamp: start.addingTimeInterval(Double(offset)), latitude: 40 + Double(offset) * 12 / 111_111,
                       longitude: -73, horizontalAccuracy: 10, speedMetersPerSecond: 12, motionHint: .automotive)
    }

    private func feedDrive(_ reducer: inout DriveCaptureReducer) {
        for offset in [0, 15, 30, 45] {
            let sample = sample(offset: offset)
            _ = reducer.apply(.location(sample, receivedAt: sample.timestamp, context: TripDetectionContext(trustedBluetoothVehicleHint: true), options: .normal))
        }
    }
}
