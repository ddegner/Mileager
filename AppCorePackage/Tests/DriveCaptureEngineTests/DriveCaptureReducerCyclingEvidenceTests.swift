import XCTest
import AppCoreModels
@testable import DriveCaptureEngine

/// The reducer is the only component that sees the cycling snapshots around a
/// capture — the ones that kill its candidates and the one that parks it — so
/// it must hand them to the completion classifiers on the draft.
final class DriveCaptureReducerCyclingEvidenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Cycling clears a parked-anchor candidate, then parks a later capture
    /// labeled automotive at bicycle speed.
    func testCyclingSnapshotsAroundACaptureRideOnTheDraft() throws {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(cycling(at: 0))

        _ = reducer.apply(.startSignal(
            DriveStartEngine.signal(source: .parkedAnchorExit, startedAt: t0.addingTimeInterval(60)),
            receivedAt: t0.addingTimeInterval(60)
        ))
        XCTAssertEqual(reducer.state.phase, .candidate)
        _ = reducer.apply(cycling(at: 70))
        XCTAssertEqual(reducer.state.phase, .idle, "cycling kills a sampleless candidate")

        XCTAssertTrue(ride(&reducer, from: 300, through: 500, speed: 7))
        XCTAssertEqual(reducer.state.phase, .recording)

        let outputs = reducer.apply(cycling(at: 505))
        let draft = try XCTUnwrap(completedDraft(outputs), "cycling right after the last moving fix must park the ride")

        XCTAssertEqual(draft.cyclingMotionDates, [0, 70, 505].map { t0.addingTimeInterval($0) })
        XCTAssertFalse(draft.vehicleConnectionObserved)
        XCTAssertEqual(draft.startDate, t0.addingTimeInterval(300))
        XCTAssertEqual(draft.endDate, t0.addingTimeInterval(500))

        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.cyclingBeforeStartCount, 2)
        XCTAssertEqual(evidence.cyclingDuringCount, 0)
        XCTAssertEqual(evidence.cyclingAfterEndCount, 1)
        XCTAssertEqual(evidence.peakReportedSpeedMetersPerSecond ?? 0, 7, accuracy: 0.001)
        guard case .cycling = CyclingTripClassifier().verdict(for: evidence) else {
            return XCTFail("End to end, the recorded ride must classify as cycling: \(evidence)")
        }
    }

    func testTrustedConnectionOnLocationContextMarksTheDraft() throws {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(cycling(at: 0))
        // The car's trusted hint is live for the first 30 s of the capture only.
        XCTAssertTrue(ride(&reducer, from: 300, through: 330, speed: 7, context: TripDetectionContext(trustedBluetoothVehicleHint: true)))
        ride(&reducer, from: 332, through: 500, speed: 7)

        let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))

        XCTAssertTrue(draft.vehicleConnectionObserved)
        XCTAssertEqual(CyclingTripClassifier().verdict(for: CyclingTripEvidence.extract(draft: draft)), .noMatch)
    }

    func testLiveConnectionEventMarksTheDraft() throws {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(cycling(at: 0))
        XCTAssertTrue(ride(&reducer, from: 300, through: 400, speed: 7))
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .bluetoothAudio, at: t0.addingTimeInterval(401)))
        ride(&reducer, from: 402, through: 500, speed: 7)

        let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))

        XCTAssertTrue(draft.vehicleConnectionObserved)
    }

    func testConnectionThatDroppedLongBeforeTheCaptureDoesNotMarkTheDraft() throws {
        // Drove home two hours earlier (link up, then down); the ride is clean.
        var reducer = DriveCaptureReducer(state: DriveCaptureState(
            vehicleConnectionActive: false,
            lastVehicleConnectionAt: t0.addingTimeInterval(-7_000),
            lastVehicleConnectionActiveAt: t0.addingTimeInterval(-7_200)
        ))
        _ = reducer.apply(cycling(at: 0))
        XCTAssertTrue(ride(&reducer, from: 300, through: 500, speed: 7))

        let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))

        XCTAssertFalse(draft.vehicleConnectionObserved)
    }

    func testDisconnectionInsideTheLeadInMarksTheDraft() throws {
        // The link was live entering the window and dropped five minutes
        // before the capture began: a car was present.
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .bluetoothAudio, at: t0.addingTimeInterval(-3_600)))
        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .bluetoothAudio, at: t0))
        _ = reducer.apply(cycling(at: 10))
        XCTAssertTrue(ride(&reducer, from: 300, through: 500, speed: 7))

        let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))

        XCTAssertTrue(draft.vehicleConnectionObserved)
    }

    func testIdleRetentionKeepsOnlyTheLeadIn() {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(cycling(at: 0))
        _ = reducer.apply(cycling(at: 1_800))
        _ = reducer.apply(cycling(at: 2_400))

        XCTAssertEqual(reducer.state.recentCyclingMotionDates, [1_800, 2_400].map { t0.addingTimeInterval($0) })
    }

    func testRetentionAnchorsOnTheCaptureStartWhileRecording() {
        // Cycling 14 minutes before a capture that has been recording for 30
        // minutes must survive a mid-capture snapshot; anchoring on the
        // snapshot itself would age it out.
        var reducer = DriveCaptureReducer(state: DriveCaptureState(
            phase: .recording,
            startedAt: t0,
            recentCyclingMotionDates: [t0.addingTimeInterval(-840)]
        ))

        _ = reducer.apply(cycling(at: 1_800))

        XCTAssertEqual(reducer.state.recentCyclingMotionDates, [-840, 1_800].map { t0.addingTimeInterval($0) })
    }

    func testCompletionPrunesTheCheckpointBehindTheCapture() throws {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(cycling(at: -700))
        _ = reducer.apply(cycling(at: 0))
        XCTAssertTrue(ride(&reducer, from: 300, through: 500, speed: 7))

        let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))

        // -700 is outside the 15-minute lead-in of a start at +300.
        XCTAssertEqual(draft.cyclingMotionDates, [0, 505].map { t0.addingTimeInterval($0) })
        XCTAssertTrue(reducer.state.recentCyclingMotionDates.allSatisfy { $0 >= t0.addingTimeInterval(500 - 16 * 60) })
    }

    func testLowConfidenceCyclingIsNotEvidence() {
        var reducer = DriveCaptureReducer()
        let date = t0
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: date, confidence: .low, hints: [.cycling]),
            receivedAt: date
        ))
        _ = reducer.apply(.motionActivity(
            MotionActivitySnapshot(startDate: date.addingTimeInterval(1), confidence: .high, hints: [.walking]),
            receivedAt: date.addingTimeInterval(1)
        ))

        XCTAssertTrue(reducer.state.recentCyclingMotionDates.isEmpty)
    }

    func testCheckpointsFromBuildsWithoutCyclingKeysDecode() throws {
        let state = DriveCaptureState(
            recentCyclingMotionDates: [t0],
            lastVehicleConnectionActiveAt: t0
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.cyclingTests.encode(state)) as? [String: Any]
        )
        object.removeValue(forKey: "recentCyclingMotionDates")
        object.removeValue(forKey: "lastVehicleConnectionActiveAt")
        let decoded = try JSONDecoder.cyclingTests.decode(
            DriveCaptureState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(decoded.recentCyclingMotionDates.isEmpty)
        XCTAssertNil(decoded.lastVehicleConnectionActiveAt)

        let draft = TripDraft(
            startDate: t0,
            endDate: t0.addingTimeInterval(60),
            samples: [],
            distanceMeters: 100,
            cyclingMotionDates: [t0],
            vehicleConnectionObserved: true
        )
        var draftObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.cyclingTests.encode(draft)) as? [String: Any]
        )
        draftObject.removeValue(forKey: "cyclingMotionDates")
        draftObject.removeValue(forKey: "vehicleConnectionObserved")
        let decodedDraft = try JSONDecoder.cyclingTests.decode(
            TripDraft.self,
            from: JSONSerialization.data(withJSONObject: draftObject)
        )
        XCTAssertTrue(decodedDraft.cyclingMotionDates.isEmpty)
        XCTAssertFalse(decodedDraft.vehicleConnectionObserved)
    }

    func testCyclingEvidenceSurvivesEncoding() throws {
        let state = DriveCaptureState(
            recentCyclingMotionDates: [t0, t0.addingTimeInterval(30)],
            lastVehicleConnectionActiveAt: t0.addingTimeInterval(-5)
        )
        let restored = try JSONDecoder.cyclingTests.decode(
            DriveCaptureState.self,
            from: JSONEncoder.cyclingTests.encode(state)
        )
        XCTAssertEqual(restored.recentCyclingMotionDates, state.recentCyclingMotionDates)
        XCTAssertEqual(restored.lastVehicleConnectionActiveAt, state.lastVehicleConnectionActiveAt)

        let draft = TripDraft(
            startDate: t0,
            endDate: t0.addingTimeInterval(60),
            samples: [],
            distanceMeters: 100,
            cyclingMotionDates: [t0.addingTimeInterval(10), t0.addingTimeInterval(-10)],
            vehicleConnectionObserved: true
        )
        let restoredDraft = try JSONDecoder.cyclingTests.decode(TripDraft.self, from: JSONEncoder.cyclingTests.encode(draft))
        XCTAssertEqual(restoredDraft.cyclingMotionDates, [t0.addingTimeInterval(-10), t0.addingTimeInterval(10)])
        XCTAssertTrue(restoredDraft.vehicleConnectionObserved)
    }

    // MARK: - Helpers

    private func cycling(at offset: TimeInterval) -> DriveCaptureEvent {
        let date = t0.addingTimeInterval(offset)
        return .motionActivity(
            MotionActivitySnapshot(startDate: date, confidence: .high, hints: [.cycling]),
            receivedAt: date
        )
    }

    /// Feeds automotive-labeled fixes every two seconds at a steady speed and
    /// reports whether recording started.
    @discardableResult
    private func ride(
        _ reducer: inout DriveCaptureReducer,
        from startOffset: TimeInterval,
        through endOffset: TimeInterval,
        speed: Double,
        context: TripDetectionContext = TripDetectionContext()
    ) -> Bool {
        var started = false
        var offset = startOffset
        while offset <= endOffset {
            let fix = LocationSample(
                timestamp: t0.addingTimeInterval(offset),
                latitude: 40 + (offset * speed) / 111_111,
                longitude: -73,
                horizontalAccuracy: 8,
                speedMetersPerSecond: speed,
                motionHint: .automotive
            )
            let outputs = reducer.apply(.location(fix, receivedAt: fix.timestamp, context: context, options: .normal))
            started = started || outputs.contains { if case .tripStarted = $0 { return true } else { return false } }
            offset += 2
        }
        return started
    }

    private func completedDraft(_ outputs: [DriveCaptureOutput]) -> TripDraft? {
        for output in outputs {
            if case .tripCompleted(let draft) = output { return draft }
        }
        return nil
    }
}

private extension JSONEncoder {
    static var cyclingTests: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cyclingTests: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
