import XCTest
import AppCoreModels
@testable import DriveCaptureEngine

final class VehicleAutomationCyclingEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAcceptedCarActionsPreserveCyclingVetoWithoutLiveConnectionOrMapping() throws {
        for mode in [AutomaticTripStartMode.both, .bluetoothOrCarPlay] {
            for trigger in [DriveStartExternalTrigger.vehicleBluetooth, .carPlay] {
                var reducer = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: mode))
                _ = reducer.apply(cycling(at: 0))
                _ = reducer.apply(action(trigger, at: 300))
                XCTAssertFalse(reducer.state.vehicleConnectionActive)
                XCTAssertFalse(reducer.state.vehicleAudioConnectionActive)
                XCTAssertNil(reducer.state.startVehicleHint)
                reducer = try restored(reducer)
                drive(&reducer, from: 300, through: 400)
                XCTAssertEqual(reducer.state.phase, .recording)
                reducer = try restored(reducer)
                drive(&reducer, from: 402, through: 500)

                let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))
                XCTAssertTrue(draft.vehicleConnectionObserved, "\(mode), \(trigger)")
                XCTAssertNil(draft.vehicleID)
                XCTAssertEqual(CyclingTripClassifier().verdict(for: CyclingTripEvidence.extract(draft: draft)), .noMatch)
            }
        }
    }

    func testManualChargerAndUnspecifiedActionsDoNotVetoCycling() throws {
        let signals = [
            DriveStartEngine.signal(forExternalTrigger: .manual, at: date(300)),
            DriveStartEngine.signal(forExternalTrigger: .charger, at: date(300)),
            DriveStartEngine.signal(source: .externalVehicleAutomation, startedAt: date(300))
        ]
        for signal in signals {
            var reducer = DriveCaptureReducer()
            _ = reducer.apply(cycling(at: 0))
            _ = reducer.apply(.startSignal(signal, receivedAt: date(300)))
            drive(&reducer, from: 300, through: 500)
            let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))
            assertCycling(draft)
            XCTAssertNil(reducer.state.lastVehicleAutomationSignalAt)
        }
    }

    func testIgnoredExpiredAndPausedCarActionsDoNotLeaveVehicleEvidence() throws {
        var ignored = DriveCaptureReducer(state: DriveCaptureState(automaticTripStartMode: .motionDetection))
        _ = ignored.apply(cycling(at: 0))
        _ = ignored.apply(action(.vehicleBluetooth, at: 300))
        XCTAssertNil(ignored.state.lastVehicleAutomationSignalAt)
        drive(&ignored, from: 300, through: 500)
        assertCycling(try XCTUnwrap(completedDraft(ignored.apply(cycling(at: 505)))))

        var expired = DriveCaptureReducer()
        _ = expired.apply(cycling(at: 0))
        let oldSignal = DriveStartEngine.signal(forExternalTrigger: .carPlay, at: date(-1))
        _ = expired.apply(.startSignal(oldSignal, receivedAt: date(300)))
        XCTAssertNil(expired.state.lastVehicleAutomationSignalAt)
        drive(&expired, from: 300, through: 500)
        assertCycling(try XCTUnwrap(completedDraft(expired.apply(cycling(at: 505)))))

        var paused = DriveCaptureReducer()
        _ = paused.apply(.trackingPaused(until: date(600)))
        _ = paused.apply(action(.carPlay, at: 300))
        XCTAssertNil(paused.state.lastVehicleAutomationSignalAt)
        XCTAssertEqual(paused.state.phase, .paused)
    }

    func testAudioConnectionsVetoCyclingButUSBPowerDoesNot() throws {
        for source in [VehicleConnectionSource.bluetoothAudio, .carPlayAudio, .unknownTrustedRoute, .usbPower] {
            var reducer = DriveCaptureReducer()
            _ = reducer.apply(cycling(at: 0))
            _ = reducer.apply(.vehicleConnectionChanged(active: true, source: source, at: date(290)))
            drive(&reducer, from: 300, through: 500)
            let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))
            if source == .usbPower {
                assertCycling(draft)
                XCTAssertNil(reducer.state.lastVehicleConnectionActiveAt)
            } else {
                XCTAssertTrue(draft.vehicleConnectionObserved)
                XCTAssertEqual(CyclingTripClassifier().verdict(for: CyclingTripEvidence.extract(draft: draft)), .noMatch)
            }
        }
    }

    func testUSBChangesDoNotEraseAnIndependentLongLivedCarAudioConnection() throws {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .carPlayAudio, at: date(-3_600)))
        _ = reducer.apply(cycling(at: 0))
        _ = reducer.apply(.vehicleConnectionChanged(active: true, source: .usbPower, at: date(100)))
        _ = reducer.apply(.vehicleConnectionChanged(active: false, source: .usbPower, at: date(150)))
        reducer = try restored(reducer)
        drive(&reducer, from: 300, through: 500)
        let draft = try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505))))
        XCTAssertTrue(draft.vehicleConnectionObserved)
    }

    func testOldCarActionDoesNotVetoAnUnrelatedLaterBikeRide() throws {
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(action(.vehicleBluetooth, at: -1_000))
        _ = reducer.apply(cycling(at: 0))
        drive(&reducer, from: 300, through: 500)
        assertCycling(try XCTUnwrap(completedDraft(reducer.apply(cycling(at: 505)))))
    }

    func testNewEvidenceKeysDefaultSafelyWhenReadingOldCheckpoints() throws {
        let state = DriveCaptureState(vehicleConnectionActive: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "vehicleAudioConnectionActive")
        object.removeValue(forKey: "lastVehicleAutomationSignalAt")
        let decoded = try JSONDecoder().decode(DriveCaptureState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.vehicleConnectionActive, "Preserve the existing parking channel")
        XCTAssertFalse(decoded.vehicleAudioConnectionActive, "A legacy generic connection could be USB power")
        XCTAssertNil(decoded.lastVehicleAutomationSignalAt)
    }

    private func assertCycling(_ draft: TripDraft, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(draft.vehicleConnectionObserved, file: file, line: line)
        guard case .cycling = CyclingTripClassifier().verdict(for: CyclingTripEvidence.extract(draft: draft)) else {
            return XCTFail("Expected the cycling bracket to remain effective", file: file, line: line)
        }
    }

    private func date(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

    private func action(_ trigger: DriveStartExternalTrigger, at offset: TimeInterval) -> DriveCaptureEvent {
        .startSignal(DriveStartEngine.signal(forExternalTrigger: trigger, at: date(offset)), receivedAt: date(offset))
    }

    private func cycling(at offset: TimeInterval) -> DriveCaptureEvent {
        .motionActivity(MotionActivitySnapshot(startDate: date(offset), confidence: .high, hints: [.cycling]), receivedAt: date(offset))
    }

    private func restored(_ reducer: DriveCaptureReducer) throws -> DriveCaptureReducer {
        DriveCaptureReducer(state: try JSONDecoder().decode(DriveCaptureState.self, from: JSONEncoder().encode(reducer.state)))
    }

    private func drive(_ reducer: inout DriveCaptureReducer, from first: Int, through last: Int) {
        for offset in stride(from: first, through: last, by: 2) {
            let sample = LocationSample(timestamp: date(Double(offset)), latitude: 40 + Double(offset) * 7 / 111_111,
                                        longitude: -73, horizontalAccuracy: 8, speedMetersPerSecond: 7, motionHint: .automotive)
            _ = reducer.apply(.location(sample, receivedAt: sample.timestamp, context: TripDetectionContext(), options: .normal))
        }
    }

    private func completedDraft(_ outputs: [DriveCaptureOutput]) -> TripDraft? {
        outputs.compactMap { if case .tripCompleted(let draft) = $0 { draft } else { nil } }.first
    }
}
