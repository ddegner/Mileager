import XCTest
import AppCoreModels
@testable import DriveCaptureEngine

final class DriveCaptureReducerTests: XCTestCase {
    func testCandidateStateSurvivesEncoding() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()

        _ = reducer.apply(.location(
            sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
            receivedAt: start,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateSamples.count, 1)
        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureState.self,
            from: JSONEncoder.iso8601.encode(reducer.state)
        )
        XCTAssertEqual(restored.phase, .candidate)
        XCTAssertEqual(restored.candidateSamples.count, 1)
        XCTAssertNotNil(restored.pendingTripID)
    }

    func testIdlePrimingExhaustionSurvivesEncoding() throws {
        let exhaustedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(idlePrimingExhaustedAt: exhaustedAt)

        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureState.self,
            from: JSONEncoder.iso8601.encode(state)
        )

        XCTAssertEqual(restored.phase, .idle)
        XCTAssertEqual(restored.idlePrimingExhaustedAt, exhaustedAt)
    }

    func testDriveStartPolicySurvivesConfigurationEncoding() throws {
        var configuration = DriveCaptureConfiguration.automatic
        configuration.startPolicy.signalHighFidelityWindow = 90
        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureConfiguration.self,
            from: JSONEncoder.iso8601.encode(configuration)
        )

        XCTAssertEqual(restored.startPolicy.signalHighFidelityWindow, 90)
    }

    func testBalancedStartPolicyUsesLowIndicatorDefaults() {
        XCTAssertEqual(DriveStartPolicy.balanced.signalHighFidelityWindow, 180)
        XCTAssertEqual(DriveStartPolicy.balanced.unconfirmedCandidateTimeout, 300)
        XCTAssertEqual(DriveStartPolicy.balanced.parkedAnchorRadiusMeters, 250)
        XCTAssertEqual(DriveStartPolicy.balanced.parkingEnd.trafficStopProtectionWindow, 180)
        XCTAssertEqual(DriveStartPolicy.balanced.parkingEnd.trafficStopMinimumSpeedMetersPerSecond, 8.0)
        XCTAssertEqual(DriveStartPolicy.balanced.parkingEnd.trafficStopHold, 600)
        XCTAssertEqual(DriveStartPolicy.balanced.parkingEnd.pedestrianExitMinimumDistanceMeters, 25)
        XCTAssertEqual(DriveStartPolicy.balanced.parkingEnd.pedestrianExitMinimumDuration, 10)
    }

    func testCurrentDriveSummaryIsOnlyExposedForRecordingOrPausedDrive() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()

        XCTAssertNil(reducer.state.currentDriveSummary())

        let candidate = sample(at: start, metersNorth: 0, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(
            candidate,
            receivedAt: candidate.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertNil(reducer.state.currentDriveSummary())

        startRecording(&reducer, start: start)
        _ = reducer.setCurrentDriveClassification(.business)
        _ = reducer.setCurrentDriveBusinessPurpose("Client visit")
        _ = reducer.setCurrentDriveNote("Parked on Atlantic Ave")
        _ = reducer.appendCurrentDriveFee(TripFee(
            tripID: nil,
            category: .toll,
            amount: 6,
            occurredAt: start
        ))

        let recording = try XCTUnwrap(reducer.state.currentDriveSummary())
        XCTAssertEqual(recording.phase, .recording)
        XCTAssertEqual(recording.classification, .business)
        XCTAssertEqual(recording.businessPurpose, "Client visit")
        XCTAssertEqual(recording.note, "Parked on Atlantic Ave")
        XCTAssertEqual(recording.feeCount, 1)
        XCTAssertGreaterThan(recording.distanceMeters, 0)

        _ = reducer.apply(.trackingPaused(until: start.addingTimeInterval(3_600)))
        let paused = try XCTUnwrap(reducer.state.currentDriveSummary())
        XCTAssertEqual(paused.phase, .paused)
    }

    func testCurrentDriveSummaryConfirmsOnlyRealTripEndAndReturnsToRecording() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        var trafficStopReducer = DriveCaptureReducer()
        startRecording(&trafficStopReducer, start: start)
        _ = enterTrafficStopHold(&trafficStopReducer, start: start)
        XCTAssertEqual(trafficStopReducer.state.parkingEvidence?.signal, .trafficStopHold)
        XCTAssertEqual(
            try XCTUnwrap(trafficStopReducer.state.currentDriveSummary()).phase,
            .recording,
            "traffic-stop protection must not tell the user the trip may have ended"
        )

        var parkingReducer = DriveCaptureReducer()
        startRecording(&parkingReducer, start: start)
        let lastMovingAt = try XCTUnwrap(parkingReducer.state.lastMovingAt)
        let disconnectAt = start.addingTimeInterval(250)
        _ = parkingReducer.apply(.vehicleConnectionChanged(
            active: false,
            source: .carPlayAudio,
            at: disconnectAt
        ))

        let confirming = try XCTUnwrap(parkingReducer.state.currentDriveSummary())
        XCTAssertEqual(confirming.phase, .confirmingTripEnd)
        XCTAssertEqual(confirming.lastMovingAt, lastMovingAt)

        let resumed = sample(
            at: disconnectAt.addingTimeInterval(5),
            metersNorth: 1_100,
            speed: 12,
            hint: .automotive
        )
        _ = parkingReducer.apply(.location(
            resumed,
            receivedAt: resumed.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertNil(parkingReducer.state.parkingEvidence)
        XCTAssertEqual(
            try XCTUnwrap(parkingReducer.state.currentDriveSummary()).phase,
            .recording
        )
    }

    func testPausedCurrentDriveTakesPrecedenceOverTripEndConfirmation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = reducer.apply(.vehicleConnectionChanged(
            active: false,
            source: .carPlayAudio,
            at: start.addingTimeInterval(250)
        ))
        XCTAssertEqual(reducer.state.currentDriveSummary()?.phase, .confirmingTripEnd)

        _ = reducer.apply(.trackingPaused(until: start.addingTimeInterval(3_600)))

        XCTAssertEqual(reducer.state.currentDriveSummary()?.phase, .paused)
        // GPS is off while paused, so a surviving deadline could never be
        // cleared — the runtime would spin its stop timer at zero delay for
        // the whole pause window (2026-08 field freeze).
        XCTAssertNil(reducer.state.stopDueAt)
    }

    func testTrackingPausedThenResumedDoesNotCompleteAtStaleStopDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = reducer.apply(.vehicleConnectionChanged(
            active: false,
            source: .carPlayAudio,
            at: start.addingTimeInterval(250)
        ))
        _ = reducer.apply(.trackingPaused(until: start.addingTimeInterval(3_600)))

        let resumeAt = start.addingTimeInterval(7_200)
        _ = reducer.apply(.trackingResumed(resumeAt))
        let outputs = reducer.finalizeIfDue(now: resumeAt.addingTimeInterval(1))

        XCTAssertEqual(reducer.state.phase, .recording, "the resumed drive must continue")
        XCTAssertNil(reducer.state.stopDueAt, "a pre-pause deadline is stale evidence")
        XCTAssertNil(reducer.state.pendingCompletionDraft)
        XCTAssertFalse(outputs.contains { output in
            if case .tripCompleted = output { return true }
            return false
        }, "resume must not instantly complete the drive at the stale deadline")
    }

    /// Legacy checkpoints from the wedged-pause bug carry phase `.paused` with
    /// a past `stopDueAt`; settling the expired pause must scrub the deadline.
    func testFinalizeIfDueSettlingExpiredPauseClearsStaleStopDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        var state = reducer.state
        state.phase = .paused
        state.pausedUntil = start.addingTimeInterval(600)
        state.stopDueAt = start.addingTimeInterval(300)
        reducer.replaceState(state)

        let outputs = reducer.finalizeIfDue(now: start.addingTimeInterval(700))

        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertNil(reducer.state.pausedUntil)
        XCTAssertNil(reducer.state.stopDueAt)
        XCTAssertFalse(outputs.contains { output in
            if case .tripCompleted = output { return true }
            return false
        })
    }

    /// An expired pause must settle in `finalizeIfDue` — GPS is off while
    /// paused, so the location-sample resume path can never run, and an
    /// unsettled pause pins the capture policy at the unwakeable paused level.
    func testFinalizeIfDueClearsExpiredPause() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let until = start.addingTimeInterval(600)
        _ = reducer.apply(.trackingPaused(until: until))
        XCTAssertEqual(reducer.state.phase, .paused)

        _ = reducer.finalizeIfDue(now: start.addingTimeInterval(300))
        XCTAssertEqual(reducer.state.phase, .paused, "active pause must survive finalize")
        XCTAssertEqual(reducer.state.pausedUntil, until)

        _ = reducer.finalizeIfDue(now: until.addingTimeInterval(1))
        XCTAssertNil(reducer.state.pausedUntil)
        XCTAssertEqual(reducer.state.phase, .idle)
    }

    func testPendingCurrentDriveFieldsSurviveEncodingAndCopyToCompletionDraft() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = reducer.setCurrentDriveClassification(.business)
        _ = reducer.setCurrentDriveBusinessPurpose("Site visit")
        _ = reducer.setCurrentDriveNote("Met client at loading dock")
        let fee = TripFee(
            tripID: nil,
            category: .parking,
            amount: 12,
            occurredAt: start.addingTimeInterval(30),
            label: "Garage"
        )
        _ = reducer.appendCurrentDriveFee(fee)

        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureState.self,
            from: JSONEncoder.iso8601.encode(reducer.state)
        )

        XCTAssertEqual(restored.pendingClassification, .business)
        XCTAssertEqual(restored.pendingBusinessPurpose, "Site visit")
        XCTAssertEqual(restored.pendingNote, "Met client at loading dock")
        XCTAssertEqual(restored.pendingFees, [fee])

        let outputs = reducer.completeCurrentRecording(at: start.addingTimeInterval(120))
        let draft = try XCTUnwrap(outputs.completedDraft)
        XCTAssertEqual(draft.classification, .business)
        XCTAssertEqual(draft.businessPurpose, "Site visit")
        XCTAssertEqual(draft.notes, "Met client at loading dock")
        XCTAssertEqual(draft.fees, [fee])

        _ = reducer.apply(.completionSaved(draft.id))
        XCTAssertTrue(reducer.state.pendingFees.isEmpty)
        XCTAssertNil(reducer.state.pendingClassification)
        XCTAssertNil(reducer.state.pendingBusinessPurpose)
        XCTAssertNil(reducer.state.pendingNote)
    }

    func testBackgroundWakeAfterStopDeadlineFinalizesAtInferredEndDate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let stationary = sample(at: start.addingTimeInterval(120), metersNorth: 2_000, speed: 0, hint: .stationary)
        _ = reducer.apply(.location(
            stationary,
            receivedAt: stationary.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let stopDueAt = try XCTUnwrap(reducer.state.stopDueAt)

        let outputs = reducer.apply(.sceneBecameActive(stopDueAt.addingTimeInterval(900)))
            + reducer.finalizeIfDue(now: stopDueAt.addingTimeInterval(900))

        XCTAssertEqual(outputs.completedDraft?.endDate, stopDueAt)
    }

    func testNextDriveAfterParkedGapClosesOldDriveThenStartsCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let stationary = sample(at: start.addingTimeInterval(120), metersNorth: 2_000, speed: 0, hint: .stationary)
        _ = reducer.apply(.location(
            stationary,
            receivedAt: stationary.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let stopDueAt = try XCTUnwrap(reducer.state.stopDueAt)
        let nextDrive = sample(at: stopDueAt.addingTimeInterval(600), metersNorth: 3_000, speed: 12, hint: .automotive)

        let outputs = reducer.apply(.location(
            nextDrive,
            receivedAt: nextDrive.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertNotNil(outputs.completedDraft)
        XCTAssertTrue(outputs.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertNotNil(reducer.state.pendingCompletionDraft)
    }

    func testStaleWakeSeedsParkedAnchorButCannotStartDrive() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let staleParked = sample(at: start, metersNorth: 0, speed: 0, hint: .stationary)

        let outputs = reducer.apply(.location(
            staleParked,
            receivedAt: start.addingTimeInterval(500),
            context: TripDetectionContext(),
            options: .staleWake
        ))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNotNil(reducer.state.parkedStartAnchor)
        XCTAssertFalse(outputs.containsCandidateStarted)
    }

    func testSignalCandidateStateSurvivesEncoding() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()

        _ = reducer.apply(.startSignal(
            DriveStartSignal(source: .motionAutomotive, confidence: .assist, startedAt: start, expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)),
            receivedAt: start
        ))

        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureState.self,
            from: JSONEncoder.iso8601.encode(reducer.state)
        )

        XCTAssertEqual(restored.phase, .candidate)
        XCTAssertEqual(restored.candidateSamples.count, 0)
        XCTAssertEqual(restored.startSignal?.source, .motionAutomotive)
        XCTAssertEqual(restored.startSignal?.confidence, .assist)
    }

    func testMediumAutomotiveMotionStartsSignalCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let motion = MotionActivitySnapshot(startDate: start, confidence: .medium, hints: [.automotive])

        let outputs = reducer.apply(.motionActivity(motion, receivedAt: start))

        XCTAssertTrue(outputs.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateSamples.count, 0)
        XCTAssertEqual(reducer.state.startSignal?.source, .motionAutomotive)
        XCTAssertEqual(reducer.state.startSignal?.confidence, .assist)
    }

    func testLowAutomotiveMotionDoesNotStartSignalCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let motion = MotionActivitySnapshot(startDate: start, confidence: .low, hints: [.automotive])

        let outputs = reducer.apply(.motionActivity(motion, receivedAt: start))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertFalse(outputs.containsCandidateStarted)
        XCTAssertNil(reducer.state.startSignal)
    }

    func testTrustedSignalCandidateStartsRecordingAfterAcceptedAutomotiveLocations() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        let first = sample(at: start.addingTimeInterval(5), metersNorth: 120, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(30), metersNorth: 500, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(), options: .normal))
        let outputs = reducer.apply(.location(second, receivedAt: second.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertNil(reducer.state.startSignal)
        XCTAssertGreaterThanOrEqual(reducer.state.samples.count, 2)
    }

    func testNoAssistAutomotiveMotionDefersToDiagnosticsInsteadOfStartingTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartSignal(source: .motionAutomotive, confidence: .assist, startedAt: start, expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)),
            receivedAt: start
        ))

        // Automotive classification without GPS-reported speed: derived speed
        // alone must not satisfy the no-trust confirmation fallback. Since
        // 2026-07-07 the candidate keeps collecting (killing it mid-drive was
        // the 12 mini churn) — but it must still never confirm a visible trip,
        // resolving only through its expiry into diagnostics.
        let samples = [
            sample(at: start.addingTimeInterval(5), metersNorth: 120, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(12), metersNorth: 240, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(20), metersNorth: 360, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(30), metersNorth: 500, speed: nil, hint: .automotive)
        ]
        var outputs: [DriveCaptureOutput] = []
        for sample in samples {
            outputs += reducer.apply(.location(sample, receivedAt: sample.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertFalse(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .candidate, "promising evidence keeps collecting instead of dying mid-drive")

        // Ride out the signal window without ever gaining reported speed.
        let expiry = start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow + 5)
        let expiredOutputs = reducer.apply(.location(
            sample(at: expiry, metersNorth: 900, speed: nil, hint: .automotive),
            receivedAt: expiry, context: TripDetectionContext(), options: .normal
        ))

        XCTAssertFalse(expiredOutputs.containsTripStarted)
        XCTAssertNil(expiredOutputs.completedDraft)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertTrue(expiredOutputs.containsIgnored(containing: "Unconfirmed candidate timed out"))
    }

    func testSustainedNoAssistAutomotiveMotionConfirmsTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartSignal(source: .motionAutomotive, confidence: .assist, startedAt: start, expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)),
            receivedAt: start
        ))

        // Automotive classification + GPS-reported speed + sustained
        // displacement: confirms visibly without any trusted vehicle evidence.
        let samples = [
            sample(at: start.addingTimeInterval(5), metersNorth: 120, speed: 12, hint: .automotive),
            sample(at: start.addingTimeInterval(12), metersNorth: 240, speed: 12, hint: .automotive),
            sample(at: start.addingTimeInterval(20), metersNorth: 360, speed: 12, hint: .automotive),
            sample(at: start.addingTimeInterval(30), metersNorth: 500, speed: 12, hint: .automotive),
            sample(at: start.addingTimeInterval(50), metersNorth: 740, speed: 12, hint: .automotive)
        ]
        var outputs: [DriveCaptureOutput] = []
        for sample in samples {
            outputs += reducer.apply(.location(sample, receivedAt: sample.timestamp, context: TripDetectionContext(), options: .normal))
        }

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    func testNoAssistCyclingMovementDefersToDiagnosticsInsteadOfStartingTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(
            sample(at: start, metersNorth: 0, speed: 12, hint: .unknown),
            receivedAt: start,
            context: TripDetectionContext(),
            options: .normal
        ))
        // Candidate resilience tolerates two contradictions before the kill.
        var outputs: [DriveCaptureOutput] = []
        for offset in [10.0, 14, 18] {
            let cycling = sample(at: start.addingTimeInterval(offset), metersNorth: 150 + offset * 10, speed: 12, hint: .cycling)
            outputs += reducer.apply(.location(
                cycling,
                receivedAt: cycling.timestamp,
                context: TripDetectionContext(),
                options: .normal
            ))
        }

        XCTAssertFalse(outputs.containsTripStarted)
        XCTAssertNil(outputs.completedDraft)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertTrue(outputs.containsIgnored(containing: "No driving signal"))
    }

    func testPowerOnlyMovementDoesNotConfirmVisibleTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .usbPower, at: start))

        let first = sample(at: start.addingTimeInterval(5), metersNorth: 120, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(12), metersNorth: 260, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(powerConnected: true), options: .normal))
        let outputs = reducer.apply(.location(second, receivedAt: second.timestamp, context: TripDetectionContext(powerConnected: true), options: .normal))

        XCTAssertFalse(outputs.containsTripStarted)
        XCTAssertNil(outputs.completedDraft)
        // Power assist must never confirm a visible trip by itself. The
        // corroborated automotive motion (CoreMotion hint + reported speed +
        // displacement) keeps the candidate collecting toward the sustained
        // no-trust fallback, but 12 seconds of movement confirms nothing.
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    func testTrustedVehicleEvidenceAllowsPedestrianSpeedOverride() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        let first = sample(at: start.addingTimeInterval(5), metersNorth: 120, speed: 12, hint: .automotive)
        let walkingFast = sample(at: start.addingTimeInterval(30), metersNorth: 520, speed: 12, hint: .walking)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(), options: .normal))
        let outputs = reducer.apply(.location(walkingFast, receivedAt: walkingFast.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    func testShortTripRescueRequiresTrustedVehicleEvidence() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let first = sample(at: start, metersNorth: 0, speed: 12, hint: .unknown)
        let second = sample(at: start.addingTimeInterval(10), metersNorth: 260, speed: 12, hint: .unknown)

        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(), options: .normal))
        _ = reducer.apply(.location(second, receivedAt: second.timestamp, context: TripDetectionContext(), options: .normal))
        // Three stationary samples exhaust candidate resilience; none of them
        // may rescue a short trip without trusted vehicle evidence.
        var outputs: [DriveCaptureOutput] = []
        for offset in [20.0, 24, 28] {
            let stationary = sample(at: start.addingTimeInterval(offset), metersNorth: 520, speed: 0, hint: .stationary)
            outputs += reducer.apply(.location(stationary, receivedAt: stationary.timestamp, context: TripDetectionContext(), options: .normal))
        }

        XCTAssertNil(outputs.completedDraft)
        XCTAssertFalse(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertTrue(outputs.containsIgnored(containing: "No driving signal"))
    }

    func testShortTripRescueClearsStaleParkedAnchorAndReanchorsAtEnd() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // A candidate short drive of ~300 m over 20 s that never confirmed to recording.
        var state = DriveCaptureState()
        state.phase = .candidate
        state.candidateStartedAt = start
        state.candidateHadBluetoothHint = true           // trusted vehicle evidence
        state.pendingTripID = UUID()
        state.startSignal = DriveStartSignal(
            source: .trustedBluetooth,
            confidence: .strong,
            startedAt: start,
            expiresAt: start.addingTimeInterval(3_600)
        )
        let candidateSamples = [
            sample(at: start, metersNorth: 0, speed: 8, hint: .automotive),
            sample(at: start.addingTimeInterval(20), metersNorth: 300, speed: 8, hint: .automotive)
        ]
        state.candidateSamples = candidateSamples
        state.lastAcceptedSample = candidateSamples.last
        // The pre-trip parked anchor points at the ORIGINAL parking spot (500 m south).
        let preTripAnchor = sample(at: start.addingTimeInterval(-600), metersNorth: -500, speed: 0, hint: .stationary)
        state.parkedStartAnchor = preTripAnchor
        state.vehicleParkingAnchor = preTripAnchor
        var reducer = DriveCaptureReducer(state: state)

        // A stationary sample at the NEW parked spot contradicts the candidate and
        // rescues the short trip.
        let parkedAtEnd = sample(at: start.addingTimeInterval(24), metersNorth: 300, speed: 0, hint: .stationary)
        let outputs = reducer.apply(.location(
            parkedAtEnd,
            receivedAt: parkedAtEnd.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        // The short trip is rescued...
        XCTAssertNotNil(outputs.completedDraft)
        // ...and the stale pre-trip anchor must not survive into the next drive. The
        // accurate stationary end sample re-anchors to the new parked spot, mirroring
        // completeRecording rather than leaving the origin at the pre-trip location.
        XCTAssertNotEqual(reducer.state.parkedStartAnchor, preTripAnchor)
        XCTAssertEqual(reducer.state.parkedStartAnchor, parkedAtEnd)
        XCTAssertEqual(reducer.state.vehicleParkingAnchor, parkedAtEnd)
    }

    func testSignalCandidateContradictedByWalkingMotionResetsWithoutSaving() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartSignal(source: .motionAutomotive, confidence: .assist, startedAt: start, expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)),
            receivedAt: start
        ))

        let walking = MotionActivitySnapshot(startDate: start.addingTimeInterval(5), confidence: .high, hints: [.walking])
        let outputs = reducer.apply(.motionActivity(walking, receivedAt: walking.startDate))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.startSignal)
        XCTAssertNil(outputs.completedDraft)
        XCTAssertTrue(outputs.containsIgnored(containing: "No driving signal"))
    }

    func testSignalCandidateTimesOutWithoutLocation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartSignal(
                source: .weakBluetoothName,
                confidence: .weak,
                startedAt: start,
                expiresAt: start.addingTimeInterval(10)
            ),
            receivedAt: start
        ))

        let outputs = reducer.apply(.stopTimerFired(start.addingTimeInterval(11)))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.startSignal)
        XCTAssertNil(outputs.completedDraft)
        XCTAssertTrue(outputs.containsIgnored(containing: "Unconfirmed candidate timed out"))
    }

    func testExternalAutomationSignalStartsCandidateButDoesNotSaveWithoutLocation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))

        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.startSignal?.source, .externalVehicleAutomation)
        XCTAssertEqual(reducer.state.startSignal?.confidence, .strong)
        XCTAssertTrue(reducer.state.candidateSamples.isEmpty)

        let outputs = reducer.apply(.stopTimerFired(start.addingTimeInterval(DriveStartPolicy.balanced.unconfirmedCandidateTimeout + 1)))
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(outputs.completedDraft)
        XCTAssertTrue(outputs.containsIgnored(containing: "Unconfirmed candidate timed out"))
    }

    func testCoarseLocationWakeArmsCandidateWithoutTrustingLocationProof() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()

        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .coarseLocationWake, startedAt: start),
            receivedAt: start
        ))

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.startSignal?.source, .coarseLocationWake)
        XCTAssertTrue(reducer.state.candidateSamples.isEmpty)
    }

    func testTrustedBluetoothAndUSBPowerStartCandidatesButWeakSeedDoesNotTrust() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var bluetooth = DriveCaptureReducer()
        _ = bluetooth.apply(.vehicleConnectionChanged(active: true, source: .bluetoothAudio, at: start))

        XCTAssertEqual(bluetooth.state.phase, .candidate)
        XCTAssertEqual(bluetooth.state.startSignal?.source, .trustedBluetooth)
        XCTAssertTrue(bluetooth.state.candidateHadBluetoothHint)

        var power = DriveCaptureReducer()
        _ = power.apply(.vehicleConnectionChanged(active: true, source: .usbPower, at: start))

        XCTAssertEqual(power.state.phase, .candidate)
        XCTAssertEqual(power.state.startSignal?.source, .usbPower)
        XCTAssertTrue(power.state.candidateHadPowerHint)

        var weak = DriveCaptureReducer()
        _ = weak.apply(.startSignal(
            DriveStartSignal(source: .weakBluetoothName, confidence: .weak, startedAt: start, expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)),
            receivedAt: start
        ))

        XCTAssertEqual(weak.state.phase, .candidate)
        XCTAssertEqual(weak.state.startSignal?.source, .weakBluetoothName)
        XCTAssertFalse(weak.state.candidateHadBluetoothHint)
    }

    func testTrustedBluetoothCanAssistLowSpeedStartButUntrustedCannot() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = sample(at: start, metersNorth: 0, speed: 1.6, hint: .unknown)
        let second = sample(at: start.addingTimeInterval(10), metersNorth: 100, speed: 1.6, hint: .unknown)

        var untrusted = DriveCaptureReducer()
        let untrustedOutputs = untrusted.apply(.location(
            first,
            receivedAt: first.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(untrusted.state.phase, .idle)
        XCTAssertFalse(untrustedOutputs.containsCandidateStarted)

        var trusted = DriveCaptureReducer()
        _ = trusted.apply(.location(
            first,
            receivedAt: first.timestamp,
            context: TripDetectionContext(trustedBluetoothVehicleHint: true),
            options: .normal
        ))
        let trustedOutputs = trusted.apply(.location(
            second,
            receivedAt: second.timestamp,
            context: TripDetectionContext(trustedBluetoothVehicleHint: true),
            options: .normal
        ))

        XCTAssertEqual(trusted.state.phase, .recording)
        XCTAssertTrue(trustedOutputs.containsTripStarted)
    }

    func testRecentPowerDisconnectDoesNotShortenStopTimeout() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var configuration = DriveCaptureConfiguration.automatic
        configuration.startPolicy.parkingEnd.trafficStopProtectionWindow = 0
        var reducer = DriveCaptureReducer(state: DriveCaptureState(configuration: configuration))
        startRecording(&reducer, start: start)
        let stationary = sample(at: start.addingTimeInterval(120), metersNorth: 2_000, speed: 0, hint: .stationary)

        _ = reducer.apply(.location(
            stationary,
            receivedAt: stationary.timestamp,
            context: TripDetectionContext(recentPowerDisconnected: true),
            options: .normal
        ))

        XCTAssertEqual(reducer.state.stopDueAt, start.addingTimeInterval(45 + DriveCaptureConfiguration.automatic.stopTimeout))
    }

    func testTrustedVehicleDisconnectFinalizesAtDisconnectAndExcludesWalking() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let disconnectAt = start.addingTimeInterval(250)

        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .bluetoothAudio, at: disconnectAt))
        let walking = sample(at: disconnectAt.addingTimeInterval(5), metersNorth: 1_050, speed: 1.6, hint: .walking)
        _ = reducer.apply(.location(
            walking,
            receivedAt: walking.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let stopDueAt = try XCTUnwrap(reducer.state.stopDueAt)
        let outputs = reducer.apply(.stopTimerFired(stopDueAt.addingTimeInterval(1)))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.endDate, disconnectAt)
        XCTAssertFalse(draft.samples.contains { $0.timestamp > disconnectAt })
        XCTAssertEqual(reducer.state.parkedStartAnchor?.timestamp, disconnectAt)
        XCTAssertEqual(reducer.state.vehicleParkingAnchor?.timestamp, disconnectAt)
    }

    func testUSBDisconnectRequiresStationaryOrWalkingConfirmation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let disconnectAt = start.addingTimeInterval(250)

        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .usbPower, at: disconnectAt))
        // Assist disconnect now arms a bounded backstop (stopTimeout) so the trip
        // can't linger forever; a settling stationary sample still completes earlier.
        XCTAssertEqual(reducer.state.stopDueAt, disconnectAt.addingTimeInterval(DriveCaptureConfiguration.automatic.stopTimeout))

        let stationary = sample(at: disconnectAt.addingTimeInterval(8), metersNorth: 1_010, speed: 0, hint: .stationary)
        let outputs = reducer.apply(.location(
            stationary,
            receivedAt: stationary.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.endDate, disconnectAt)
        XCTAssertFalse(draft.samples.contains { $0.timestamp > disconnectAt })
    }

    func testConfirmedPedestrianExitAfterTrafficStopEndsAtVehicleEndpoint() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let vehicleEndpoint = sample(at: start.addingTimeInterval(120), metersNorth: 2_200, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(
            vehicleEndpoint,
            receivedAt: vehicleEndpoint.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let firstWalking = sample(at: start.addingTimeInterval(135), metersNorth: 2_230, speed: 1.4, hint: .walking)
        let firstOutputs = reducer.apply(.location(
            firstWalking,
            receivedAt: firstWalking.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        XCTAssertNil(firstOutputs.completedDraft)

        let confirmedWalking = sample(at: start.addingTimeInterval(146), metersNorth: 2_260, speed: 1.4, hint: .walking)
        let outputs = reducer.apply(.location(
            confirmedWalking,
            receivedAt: confirmedWalking.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.endDate, vehicleEndpoint.timestamp)
        XCTAssertEqual(draft.samples.last?.timestamp, vehicleEndpoint.timestamp)
    }

    func testTrafficStopIgnoresDisconnectFlapsAndFalseWalkingTransition() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)

        let outputs = enterTrafficStopHold(&reducer, start: start)

        XCTAssertNil(outputs.completedDraft)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.parkingEvidence?.signal, .trafficStopHold)
        let lastMovingAt = try XCTUnwrap(reducer.state.lastMovingAt)
        XCTAssertEqual(
            reducer.state.stopDueAt,
            lastMovingAt.addingTimeInterval(DriveStartPolicy.balanced.parkingEnd.trafficStopHold)
        )
    }

    func testTrafficStopContinuationKeepsSameRecording() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = enterTrafficStopHold(&reducer, start: start)

        let resume = sample(at: start.addingTimeInterval(660), metersNorth: 2_800, speed: 12, hint: .automotive)
        let resumeOutputs = reducer.apply(.location(
            resume,
            receivedAt: resume.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        XCTAssertNil(resumeOutputs.completedDraft)
        XCTAssertNil(reducer.state.parkingEvidence)
        XCTAssertNil(reducer.state.stopDueAt)

        let next = sample(at: start.addingTimeInterval(665), metersNorth: 2_860, speed: 12, hint: .automotive)
        let nextOutputs = reducer.apply(.location(
            next,
            receivedAt: next.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertNil(nextOutputs.completedDraft)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.samples.last?.timestamp, next.timestamp)
    }

    func testTrafficStopHoldExpiresAndCompletesOnce() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = enterTrafficStopHold(&reducer, start: start)
        let stopDueAt = try XCTUnwrap(reducer.state.stopDueAt)

        let outputs = reducer.finalizeIfDue(now: stopDueAt.addingTimeInterval(1))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.endDate, stopDueAt)
        XCTAssertEqual(reducer.state.phase, .idle)
    }

    func testStationarySpeedSpikeDoesNotRefreshLastMovingAt() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let lastMovingAt = try XCTUnwrap(reducer.state.lastMovingAt)
        let speedSpike = sample(at: start.addingTimeInterval(120), metersNorth: 1_020, speed: 3.2, hint: .stationary)

        _ = reducer.apply(.location(
            speedSpike,
            receivedAt: speedSpike.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(reducer.state.lastMovingAt, lastMovingAt)
        XCTAssertEqual(reducer.state.stopDueAt, lastMovingAt.addingTimeInterval(DriveStartPolicy.balanced.parkingEnd.trafficStopHold))
    }

    /// 2026-06-18 regression: a recording that confirmed on connection/assist evidence
    /// but only ever captured a single parked fix (0.0 mi) must not be persisted as a
    /// visible stub trip. The completion is dropped, state returns cleanly to idle.
    func testEmptyRecordingCompletionIsNotPersistedAsStubTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState()
        state.phase = .recording
        state.startedAt = start
        state.pendingTripID = UUID()
        state.captureID = UUID()
        state.lastMovingAt = start
        state.stopDueAt = start.addingTimeInterval(1)
        state.samples = [sample(at: start, metersNorth: 0, speed: 0, hint: .stationary)]
        var reducer = DriveCaptureReducer(state: state)

        let outputs = reducer.finalizeIfDue(now: start.addingTimeInterval(2))

        XCTAssertNil(outputs.completedDraft, "a single-sample zero-distance recording must not complete a trip")
        XCTAssertNil(reducer.state.pendingCompletionDraft)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertTrue(outputs.containsIgnored(containing: "no usable route"))
    }

    /// Guard rail for the empty-completion drop: a real multi-sample drive with route
    /// distance still completes normally.
    func testRealRecordingStillCompletesAfterEmptyCompletionGuard() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)

        // Park: a stationary fix past the stop timeout closes the (1 000 m) drive.
        let stop = start.addingTimeInterval(45 + DriveCaptureConfiguration.automatic.stopTimeout + 5)
        let stationary = sample(at: stop, metersNorth: 1_000, speed: 0, hint: .stationary)
        let outputs = reducer.apply(.location(stationary, receivedAt: stationary.timestamp, context: TripDetectionContext(), options: .normal))

        let draft = try XCTUnwrap(outputs.completedDraft)
        XCTAssertGreaterThan(draft.distanceMeters, 0)
    }

    func testCompletionSavedClearsMatchingPendingTripIDAndPreservesParkedAnchor() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tripID = UUID()
        let anchor = sample(at: start.addingTimeInterval(300), metersNorth: 1_000, speed: 0, hint: .stationary)
        let draft = TripDraft(
            id: tripID,
            startDate: start,
            endDate: start.addingTimeInterval(60),
            samples: [
                sample(at: start, metersNorth: 0),
                sample(at: start.addingTimeInterval(60), metersNorth: 600)
            ],
            distanceMeters: 600
        )
        var state = DriveCaptureState()
        state.phase = .idle
        state.pendingTripID = tripID
        state.pendingCompletionDraft = draft
        state.parkedStartAnchor = anchor
        var reducer = DriveCaptureReducer(state: state)

        _ = reducer.apply(.completionSaved(tripID))

        XCTAssertNil(reducer.state.pendingCompletionDraft)
        XCTAssertNil(reducer.state.pendingTripID)
        XCTAssertEqual(reducer.state.parkedStartAnchor, anchor)
    }

    func testDiscardedCompletionClearsVehicleParkingAnchorButKeepsIdleWakeAnchor() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tripID = UUID()
        let anchor = sample(at: start.addingTimeInterval(300), metersNorth: 1_000, speed: 0, hint: .stationary)
        let draft = TripDraft(
            id: tripID,
            startDate: start,
            endDate: start.addingTimeInterval(60),
            samples: [
                sample(at: start, metersNorth: 0),
                sample(at: start.addingTimeInterval(60), metersNorth: 600)
            ],
            distanceMeters: 600
        )
        var state = DriveCaptureState()
        state.phase = .idle
        state.pendingTripID = tripID
        state.pendingCompletionDraft = draft
        state.parkedStartAnchor = anchor
        state.vehicleParkingAnchor = anchor
        var reducer = DriveCaptureReducer(state: state)

        _ = reducer.apply(.completionDiscarded(tripID))

        XCTAssertNil(reducer.state.pendingCompletionDraft)
        XCTAssertNil(reducer.state.pendingTripID)
        XCTAssertEqual(reducer.state.parkedStartAnchor, anchor)
        XCTAssertNil(reducer.state.vehicleParkingAnchor)
    }

    func testGenericParkedAnchorSuppressesImmediateSpeedOnlyRestartWithoutBackdating() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start, metersNorth: 0, speed: 0, hint: .stationary)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(parkedStartAnchor: anchor))
        let speedOnly = sample(
            at: start.addingTimeInterval(10),
            metersNorth: 5,
            speed: 8,
            hint: .unknown
        )

        let outputs = reducer.apply(.location(
            speedOnly,
            receivedAt: speedOnly.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertFalse(outputs.containsCandidateStarted)
        XCTAssertTrue(outputs.containsIgnored(containing: "No driving signal"))
        XCTAssertNil(reducer.state.vehicleParkingAnchor)
    }

    /// 2026-06-18 regression: at arrival the OS delivered two parked fixes ~1 ms
    /// apart that differed by 0.14–0.44 m (well inside their ~10 m accuracy). The
    /// implied speed (hundreds of m/s) tripped the `maxSegmentSpeed` cap and flagged
    /// the otherwise-clean drive `needsAttention` as "Impossible GPS jump". Sub-accuracy
    /// jitter must never be treated as a teleport.
    func testSubAccuracyJitterBurstIsNotFlaggedAsImpossibleJump() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)

        // Car has arrived and parked ~1 000 m north; a fix lands, then a duplicate
        // delivery 1 ms later sits 0.4 m away — noise, not motion.
        let parked = sample(at: start.addingTimeInterval(51), metersNorth: 1_000.4, speed: 0, hint: .stationary, horizontalAccuracy: 10)
        _ = reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))

        let jitter = sample(at: start.addingTimeInterval(51.001), metersNorth: 1_000.0, speed: 0, hint: .stationary, horizontalAccuracy: 10)
        let outputs = reducer.apply(.location(jitter, receivedAt: jitter.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertFalse(reducer.state.attentionReasons.contains("Impossible GPS jump"))
        XCTAssertFalse(outputs.contains { output in
            if case .ignored(let reason) = output { return reason == "Impossible GPS jump" }
            return false
        })
        XCTAssertEqual(reducer.state.lastAcceptedSample?.timestamp, jitter.timestamp, "sub-accuracy fix should be accepted, not rejected as a jump")
    }

    /// A genuine teleport (a bad fix far beyond the combined accuracy, at impossible
    /// speed) must still be rejected so the displacement floor doesn't open a hole.
    func testRealTeleportStillFlaggedAsImpossibleJump() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)

        // 5 km away, 2 s later → 2 500 m/s, displacement far above combined accuracy.
        let teleport = sample(at: start.addingTimeInterval(47), metersNorth: 6_000, speed: 12, hint: .automotive, horizontalAccuracy: 10)
        let outputs = reducer.apply(.location(teleport, receivedAt: teleport.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.contains { output in
            if case .ignored(let reason) = output { return reason == "Impossible GPS jump" }
            return false
        })
        XCTAssertTrue(reducer.state.attentionReasons.contains("Impossible GPS jump"))
    }

    func testLowSpeedTrafficCrawlDoesNotTriggerMotionParkingHandoff() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let lastMovingAt = try XCTUnwrap(reducer.state.lastMovingAt)
        let crawl = sample(at: start.addingTimeInterval(70), metersNorth: 1_030, speed: 1.8, hint: .unknown)

        let outputs = reducer.apply(.location(
            crawl,
            receivedAt: crawl.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertNil(outputs.completedDraft)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.stopDueAt, lastMovingAt.addingTimeInterval(DriveStartPolicy.balanced.parkingEnd.trafficStopHold))
    }

    func testRentalCenterWalkAwayDoesNotCreatePostParkingTripFromJitter() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let (dropoff, draft) = try completeWithConfirmedWalkAway(&reducer, start: start)
        _ = reducer.apply(.completionSaved(draft.id))

        let jitter = sample(at: start.addingTimeInterval(900), metersNorth: 5_300, speed: 2.8, hint: .unknown)
        let jitterOutputs = reducer.apply(.location(
            jitter,
            receivedAt: jitter.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(draft.endDate, dropoff.timestamp)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertFalse(jitterOutputs.containsCandidateStarted)
    }

}

// MARK: - Candidate resilience (Part C)

extension DriveCaptureReducerTests {
    func testCandidateSurvivesBriefContradictionFlicker() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.phase, .candidate)

        // Two consecutive contradictions are tolerated as flicker.
        for offset in [4.0, 8] {
            let flicker = sample(at: start.addingTimeInterval(offset), metersNorth: 50, speed: 0, hint: .stationary)
            let outputs = reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))
            XCTAssertFalse(outputs.containsIgnored(containing: "No driving signal"), "offset \(offset)")
        }
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateContradictionCount, 2)

        // A vehicle sample resets the consecutive count.
        let moving = sample(at: start.addingTimeInterval(12), metersNorth: 150)
        _ = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.candidateContradictionCount, 0)
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    func testThirdConsecutiveContradictionKillsCandidateAndStashesSnapshot() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))

        var outputs: [DriveCaptureOutput] = []
        for offset in [4.0, 8, 12] {
            let flicker = sample(at: start.addingTimeInterval(offset), metersNorth: 50, speed: 0, hint: .stationary)
            outputs += reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))
        }

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertTrue(outputs.containsIgnored(containing: "No driving signal"))
        let snapshot = try XCTUnwrap(reducer.state.recentCandidate)
        XCTAssertEqual(snapshot.candidateStartedAt, start)
        XCTAssertEqual(snapshot.samples.count, 1)
        XCTAssertEqual(snapshot.killedAt, start.addingTimeInterval(12))
    }

    func testStaleEvidenceUsesReceiptTimeForCandidateKillAndCooldown() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(
            sample(at: start, metersNorth: 0),
            receivedAt: start,
            context: TripDetectionContext(),
            options: .normal
        ))
        let staleTimestamp = start.addingTimeInterval(-51)
        for receiptOffset in [1.0, 2, 3] {
            let stale = sample(at: staleTimestamp, metersNorth: 0, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(
                stale,
                receivedAt: start.addingTimeInterval(receiptOffset),
                context: TripDetectionContext(),
                options: .normal
            ))
        }

        let snapshot = try XCTUnwrap(reducer.state.recentCandidate)
        XCTAssertEqual(snapshot.candidateStartedAt, start)
        XCTAssertEqual(snapshot.killedAt, start.addingTimeInterval(3))
        XCTAssertGreaterThanOrEqual(snapshot.killedAt, try XCTUnwrap(snapshot.candidateStartedAt))
    }

    func testRevivalWithinWindowInheritsEvidence() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))
        _ = reducer.apply(.location(sample(at: start.addingTimeInterval(10), metersNorth: 120), receivedAt: start.addingTimeInterval(10), context: TripDetectionContext(), options: .normal))
        for offset in [14.0, 18, 22] {
            let flicker = sample(at: start.addingTimeInterval(offset), metersNorth: 150, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertEqual(reducer.state.phase, .idle)

        // Vehicle evidence 40 s after the kill revives the candidate with the
        // original start time and accumulated samples.
        let revival = sample(at: start.addingTimeInterval(62), metersNorth: 700)
        let outputs = reducer.apply(.location(revival, receivedAt: revival.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateStartedAt, start)
        XCTAssertEqual(reducer.state.candidateSamples.count, 3)
        XCTAssertNil(reducer.state.recentCandidate)
    }

    func testRevivalWindowExpiresAfterNinetySeconds() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))
        for offset in [4.0, 8, 12] {
            let flicker = sample(at: start.addingTimeInterval(offset), metersNorth: 30, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertNotNil(reducer.state.recentCandidate)

        // Kill happened at +12; +200 is far outside the 90 s revive window.
        let late = sample(at: start.addingTimeInterval(200), metersNorth: 900)
        _ = reducer.apply(.location(late, receivedAt: late.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateStartedAt, late.timestamp)
        XCTAssertEqual(reducer.state.candidateSamples.count, 1)
        XCTAssertNil(reducer.state.recentCandidate)
    }

    func testDuplicateSameSecondStartSignalDoesNotMintNewCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let signal = DriveStartSignal(
            source: .motionAutomotive,
            confidence: .assist,
            startedAt: start,
            expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)
        )
        var state = DriveCaptureState()
        state.phase = .idle
        state.recentCandidate = RecentCandidateSnapshot(
            candidateStartedAt: start,
            samples: [],
            startSignal: signal,
            hadBluetoothHint: false,
            hadPowerHint: false,
            contradictionCount: 1,
            lastContradiction: nil,
            killedAt: start
        )
        var reducer = DriveCaptureReducer(state: state)

        let outputs = reducer.apply(.startSignal(signal, receivedAt: start))

        XCTAssertFalse(outputs.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.pendingTripID)
        XCTAssertNotNil(reducer.state.recentCandidate)
    }

    func testDuplicateSameSecondAcceptedLocationDoesNotMintNewCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let signal = DriveStartSignal(
            source: .acceptedVehicleLocation,
            confidence: .assist,
            startedAt: start,
            expiresAt: start.addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)
        )
        let first = sample(at: start, metersNorth: 0)
        var state = DriveCaptureState()
        state.phase = .idle
        state.recentCandidate = RecentCandidateSnapshot(
            candidateStartedAt: start,
            samples: [first],
            startSignal: signal,
            hadBluetoothHint: false,
            hadPowerHint: false,
            contradictionCount: 1,
            lastContradiction: nil,
            killedAt: start
        )
        var reducer = DriveCaptureReducer(state: state)

        let outputs = reducer.apply(.location(first, receivedAt: start, context: TripDetectionContext(), options: .normal))

        XCTAssertFalse(outputs.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.pendingTripID)
        XCTAssertNotNil(reducer.state.recentCandidate)
    }

    func testFreshPedestrianContradictionBlocksFallbackConfirmationUntilHoldExpires() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))

        // One walking flicker at +5 arms the 60 s contradiction hold.
        let walking = sample(at: start.addingTimeInterval(5), metersNorth: 40, speed: 1.5, hint: .walking)
        _ = reducer.apply(.location(walking, receivedAt: walking.timestamp, context: TripDetectionContext(), options: .normal))

        var outputs: [DriveCaptureOutput] = []
        var tripStartedAt: Date?
        var offset = 10.0
        while offset <= 80 {
            let moving = sample(at: start.addingTimeInterval(offset), metersNorth: offset * 12)
            let stepOutputs = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: TripDetectionContext(), options: .normal))
            if stepOutputs.containsTripStarted, tripStartedAt == nil {
                tripStartedAt = moving.timestamp
            }
            outputs += stepOutputs
            offset += 5
        }

        // The hold (until +65) blocks the no-trust fallback even though the
        // strong-agreement evidence is otherwise complete well before that;
        // evidence survives the interim kills, so the start is not delayed.
        let confirmedAt = try XCTUnwrap(tripStartedAt)
        XCTAssertGreaterThan(confirmedAt, start.addingTimeInterval(65))
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startedAt, start)
    }

    func testSnapshotClearedOnTripStart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))
        for offset in [4.0, 8, 12] {
            let flicker = sample(at: start.addingTimeInterval(offset), metersNorth: 30, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertNotNil(reducer.state.recentCandidate)

        startRecording(&reducer, start: start.addingTimeInterval(30))

        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertNil(reducer.state.recentCandidate)
    }

    func testResilienceStateCodableRoundTrip() throws {
        var state = DriveCaptureState()
        state.candidateContradictionCount = 2
        state.lastCandidateContradiction = CandidateContradiction(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .pedestrian
        )
        state.recentCandidate = RecentCandidateSnapshot(
            candidateStartedAt: Date(timeIntervalSince1970: 1_800_000_000),
            samples: [sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0)],
            startSignal: DriveStartSignal(source: .motionAutomotive, confidence: .assist, startedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(DriveStartPolicy.balanced.signalHighFidelityWindow)),
            hadBluetoothHint: true,
            hadPowerHint: false,
            contradictionCount: 2,
            lastContradiction: CandidateContradiction(at: Date(timeIntervalSince1970: 1_800_000_010), kind: .stationary),
            killedAt: Date(timeIntervalSince1970: 1_800_000_020)
        )

        let data = try JSONEncoder.iso8601.encode(state)
        let decoded = try JSONDecoder.iso8601.decode(DriveCaptureState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    func testStartPolicyDecodesCheckpointsWithoutResilienceKey() throws {
        let data = try JSONEncoder.iso8601.encode(DriveStartPolicy.balanced)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "candidateResilience")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso8601.decode(DriveStartPolicy.self, from: legacyData)

        XCTAssertEqual(decoded.candidateResilience.maximumConsecutiveContradictions, 3)
        XCTAssertEqual(decoded.candidateResilience.contradictionHoldSeconds, 60)
        XCTAssertEqual(decoded.candidateResilience.reviveWindow, 90)
    }

    // MARK: - Parked-anchor-exit cooldown (2026-07-05 walk-away churn regression)

    /// 2026-07-05 regression: geofence exit armed a candidate, a walking motion
    /// snapshot killed it within a second, and the still-outside-the-anchor
    /// exit re-armed it instantly — ~20 arm/kill cycles per minute for the
    /// whole walk to the car. After a pedestrian kill of a never-moved
    /// candidate, `.parkedAnchorExit` alone must not re-arm until the cooldown
    /// lapses.
    func testJuly5WalkToCarAnchorExitChurnIsSuppressed() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let arm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: start),
            receivedAt: start
        ))
        XCTAssertTrue(arm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)

        // Walking motion one second later kills the sampleless candidate.
        let killOutputs = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(1)
        ))
        XCTAssertTrue(killOutputs.containsIgnored(containing: "No driving signal"))
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.recentCandidate?.firstMovementAt)

        // The immediate anchor-exit re-fire is suppressed for the cooldown.
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: start.addingTimeInterval(2)),
            receivedAt: start.addingTimeInterval(2)
        ))
        XCTAssertFalse(rearm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNotNil(reducer.state.recentCandidate, "the stash must survive suppression for later revival")
    }

    func testAnchorExitArmsAgainAfterCooldownExpires() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: start),
            receivedAt: start
        ))
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(reducer.state.phase, .idle)
        let cooldown = DriveStartPolicy.balanced.candidateResilience.postKillParkedExitCooldownSeconds

        let rearmAt = start.addingTimeInterval(1 + cooldown + 1)
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: rearmAt),
            receivedAt: rearmAt
        ))

        XCTAssertTrue(rearm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    func testMotionAutomotiveArmsDuringAnchorExitCooldownAndInheritsStash() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: start),
            receivedAt: start
        ))
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(reducer.state.phase, .idle)

        // The user reached the car: automotive motion is NOT gated by the
        // cooldown and revives the stashed evidence.
        let driveAt = start.addingTimeInterval(30)
        let arm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .motionAutomotive, startedAt: driveAt),
            receivedAt: driveAt
        ))

        XCTAssertTrue(arm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateStartedAt, start, "revival inherits the original start")
        XCTAssertNil(reducer.state.recentCandidate)
    }

    func testAnchorExitCooldownDoesNotApplyAfterMovedCandidateKill() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        // Arm via a genuine vehicle sample, add movement, then kill with three
        // stationary contradictions — a moved candidate keeps the June-9
        // revive-through-anchor-exit path.
        _ = reducer.apply(.location(sample(at: start, metersNorth: 0), receivedAt: start, context: TripDetectionContext(), options: .normal))
        _ = reducer.apply(.location(sample(at: start.addingTimeInterval(5), metersNorth: 80), receivedAt: start.addingTimeInterval(5), context: TripDetectionContext(), options: .normal))
        for offset in [9.0, 13, 17] {
            let flicker = sample(at: start.addingTimeInterval(offset), metersNorth: 90, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNotNil(reducer.state.recentCandidate?.firstMovementAt)

        let rearmAt = start.addingTimeInterval(25)
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: rearmAt),
            receivedAt: rearmAt
        ))

        XCTAssertTrue(rearm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    /// 2026-07-06 regression (stationary-at-home SLC churn): iOS relaunched the
    /// app every 2-8 minutes for SLC events while the phone never moved; each
    /// wake armed a candidate + full-accuracy service session that died within
    /// a second, keeping the location indicator lit all day. After a
    /// never-moved stationary/pedestrian kill, passive location wakes (SLC,
    /// visit departure, coarse wake) must be gated by the same post-kill
    /// cooldown as the anchor exit.
    func testJuly6SlcSignalDuringPostKillCooldownIsSuppressedByBackstop() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .significantLocationChange, startedAt: start),
            receivedAt: start
        ))
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(reducer.state.recentCandidate?.firstMovementAt)

        let rearmAt = start.addingTimeInterval(30)
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .significantLocationChange, startedAt: rearmAt),
            receivedAt: rearmAt
        ))

        XCTAssertFalse(rearm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNotNil(reducer.state.recentCandidate, "the stash must survive suppression for later revival")
    }

    func testVisitDepartureAndCoarseWakeSignalsDuringPostKillCooldownAreSuppressed() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for source in [DriveStartSignalSource.visitDeparture, .coarseLocationWake] {
            var reducer = DriveCaptureReducer()
            _ = reducer.apply(.startSignal(
                DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: start),
                receivedAt: start
            ))
            _ = reducer.apply(.motionActivity(
                MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]),
                receivedAt: start.addingTimeInterval(1)
            ))
            XCTAssertEqual(reducer.state.phase, .idle)

            let rearmAt = start.addingTimeInterval(30)
            let rearm = reducer.apply(.startSignal(
                DriveStartEngine.signal(source: source, startedAt: rearmAt),
                receivedAt: rearmAt
            ))

            XCTAssertFalse(rearm.containsCandidateStarted, "\(source) must be gated during the cooldown")
            XCTAssertEqual(reducer.state.phase, .idle)
        }
    }

    func testSlcSignalArmsAgainAfterPostKillCooldownExpires() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .significantLocationChange, startedAt: start),
            receivedAt: start
        ))
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(reducer.state.phase, .idle)
        let cooldown = DriveStartPolicy.balanced.candidateResilience.postKillParkedExitCooldownSeconds

        let rearmAt = start.addingTimeInterval(1 + cooldown + 1)
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .significantLocationChange, startedAt: rearmAt),
            receivedAt: rearmAt
        ))

        XCTAssertTrue(rearm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    /// 2026-07-07 regression (17 Pro ignition kill): trusted Bluetooth +
    /// Shortcut automation armed a strong candidate the moment the car turned
    /// on, but CoreMotion kept reporting high-confidence walking while the
    /// driver settled in and a cold-GPS burst delivered three
    /// pedestrian-classified samples inside one second — spending the whole
    /// contradiction budget and killing the candidate 4 s after ignition. The
    /// app then slept through the first three minutes of the drive. Walking
    /// must be graced like stationary while the vehicle's Bluetooth link is
    /// live: you cannot be walking away from a running car you are connected to.
    func testJuly7WalkingBurstIsGracedWhileVehicleBluetoothLive() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        let carContext = TripDetectionContext(trustedBluetoothVehicleHint: true)
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .trustedBluetooth, startedAt: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        for offset in [1.0, 1.3, 1.6, 4.0] {
            let settlingIn = sample(at: start.addingTimeInterval(offset), metersNorth: 5, speed: 1.4, hint: .walking)
            _ = reducer.apply(.location(settlingIn, receivedAt: settlingIn.timestamp, context: carContext, options: .normal))
        }
        XCTAssertEqual(
            reducer.state.phase, .candidate,
            "a walking burst with the car's Bluetooth live is the driver settling in, not a departure"
        )

        var tripStarted = false
        var offset = 40.0
        while offset <= 120 {
            let moving = sample(at: start.addingTimeInterval(offset), metersNorth: (offset - 40) * 12)
            let outputs = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: carContext, options: .normal))
            tripStarted = tripStarted || outputs.containsTripStarted
            offset += 5
        }
        XCTAssertTrue(tripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    /// 2026-07-07 afternoon regression (17 Pro ignition jitter kill): the
    /// Shortcut armed a strong candidate and GPS cold-started with a burst of
    /// fixes inside one second, 0 m apart. Dividing jitter by hundredths of a
    /// second manufactured a vehicle-grade derived speed, which set
    /// `candidateFirstMovementAt` — disqualifying every pre-movement grace —
    /// so the walking burst one second later killed the candidate and the app
    /// slept through the first five minutes of the drive. Sub-second sample
    /// pairs must not derive speed or mark first movement.
    func testJuly7ColdStartJitterBurstDoesNotMarkFirstMovementOrKillCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        let carContext = TripDetectionContext(trustedBluetoothVehicleHint: true)
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        // Cold-start burst: several fixes inside one second, centimeters
        // apart, no reported speed — followed by the walking misread.
        for (index, offset) in [0.1, 0.2, 0.35, 0.5, 0.7].enumerated() {
            let jitter = sample(at: start.addingTimeInterval(offset), metersNorth: Double(index) * 0.3, speed: nil, hint: .unknown)
            _ = reducer.apply(.location(jitter, receivedAt: jitter.timestamp, context: carContext, options: .normal))
        }
        XCTAssertNil(reducer.state.candidateFirstMovementAt, "jitter must not count as first movement")
        for offset in [1.0, 1.2, 1.5, 2.0] {
            let walking = sample(at: start.addingTimeInterval(offset), metersNorth: 1, speed: 1.4, hint: .walking)
            _ = reducer.apply(.location(walking, receivedAt: walking.timestamp, context: carContext, options: .normal))
        }

        XCTAssertEqual(reducer.state.phase, .candidate, "the ignition candidate must survive the jitter burst and walking misread")
    }

    /// Motion-path twin of the walking-burst grace: a single walking snapshot
    /// must not kill a sampleless trusted-Bluetooth candidate either.
    func testJuly7WalkingMotionSnapshotIsGracedForTrustedBluetoothCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .trustedBluetooth, startedAt: start),
            receivedAt: start
        ))
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(2), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(2)
        ))

        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    /// Power alone must not neutralize a pedestrian contradiction — a phone
    /// can stay on a charger while its owner walks away, so a usbPower-armed
    /// candidate still dies to a walking snapshot.
    func testWalkingMotionSnapshotStillKillsPowerArmedCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .usbPower, startedAt: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(2), confidence: .high, hints: [.walking]),
            receivedAt: start.addingTimeInterval(2)
        ))

        XCTAssertEqual(reducer.state.phase, .idle)
    }

    /// Cycling is never graced: riding off with the car's Bluetooth still in
    /// range is a real departure.
    func testCyclingMotionSnapshotStillKillsTrustedBluetoothCandidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .trustedBluetooth, startedAt: start),
            receivedAt: start
        ))

        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: start.addingTimeInterval(2), confidence: .high, hints: [.cycling]),
            receivedAt: start.addingTimeInterval(2)
        ))

        XCTAssertEqual(reducer.state.phase, .idle)
    }

    /// 2026-07-07 regression (12 mini churn): the first confirmation-policy
    /// evaluation landed 25 s after a mid-drive visit wake with automotive and
    /// reported-speed evidence but only ~68 m of displacement and a stationary
    /// hint still inside the contradiction hold — and killed the candidate
    /// with stationaryMotionConflict four times in six seconds, delaying the
    /// visible trip by three minutes. Ambiguous-but-promising evidence must
    /// keep collecting until displacement resolves it or the candidate expires.
    func testJuly7StationaryConflictBelowDisplacementKeepsCollectingAndConfirms() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .visitDeparture, startedAt: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        // A tolerated stationary flicker arms the 60 s contradiction hold that
        // ORs the stationary hint into the confirmation evidence.
        let flicker = sample(at: start.addingTimeInterval(1), metersNorth: 0, speed: 0, hint: .stationary)
        _ = reducer.apply(.location(flicker, receivedAt: flicker.timestamp, context: TripDetectionContext(), options: .normal))

        // Slow pull-away: displacement crosses the 75 m bar only after the
        // first policy evaluation at minimumStartDuration (25 s).
        var tripStarted = false
        var everKilled = false
        var offset = 2.0
        while offset <= 110 {
            let moving = sample(at: start.addingTimeInterval(offset), metersNorth: offset * 2.5, speed: 9)
            let outputs = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: TripDetectionContext(), options: .normal))
            tripStarted = tripStarted || outputs.containsTripStarted
            everKilled = everKilled || (reducer.state.phase == .idle)
            offset += 2
        }

        XCTAssertFalse(everKilled, "promising automotive+speed evidence must not be killed while displacement accrues")
        XCTAssertTrue(tripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    /// 2026-07-07: the post-kill cooldown's contract is "strong signals stay
    /// ungated" — that must include a strong signal the kill itself discarded.
    /// A dead candidate whose merged signal is still inside its own validity
    /// window must not silence the passive wake (anchor exit, SLC) that would
    /// catch the drive. The churn loops the cooldown exists for are armed by
    /// assist-grade wakes, so they stay suppressed.
    func testUnexpiredStrongSignalStashExemptsPostKillCooldown() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartSignal(source: .motionAutomotive, confidence: .strong, startedAt: start, expiresAt: start.addingTimeInterval(180)),
            receivedAt: start
        ))
        for offset in [2.0, 4, 6] {
            let parked = sample(at: start.addingTimeInterval(offset), metersNorth: 0, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertEqual(reducer.state.recentCandidate?.startSignal?.confidence, .strong)

        let rearmAt = start.addingTimeInterval(30)
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: rearmAt),
            receivedAt: rearmAt
        ))

        XCTAssertTrue(rearm.containsCandidateStarted, "an unexpired strong signal must exempt the passive wake from the cooldown")
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.startSignal?.confidence, .strong, "revival inherits the strong signal")
    }

    /// 2026-07-07 (17 Pro): the ignition kill discarded a trusted-Bluetooth
    /// signal with minutes of validity left, so the geofence-exit wake three
    /// minutes later — past the 90 s revive window — re-armed as weak. An
    /// unexpired strong signal outlives the revive window on its own terms:
    /// its expiresAt bounds the claim, not how quickly the next wake arrived.
    func testStrongSignalSurvivesKillBeyondReviveWindow() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartSignal(source: .motionAutomotive, confidence: .strong, startedAt: start, expiresAt: start.addingTimeInterval(180)),
            receivedAt: start
        ))
        for offset in [2.0, 4, 6] {
            let parked = sample(at: start.addingTimeInterval(offset), metersNorth: 0, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertEqual(reducer.state.phase, .idle)
        let signalExpiry = try XCTUnwrap(reducer.state.recentCandidate?.startSignal?.expiresAt)
        let reviveWindow = DriveStartPolicy.balanced.candidateResilience.reviveWindow

        // Past the revive window, still inside the strong signal's validity.
        let rearmAt = start.addingTimeInterval(reviveWindow + 30)
        XCTAssertLessThan(rearmAt, signalExpiry, "test setup: the rearm must land inside the signal window")
        let rearm = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: rearmAt),
            receivedAt: rearmAt
        ))

        XCTAssertTrue(rearm.containsCandidateStarted)
        XCTAssertEqual(reducer.state.startSignal?.confidence, .strong, "the salvaged strong signal upgrades the fresh arming")
        XCTAssertEqual(reducer.state.candidateStartedAt, rearmAt, "stale candidate evidence (elapsed clock) is not inherited")
    }

    func testCandidateResilienceDecodesLegacyPayloadWithCooldownDefault() throws {
        let legacy = """
        {"maximumConsecutiveContradictions": 3, "contradictionHoldSeconds": 60, "reviveWindow": 90}
        """
        let decoded = try JSONDecoder().decode(DriveStartPolicy.CandidateResilience.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.postKillParkedExitCooldownSeconds, 180)
        XCTAssertEqual(decoded.preMovementGraceSeconds, 300)
    }

    /// 2026-07-05 regression: a sampleless candidate that lived out its whole
    /// signal window logged "elapsed=0s", which read as instant death. `age`
    /// reports the wall clock since arming.
    func testSamplelessCandidateTimeoutReportsAge() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        let outputs = reducer.finalizeIfDue(now: start.addingTimeInterval(200))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertTrue(outputs.containsIgnored(containing: "samples=0"))
        XCTAssertTrue(outputs.containsIgnored(containing: "elapsed=0s"))
        XCTAssertTrue(outputs.containsIgnored(containing: "age=200s"))
    }

    /// June 9 replay: ~12 s flicker cadence while actually driving used to
    /// kill/restart the candidate ~15 times and miss the start by ~3 minutes.
    func testJune9ChurnPatternStartsTripWithinSixtySeconds() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()

        var tripStartedAt: Date?
        var kills = 0
        var step = 0
        var offset = 0.0
        while offset <= 90 {
            let isFlicker = step > 0 && step % 4 == 0
            let current = isFlicker
                ? sample(at: start.addingTimeInterval(offset), metersNorth: offset * 12, speed: 0, hint: .stationary)
                : sample(at: start.addingTimeInterval(offset), metersNorth: offset * 12)
            let outputs = reducer.apply(.location(current, receivedAt: current.timestamp, context: TripDetectionContext(), options: .normal))
            if outputs.containsIgnored(containing: "No driving signal") {
                kills += 1
            }
            if outputs.containsTripStarted, tripStartedAt == nil {
                tripStartedAt = current.timestamp
            }
            step += 1
            offset += 3
        }

        let confirmedAt = try XCTUnwrap(tripStartedAt, "trip never confirmed")
        XCTAssertLessThanOrEqual(confirmedAt.timeIntervalSince(start), 60)
        XCTAssertEqual(kills, 0)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startedAt, start)
    }

    // MARK: - Parked-start inference displacement bound

    func testDeferredParkedStartAnchorBackdatesFirstRecordingSample() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        var state = DriveCaptureState()
        state.phase = .recording
        state.startedAt = start
        state.lastMovingAt = start
        state.pendingTripID = UUID()
        state.vehicleParkingAnchor = anchor
        state.samples = []
        var reducer = DriveCaptureReducer(state: state)

        let first = sample(at: start, metersNorth: 1_000, speed: 12, hint: .automotive)
        let outputs = reducer.apply(.location(
            first,
            receivedAt: first.timestamp,
            context: TripDetectionContext(trustedBluetoothVehicleHint: true),
            options: .normal
        ))

        XCTAssertTrue(outputs.contains { output in
            if case .tripUpdated(let sampleCount) = output { return sampleCount == 2 }
            return false
        })
        XCTAssertNil(reducer.state.vehicleParkingAnchor)
        XCTAssertLessThan(try XCTUnwrap(reducer.state.startedAt), start)
        XCTAssertTrue(reducer.state.attentionReasons.contains(DriveCaptureReducer.inferredStartAttentionReason))
        XCTAssertEqual(try XCTUnwrap(reducer.state.samples.first).latitude, anchor.latitude, accuracy: 0.0001)
        XCTAssertEqual(reducer.state.samples.last, first)
    }

    func testParkedStartInferenceBackdatesWithinDisplacementBound() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState()
        // Parked 1 km south of where GPS first locks, two minutes earlier — a
        // normal delayed-lock drive that should backdate to the parked spot.
        state.vehicleParkingAnchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        var reducer = DriveCaptureReducer(state: state)
        let context = TripDetectionContext(trustedBluetoothVehicleHint: true)

        let first = sample(at: start, metersNorth: 1_000, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(45), metersNorth: 2_000, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: context, options: .normal))
        let outputs = reducer.apply(.location(second, receivedAt: second.timestamp, context: context, options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
        let startedAt = try XCTUnwrap(reducer.state.startedAt)
        XCTAssertLessThan(startedAt, start, "start should be backdated toward the parked anchor")
        XCTAssertTrue(reducer.state.attentionReasons.contains(DriveCaptureReducer.inferredStartAttentionReason))
        // The anchor (lat 40) is prepended as the origin sample.
        XCTAssertEqual(try XCTUnwrap(reducer.state.samples.first).latitude, 40, accuracy: 0.0001)
    }

    func testGenericIdleWakeAnchorCannotBackdateVehicleTripStart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState()
        // Replays the bicycle-arrival failure: a stopped phone location may arm
        // background wake monitoring, but it has no vehicle parking provenance.
        state.parkedStartAnchor = sample(
            at: start.addingTimeInterval(-4 * 60 * 60),
            metersNorth: -2_300,
            speed: 0,
            hint: .stationary
        )
        var reducer = DriveCaptureReducer(state: state)
        let context = TripDetectionContext(trustedBluetoothVehicleHint: true)
        let first = sample(at: start, metersNorth: 0, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(45), metersNorth: 1_000, speed: 12, hint: .automotive)

        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: context, options: .normal))
        let outputs = reducer.apply(.location(second, receivedAt: second.timestamp, context: context, options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.startedAt, start)
        XCTAssertEqual(try XCTUnwrap(reducer.state.samples.first).latitude, first.latitude, accuracy: 0.0001)
        XCTAssertFalse(reducer.state.attentionReasons.contains(DriveCaptureReducer.inferredStartAttentionReason))
        XCTAssertNil(reducer.state.parkedStartAnchor)
        XCTAssertNil(reducer.state.vehicleParkingAnchor)
    }

    func testGenericIdleWakeAnchorDoesNotOverwriteVehicleParkingAnchor() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let vehicleAnchor = sample(at: start, metersNorth: 0, speed: 0, hint: .stationary)
        let state = DriveCaptureState(vehicleParkingAnchor: vehicleAnchor)
        let idleBikeArrival = sample(
            at: start.addingTimeInterval(60),
            metersNorth: 500,
            speed: 0,
            hint: .cycling
        )
        var reducer = DriveCaptureReducer(state: state)

        _ = reducer.apply(.location(
            idleBikeArrival,
            receivedAt: idleBikeArrival.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(reducer.state.parkedStartAnchor, idleBikeArrival)
        XCTAssertEqual(reducer.state.vehicleParkingAnchor, vehicleAnchor)
    }

    /// A delayed wake can place the first GPS sample
    /// ~185 km from the parked anchor. The straight-line backdate teleported the
    /// origin because only `distance/age ≤ maxSegmentSpeed` gated it. The bound
    /// must reject the backdate and start at the resume point instead.
    func testParkedStartInferenceRejectsExcessiveDisplacementAndStartsAtResumePoint() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState()
        // 185 km away, 10 000 s earlier → 18.5 m/s, under the 60 m/s segment cap,
        // so it slips past the speed guard and must be caught by the displacement cap.
        state.vehicleParkingAnchor = sample(at: start.addingTimeInterval(-10_000), metersNorth: 0, speed: 0, hint: .stationary)
        var reducer = DriveCaptureReducer(state: state)
        let context = TripDetectionContext(trustedBluetoothVehicleHint: true)

        let first = sample(at: start, metersNorth: 185_000, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(45), metersNorth: 186_000, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: context, options: .normal))
        let outputs = reducer.apply(.location(second, receivedAt: second.timestamp, context: context, options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startedAt, start, "start should fall back to the resume point, not the anchor")
        XCTAssertTrue(reducer.state.attentionReasons.contains(DriveCaptureReducer.excessiveParkedDisplacementAttentionReason))
        XCTAssertFalse(reducer.state.attentionReasons.contains(DriveCaptureReducer.inferredStartAttentionReason))
        // No teleport origin prepended: first sample is the drive, not the far anchor.
        XCTAssertGreaterThan(try XCTUnwrap(reducer.state.samples.first).latitude, 41)
    }

    func testNewBackgroundWakeSourcesUseAssistConfidence() {
        XCTAssertEqual(DriveStartEngine.confidence(for: .significantLocationChange), .assist)
        XCTAssertEqual(DriveStartEngine.confidence(for: .visitDeparture), .assist)
    }

    func testParkedStartInferenceDecodesCheckpointsWithoutMaximumDisplacement() throws {
        let data = try JSONEncoder.iso8601.encode(DriveStartPolicy.balanced)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var inference = try XCTUnwrap(object["parkedStartInference"] as? [String: Any])
        inference.removeValue(forKey: "maximumDisplacementMeters")
        object["parkedStartInference"] = inference
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso8601.decode(DriveStartPolicy.self, from: legacyData)

        XCTAssertEqual(decoded.parkedStartInference.maximumDisplacementMeters, 5_000)
    }

    /// Regression (#1): a candidate that accumulated movement + trusted-vehicle
    /// evidence but went GPS-silent before the assisted start duration elapsed must
    /// be confirmed when the expiry timer fires, not discarded as "timed out".
    func testConfirmableCandidateAtExpiryStartsRecordingInsteadOfBeingDiscarded() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        // One qualifying sample arrives before the assisted start duration (10s)
        // elapses, so the normal flow keeps collecting; then GPS goes silent.
        let moving = sample(at: start.addingTimeInterval(5), metersNorth: 120, speed: 12, hint: .automotive)
        let pre = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertFalse(pre.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .candidate)

        let expiresAt = try XCTUnwrap(reducer.state.startSignal?.expiresAt)
        let outputs = reducer.apply(.stopTimerFired(expiresAt))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertNil(outputs.completedDraft)
        XCTAssertFalse(outputs.containsIgnored(containing: "Unconfirmed candidate timed out"))
    }

    /// Regression (#4): an assist (USB) disconnect with no follow-up sample must
    /// still finalize via the bounded backstop, not linger in .recording forever.
    func testAssistDisconnectWithoutFollowupFinalizesAtBackstop() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let disconnectAt = start.addingTimeInterval(250)

        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .usbPower, at: disconnectAt))
        let stopDueAt = try XCTUnwrap(reducer.state.stopDueAt)
        XCTAssertEqual(stopDueAt, disconnectAt.addingTimeInterval(DriveCaptureConfiguration.automatic.stopTimeout))

        let outputs = reducer.apply(.stopTimerFired(stopDueAt.addingTimeInterval(1)))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.endDate, disconnectAt)
        XCTAssertEqual(reducer.state.phase, .idle)
    }

    /// Regression (#10): a checkpoint persisted before a new numeric field existed
    /// must decode with the default applied, not throw and drop the whole state.
    func testDriveCaptureConfigurationDecodesCheckpointsMissingNumericField() throws {
        let data = try JSONEncoder.iso8601.encode(DriveCaptureConfiguration.automatic)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stopTimeout")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso8601.decode(DriveCaptureConfiguration.self, from: legacyData)

        XCTAssertEqual(decoded.stopTimeout, DriveCaptureConfiguration.automatic.stopTimeout)
        XCTAssertEqual(decoded.maxHorizontalAccuracyMeters, DriveCaptureConfiguration.automatic.maxHorizontalAccuracyMeters)
    }

    func testDriveStartPolicyDecodesParkingEndMissingTrafficStopFields() throws {
        let data = try JSONEncoder.iso8601.encode(DriveStartPolicy.balanced)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var parkingEnd = try XCTUnwrap(object["parkingEnd"] as? [String: Any])
        parkingEnd.removeValue(forKey: "trafficStopProtectionWindow")
        parkingEnd.removeValue(forKey: "trafficStopMinimumSpeedMetersPerSecond")
        parkingEnd.removeValue(forKey: "trafficStopHold")
        parkingEnd.removeValue(forKey: "pedestrianExitMinimumDistanceMeters")
        parkingEnd.removeValue(forKey: "pedestrianExitMinimumDuration")
        object["parkingEnd"] = parkingEnd
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso8601.decode(DriveStartPolicy.self, from: legacyData)

        XCTAssertEqual(decoded.parkingEnd.trafficStopProtectionWindow, 180)
        XCTAssertEqual(decoded.parkingEnd.trafficStopMinimumSpeedMetersPerSecond, 8.0)
        XCTAssertEqual(decoded.parkingEnd.trafficStopHold, 600)
        XCTAssertEqual(decoded.parkingEnd.pedestrianExitMinimumDistanceMeters, 25)
        XCTAssertEqual(decoded.parkingEnd.pedestrianExitMinimumDuration, 10)
    }

    // MARK: - Pre-movement patience (vehicle-trigger candidates)

    func testVehicleTriggerCandidateSurvivesProlongedParkedStationarySamples() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        // 24 stationary samples over 4 minutes - well past the old 3-strike
        // kill and the 90 s revive window, still inside the 5 min grace.
        var allOutputs: [DriveCaptureOutput] = []
        for offset in stride(from: 10.0, through: 240, by: 10) {
            let parked = sample(at: start.addingTimeInterval(offset), metersNorth: 0, speed: 0, hint: .stationary)
            allOutputs += reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))
        }

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateContradictionCount, 0)
        XCTAssertFalse(allOutputs.containsIgnored(containing: "No driving signal"))
    }

    func testVehicleTriggerCandidateConfirmsAfterDelayedMovement() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        for offset in stride(from: 10.0, through: 90, by: 10) {
            let parked = sample(at: start.addingTimeInterval(offset), metersNorth: 0, speed: 0, hint: .stationary)
            _ = reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))
        }
        XCTAssertEqual(reducer.state.phase, .candidate, "should still be patiently waiting")

        let movingFirst = sample(at: start.addingTimeInterval(100), metersNorth: 20, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(movingFirst, receivedAt: movingFirst.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.phase, .candidate, "10 s assisted window has not elapsed yet")

        let movingSecond = sample(at: start.addingTimeInterval(111), metersNorth: 150, speed: 12, hint: .automotive)
        let outputs = reducer.apply(.location(movingSecond, receivedAt: movingSecond.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    /// Guards the elapsed-clock fix directly: with the historic bug (elapsed
    /// measured from `candidateStartedAt`), a delayed first-movement sample
    /// would instantly satisfy the 10 s assisted duration and confirm on the
    /// spot. Elapsed must be measured from first movement instead.
    func testAssistedStartElapsedMeasuredFromFirstMovementNotTrigger() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        let firstMoving = sample(at: start.addingTimeInterval(90), metersNorth: 20, speed: 12, hint: .automotive)
        let firstOutputs = reducer.apply(.location(firstMoving, receivedAt: firstMoving.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertFalse(firstOutputs.containsTripStarted, "must not confirm instantly off a stale trigger-time elapsed clock")
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateFirstMovementAt, firstMoving.timestamp)

        let secondMoving = sample(at: start.addingTimeInterval(101), metersNorth: 150, speed: 12, hint: .automotive)
        let secondOutputs = reducer.apply(.location(secondMoving, receivedAt: secondMoving.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(secondOutputs.containsTripStarted, "confirms once 10 s of real movement has elapsed")
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    func testVehicleTriggerCandidateBackdatesFromTriggerAfterDelayedStart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        let parked = sample(at: start.addingTimeInterval(60), metersNorth: 0, speed: 0, hint: .stationary)
        _ = reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))

        let movingFirst = sample(at: start.addingTimeInterval(90), metersNorth: 20, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(movingFirst, receivedAt: movingFirst.timestamp, context: TripDetectionContext(), options: .normal))
        let movingSecond = sample(at: start.addingTimeInterval(101), metersNorth: 150, speed: 12, hint: .automotive)
        let outputs = reducer.apply(.location(movingSecond, receivedAt: movingSecond.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startedAt, start, "trip should backdate to the original trigger time, not first movement")
    }

    func testPedestrianMotionStillKillsVehicleTriggerCandidateDuringGrace() throws {
        // Power-armed only: a phone can stay on a charger while its owner
        // walks away, so walking kills. A candidate with a LIVE vehicle
        // Bluetooth link is graced instead — see
        // testJuly7WalkingBurstIsGracedWhileVehicleBluetoothLive.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .usbPower, startedAt: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)

        var outputs: [DriveCaptureOutput] = []
        for offset in [10.0, 14, 18] {
            let walking = sample(at: start.addingTimeInterval(offset), metersNorth: offset, speed: 1.4, hint: .walking)
            outputs += reducer.apply(.location(walking, receivedAt: walking.timestamp, context: TripDetectionContext(), options: .normal))
        }

        XCTAssertEqual(reducer.state.phase, .idle, "walking away from the charger must still kill the candidate even during pre-movement grace")
        XCTAssertTrue(outputs.containsIgnored(containing: "No driving signal"))
    }

    func testStationaryMotionSnapshotDoesNotKillVehicleTriggerCandidateDuringGrace() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertTrue(reducer.state.candidateSamples.isEmpty)

        let stationarySnapshot = MotionActivitySnapshot(startDate: start.addingTimeInterval(30), confidence: .high, hints: [.stationary])
        let outputs = reducer.apply(.motionActivity(stationarySnapshot, receivedAt: stationarySnapshot.startDate))

        XCTAssertEqual(reducer.state.phase, .candidate, "stationary-only motion snapshot must not kill a vehicle-triggered candidate during pre-movement grace")
        XCTAssertFalse(outputs.containsIgnored(containing: "No driving signal"))
        XCTAssertEqual(reducer.state.candidateContradictionCount, 0)
    }

    func testPreMovementGraceExpiresAndDiscardsWhenNoMovement() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        let signal = DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start)
        _ = reducer.apply(.startSignal(signal, receivedAt: start))
        XCTAssertEqual(signal.expiresAt, start.addingTimeInterval(300), "vehicle trigger window should extend to the pre-movement grace")

        let parked = sample(at: start.addingTimeInterval(60), metersNorth: 0, speed: 0, hint: .stationary)
        _ = reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.phase, .candidate, "still patiently waiting mid-grace")

        let outputs = reducer.apply(.stopTimerFired(signal.expiresAt.addingTimeInterval(1)))

        XCTAssertEqual(reducer.state.phase, .idle)
        XCTAssertNil(outputs.completedDraft)
        XCTAssertTrue(outputs.containsIgnored(containing: "Unconfirmed candidate timed out"))
    }

    func testLowSpeedMovementToleratedDuringVehicleTriggerGraceByDefault() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        var outputs: [DriveCaptureOutput] = []
        for offset in [10.0, 20, 30, 40] {
            let crawling = sample(at: start.addingTimeInterval(offset), metersNorth: offset / 10, speed: 1.5, hint: .unknown)
            outputs += reducer.apply(.location(crawling, receivedAt: crawling.timestamp, context: TripDetectionContext(), options: .normal))
        }

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertEqual(reducer.state.candidateContradictionCount, 0)
        XCTAssertFalse(outputs.containsIgnored(containing: "No driving signal"))
    }

    func testCandidateResilienceDecodesCheckpointsMissingPreMovementFields() throws {
        let data = try JSONEncoder.iso8601.encode(DriveStartPolicy.balanced)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var candidateResilience = try XCTUnwrap(object["candidateResilience"] as? [String: Any])
        candidateResilience.removeValue(forKey: "preMovementGraceSeconds")
        candidateResilience.removeValue(forKey: "preMovementToleratesLowSpeed")
        object["candidateResilience"] = candidateResilience
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso8601.decode(DriveStartPolicy.self, from: legacyData)

        XCTAssertEqual(decoded.candidateResilience.preMovementGraceSeconds, 300)
        XCTAssertEqual(decoded.candidateResilience.preMovementToleratesLowSpeed, true)
        XCTAssertEqual(decoded.candidateResilience.maximumConsecutiveContradictions, 3)
    }

    func testCandidateFirstMovementAtSurvivesEncoding() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))
        let moving = sample(at: start.addingTimeInterval(30), metersNorth: 20, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.candidateFirstMovementAt, moving.timestamp)

        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureState.self,
            from: JSONEncoder.iso8601.encode(reducer.state)
        )

        XCTAssertEqual(restored.candidateFirstMovementAt, moving.timestamp)
    }

    /// Companion to `testPowerOnlyMovementDoesNotConfirmVisibleTrip`: charger
    /// triggers now get the same parked patience as Bluetooth, but that
    /// patience must never leak into trusted-vehicle fast-path confirmation.
    func testChargerTriggeredCandidateGetsPatienceButNotInstantConfirmation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .usbPower, at: start))
        XCTAssertEqual(reducer.state.phase, .candidate)

        var outputs: [DriveCaptureOutput] = []
        for offset in [10.0, 20, 30, 40] {
            let parked = sample(at: start.addingTimeInterval(offset), metersNorth: 0, speed: 0, hint: .stationary)
            outputs += reducer.apply(.location(parked, receivedAt: parked.timestamp, context: TripDetectionContext(powerConnected: true), options: .normal))
        }
        XCTAssertEqual(reducer.state.phase, .candidate, "charger trigger should be patient through parked samples, like Bluetooth")
        XCTAssertFalse(outputs.containsIgnored(containing: "No driving signal"))

        // Unchanged guard, now reached after a patience period: power must
        // never confirm a visible trip by itself, even with corroborated
        // automotive+speed+displacement evidence past the assisted-duration gate.
        let first = sample(at: start.addingTimeInterval(50), metersNorth: 120, speed: 12, hint: .automotive)
        let second = sample(at: start.addingTimeInterval(62), metersNorth: 260, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: TripDetectionContext(powerConnected: true), options: .normal))
        let movedOutputs = reducer.apply(.location(second, receivedAt: second.timestamp, context: TripDetectionContext(powerConnected: true), options: .normal))

        XCTAssertFalse(movedOutputs.containsTripStarted, "power/charger patience must not become trusted-vehicle fast-path confirmation")
        XCTAssertNil(movedOutputs.completedDraft)
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    /// CoreMotion can report automotive+stationary simultaneously on an idling
    /// parked car (engine vibration reads as automotive before the device has
    /// displaced). That must not anchor `candidateFirstMovementAt`, or a later
    /// real drive would confirm instantly instead of after sustained movement.
    func testAutomotiveWhileStationaryDoesNotAnchorFirstMovement() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(forExternalTrigger: .vehicleBluetooth, at: start),
            receivedAt: start
        ))

        var idlingAutomotive = sample(at: start.addingTimeInterval(30), metersNorth: 0, speed: 0, hint: .automotive)
        idlingAutomotive.motionActivity = MotionActivitySnapshot(
            startDate: idlingAutomotive.timestamp,
            confidence: .high,
            hints: [.automotive, .stationary]
        )
        _ = reducer.apply(.location(idlingAutomotive, receivedAt: idlingAutomotive.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertEqual(reducer.state.phase, .candidate)
        XCTAssertNil(reducer.state.candidateFirstMovementAt, "a bare automotive label must not anchor first movement while the car hasn't actually displaced")

        let genuineMovement = sample(at: start.addingTimeInterval(100), metersNorth: 20, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(genuineMovement, receivedAt: genuineMovement.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.candidateFirstMovementAt, genuineMovement.timestamp)
        XCTAssertEqual(reducer.state.phase, .candidate, "must wait the assisted 10 s window from real movement, not confirm instantly")

        let sustained = sample(at: start.addingTimeInterval(111), metersNorth: 150, speed: 12, hint: .automotive)
        let outputs = reducer.apply(.location(sustained, receivedAt: sustained.timestamp, context: TripDetectionContext(), options: .normal))

        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.phase, .recording)
    }

    // MARK: - New leg (splitCurrentRecording)

    func testSplitCurrentRecordingCompletesLegAndContinuesRecording() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let cruise = sample(at: start.addingTimeInterval(120), metersNorth: 2_000, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(cruise, receivedAt: cruise.timestamp, context: TripDetectionContext(), options: .normal))
        let firstLegTripID = try XCTUnwrap(reducer.state.pendingTripID)

        let splitDate = start.addingTimeInterval(150)
        let outputs = reducer.splitCurrentRecording(at: splitDate)

        let draft = try XCTUnwrap(outputs.completedDraft)
        XCTAssertEqual(draft.id, firstLegTripID)
        XCTAssertEqual(draft.endDate, splitDate)
        XCTAssertTrue(outputs.containsTripStarted)
        XCTAssertEqual(reducer.state.pendingCompletionDraft?.id, draft.id)

        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startedAt, splitDate)
        XCTAssertEqual(reducer.state.samples.count, 1)
        let boundary = try XCTUnwrap(reducer.state.samples.first)
        let legEnd = try XCTUnwrap(draft.samples.last)
        XCTAssertEqual(boundary.latitude, legEnd.latitude, "New leg must start where the finished leg ended")
        XCTAssertEqual(boundary.longitude, legEnd.longitude)
        XCTAssertEqual(boundary.timestamp, splitDate)
        let newLegTripID = try XCTUnwrap(reducer.state.pendingTripID)
        XCTAssertNotEqual(newLegTripID, draft.id)
        XCTAssertNil(reducer.state.stopDueAt)
        XCTAssertNil(reducer.state.parkedStartAnchor)
    }

    func testSplitSnapshotsPendingReviewFieldsOntoFinishedLegOnly() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = reducer.setCurrentDriveClassification(.business)
        _ = reducer.setCurrentDriveBusinessPurpose("Client visit")
        _ = reducer.setCurrentDriveNote("Parked on Atlantic Ave")
        _ = reducer.appendCurrentDriveFee(TripFee(
            tripID: nil,
            category: .toll,
            amount: 6,
            occurredAt: start
        ))

        let outputs = reducer.splitCurrentRecording(at: start.addingTimeInterval(120))

        let draft = try XCTUnwrap(outputs.completedDraft)
        XCTAssertEqual(draft.classification, .business)
        XCTAssertEqual(draft.businessPurpose, "Client visit")
        XCTAssertEqual(draft.notes, "Parked on Atlantic Ave")
        XCTAssertEqual(draft.fees.count, 1)

        let newLeg = try XCTUnwrap(reducer.state.currentDriveSummary())
        XCTAssertNil(newLeg.classification, "New leg starts unclassified")
        XCTAssertNil(newLeg.businessPurpose)
        XCTAssertNil(newLeg.note)
        XCTAssertEqual(newLeg.feeCount, 0)
    }

    func testSplitIsNoOpUnlessRecording() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()

        XCTAssertTrue(reducer.splitCurrentRecording(at: start).isEmpty)
        XCTAssertEqual(reducer.state.phase, .idle)

        let candidate = sample(at: start, metersNorth: 0, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(candidate, receivedAt: candidate.timestamp, context: TripDetectionContext(), options: .normal))
        XCTAssertEqual(reducer.state.phase, .candidate)

        XCTAssertTrue(reducer.splitCurrentRecording(at: start.addingTimeInterval(5)).isEmpty)
        XCTAssertEqual(reducer.state.phase, .candidate)
    }

    func testImmediateSecondSplitIsIgnoredWithoutSheddingAStubLeg() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let splitDate = start.addingTimeInterval(120)
        _ = reducer.splitCurrentRecording(at: splitDate)

        let outputs = reducer.splitCurrentRecording(at: splitDate.addingTimeInterval(1))

        XCTAssertNil(outputs.completedDraft)
        XCTAssertTrue(outputs.containsIgnored(containing: "empty"))
        XCTAssertEqual(reducer.state.phase, .recording)
        XCTAssertEqual(reducer.state.startedAt, splitDate)
        XCTAssertEqual(reducer.state.samples.count, 1)
    }

    func testSplitThenStationaryTimeoutFinalizesSecondLegFromSplitDate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let splitDate = start.addingTimeInterval(120)
        let splitOutputs = reducer.splitCurrentRecording(at: splitDate)
        let firstDraft = try XCTUnwrap(splitOutputs.completedDraft)
        // The runtime saves the finished leg right after the split.
        _ = reducer.apply(.completionSaved(firstDraft.id))

        let moving = sample(at: splitDate.addingTimeInterval(60), metersNorth: 3_000, speed: 12, hint: .automotive)
        _ = reducer.apply(.location(moving, receivedAt: moving.timestamp, context: TripDetectionContext(), options: .normal))
        let stationary = sample(at: splitDate.addingTimeInterval(180), metersNorth: 3_000, speed: 0, hint: .stationary)
        _ = reducer.apply(.location(stationary, receivedAt: stationary.timestamp, context: TripDetectionContext(), options: .normal))

        let stopDueAt = try XCTUnwrap(reducer.state.stopDueAt)
        let outputs = reducer.apply(.stopTimerFired(stopDueAt.addingTimeInterval(1)))
        let draft = try XCTUnwrap(outputs.completedDraft)

        XCTAssertEqual(draft.startDate, splitDate)
        XCTAssertTrue(draft.samples.allSatisfy { $0.timestamp >= splitDate })
        XCTAssertGreaterThan(draft.distanceMeters, 0)
    }

    func testPostSplitStateSurvivesEncoding() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let splitDate = start.addingTimeInterval(120)
        let outputs = reducer.splitCurrentRecording(at: splitDate)
        let draft = try XCTUnwrap(outputs.completedDraft)

        let restored = try JSONDecoder.iso8601.decode(
            DriveCaptureState.self,
            from: JSONEncoder.iso8601.encode(reducer.state)
        )

        XCTAssertEqual(restored.phase, .recording)
        XCTAssertEqual(restored.startedAt, splitDate)
        XCTAssertEqual(restored.samples.count, 1)
        XCTAssertEqual(restored.pendingCompletionDraft?.id, draft.id)
        XCTAssertEqual(restored.pendingTripID, reducer.state.pendingTripID)
    }

    func testCompletionSavedWhileRecordingKeepsNewLegPendings() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        _ = reducer.setCurrentDriveClassification(.business)
        let outputs = reducer.splitCurrentRecording(at: start.addingTimeInterval(120))
        let draft = try XCTUnwrap(outputs.completedDraft)

        // The user classifies the new leg before leg 1's save lands.
        _ = reducer.setCurrentDriveClassification(.personal)
        _ = reducer.apply(.completionSaved(draft.id))

        XCTAssertNil(reducer.state.pendingCompletionDraft)
        XCTAssertEqual(reducer.state.pendingClassification, .personal)
        XCTAssertEqual(reducer.state.currentDriveSummary()?.classification, .personal)
    }
}

extension DriveCaptureReducerTests {
    func testStartVehicleHintSurvivesPromotionAndStampsDraft() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let vehicle = UUID()
        var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .both))
        _ = reducer.apply(.startSignal(
            DriveStartSignal(
                source: .externalVehicleAutomation,
                confidence: .strong,
                startedAt: start,
                expiresAt: start.addingTimeInterval(300),
                vehicleID: vehicle
            ),
            receivedAt: start
        ))
        startRecording(&reducer, start: start)
        XCTAssertEqual(reducer.state.phase, .recording)
        // Preserved across the candidate→recording promotion that nulls startSignal.
        XCTAssertEqual(reducer.state.startVehicleHint, vehicle)

        let (_, draft) = try completeWithConfirmedWalkAway(&reducer, start: start)
        XCTAssertEqual(draft.vehicleID, vehicle)
        XCTAssertEqual(draft.vehicleAssignmentSource, .shortcut)
        // Cleared once the draft carries it forward.
        XCTAssertNil(reducer.state.startVehicleHint)
    }

    func testPostParkingDerivedSpeedJitterDoesNotCreateNearbyTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = DriveCaptureReducer()
        startRecording(&reducer, start: start)
        let (dropoff, draft) = try completeWithConfirmedWalkAway(&reducer, start: start)
        _ = reducer.apply(.completionSaved(draft.id))

        let derivedJitter = sample(
            at: start.addingTimeInterval(854),
            metersNorth: 5_530,
            speed: nil,
            hint: .unknown,
            horizontalAccuracy: 25
        )
        let derivedOutputs = reducer.apply(.location(
            derivedJitter,
            receivedAt: derivedJitter.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))
        let speedJitter = sample(
            at: start.addingTimeInterval(855),
            metersNorth: 5_560,
            speed: 2.8,
            hint: .unknown,
            horizontalAccuracy: 25
        )
        let speedOutputs = reducer.apply(.location(
            speedJitter,
            receivedAt: speedJitter.timestamp,
            context: TripDetectionContext(),
            options: .normal
        ))

        XCTAssertEqual(draft.endDate, dropoff.timestamp)
        XCTAssertFalse(derivedOutputs.containsCandidateStarted)
        XCTAssertFalse(speedOutputs.containsCandidateStarted)
        XCTAssertEqual(reducer.state.phase, .idle)
    }
}

private extension DriveCaptureReducerTests {
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
