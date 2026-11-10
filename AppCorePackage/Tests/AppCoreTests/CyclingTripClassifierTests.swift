import XCTest
@testable import AppCore

/// Reconstructed cycling signatures with offsets relative to capture start.
final class CyclingTripClassifierTests: XCTestCase {
    private let classifier = CyclingTripClassifier()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // Cycling before the capture and one second after its end surrounds
    // 153 seconds of automotive-labeled fixes at bicycle speeds.
    func testCyclingBeforeAndAfterCaptureIsCycling() {
        let draft = makeDraft(duration: 153, peakSpeed: 7.1, cyclingOffsets: [-753, -256, 154])

        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.cyclingBeforeStartCount, 2)
        XCTAssertEqual(evidence.cyclingDuringCount, 0)
        XCTAssertEqual(evidence.cyclingAfterEndCount, 1)
        XCTAssertFalse(evidence.vehicleConnectionObserved)
        guard case .cycling(let reason) = classifier.verdict(for: evidence) else {
            return XCTFail("Expected cycling, got noMatch: \(evidence)")
        }
        XCTAssertTrue(reason.contains("before=2"), reason)
        XCTAssertTrue(reason.contains("after=1"), reason)
    }

    // Cycling 21 and 8 seconds before the start and again 38 seconds in.
    func testCyclingBeforeAndDuringCaptureIsCycling() {
        let draft = makeDraft(duration: 300, peakSpeed: 8.7, cyclingOffsets: [-21, -8, 38])

        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.cyclingBeforeStartCount, 2)
        XCTAssertEqual(evidence.cyclingDuringCount, 1)
        XCTAssertEqual(evidence.cyclingAfterEndCount, 0)
        guard case .cycling = classifier.verdict(for: evidence) else {
            return XCTFail("Expected cycling, got noMatch: \(evidence)")
        }
    }

    func testCyclingBeforeStartAloneIsNoMatch() {
        // Rode to the car, then drove: the lead-in half alone proves nothing.
        let draft = makeDraft(duration: 1_200, peakSpeed: 9, cyclingOffsets: [-300])
        XCTAssertEqual(classifier.verdict(for: CyclingTripEvidence.extract(draft: draft)), .noMatch)
    }

    func testStrayCyclingDuringOrAfterADriveIsNoMatch() {
        // Cars collect stray cycling reports mid-drive and right after
        // parking; without the lead-in half the bracket never closes.
        let draft = makeDraft(duration: 1_200, peakSpeed: 9, cyclingOffsets: [600, 1_210])
        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.cyclingBeforeStartCount, 0)
        XCTAssertEqual(evidence.cyclingDuringCount, 1)
        XCTAssertEqual(evidence.cyclingAfterEndCount, 1)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testVehicleConnectionVetoesFromEitherSide() {
        let fromReducer = makeDraft(duration: 153, peakSpeed: 7.1, cyclingOffsets: [-753, 154], vehicleConnectionObserved: true)
        XCTAssertEqual(classifier.verdict(for: CyclingTripEvidence.extract(draft: fromReducer)), .noMatch)

        let fromStores = makeDraft(duration: 153, peakSpeed: 7.1, cyclingOffsets: [-753, 154])
        let evidence = CyclingTripEvidence.extract(draft: fromStores, vehicleConnectionObserved: true)
        XCTAssertTrue(evidence.vehicleConnectionObserved)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    // Car-like speed vetoes a complete cycling bracket.
    func testCarSpeedVetoes() {
        let car = makeDraft(duration: 300, peakSpeed: 18.7, cyclingOffsets: [-120, 310])
        XCTAssertEqual(classifier.verdict(for: CyclingTripEvidence.extract(draft: car)), .noMatch)

        let atCeiling = makeDraft(duration: 300, peakSpeed: 13, cyclingOffsets: [-120, 310])
        guard case .cycling = classifier.verdict(for: CyclingTripEvidence.extract(draft: atCeiling)) else {
            return XCTFail("13 m/s is inclusive")
        }
        let overCeiling = makeDraft(duration: 300, peakSpeed: 13.01, cyclingOffsets: [-120, 310])
        XCTAssertEqual(classifier.verdict(for: CyclingTripEvidence.extract(draft: overCeiling)), .noMatch)
    }

    func testMissingSpeedsFailOpen() {
        let draft = makeDraft(duration: 153, peakSpeed: 7.1, cyclingOffsets: [-753, 154], speedless: true)
        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertNil(evidence.peakReportedSpeedMetersPerSecond)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testBracketWindowBoundariesAreInclusive() {
        let inside = makeDraft(duration: 300, peakSpeed: 7, cyclingOffsets: [-900, 600])
        let insideEvidence = CyclingTripEvidence.extract(draft: inside)
        XCTAssertEqual(insideEvidence.cyclingBeforeStartCount, 1)
        XCTAssertEqual(insideEvidence.cyclingAfterEndCount, 1)
        guard case .cycling = classifier.verdict(for: insideEvidence) else {
            return XCTFail("Both edges are inclusive")
        }

        let outside = makeDraft(duration: 300, peakSpeed: 7, cyclingOffsets: [-901, 601])
        let outsideEvidence = CyclingTripEvidence.extract(draft: outside)
        XCTAssertEqual(outsideEvidence.cyclingBeforeStartCount, 0)
        XCTAssertEqual(outsideEvidence.cyclingAfterEndCount, 0)
        XCTAssertEqual(classifier.verdict(for: outsideEvidence), .noMatch)

        // Exactly at the start and exactly at the end both count as "during".
        let edges = makeDraft(duration: 300, peakSpeed: 7, cyclingOffsets: [-10, 0, 300])
        XCTAssertEqual(CyclingTripEvidence.extract(draft: edges).cyclingDuringCount, 2)
    }

    func testCyclingHintsOnInTripFixesCountAsDuring() {
        var draft = makeDraft(duration: 300, peakSpeed: 7, cyclingOffsets: [-120])
        draft.samples[10].motionHint = .cycling
        draft.samples[20].motionActivity = MotionActivitySnapshot(
            startDate: draft.samples[20].timestamp,
            confidence: .high,
            hints: [.cycling]
        )
        // A low-confidence cycling activity on a fix is not evidence.
        draft.samples[30].motionActivity = MotionActivitySnapshot(
            startDate: draft.samples[30].timestamp,
            confidence: .low,
            hints: [.cycling]
        )

        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.cyclingDuringCount, 2)
        guard case .cycling = classifier.verdict(for: evidence) else {
            return XCTFail("Expected cycling, got noMatch: \(evidence)")
        }
    }

    func testWeakAccuracyAndOutOfWindowFixesDoNotSetThePeak() {
        var draft = makeDraft(duration: 300, peakSpeed: 7, cyclingOffsets: [-120, 305])
        draft.samples.append(LocationSample(
            timestamp: start.addingTimeInterval(150),
            latitude: 40.7, longitude: -38.99, horizontalAccuracy: 300,
            speedMetersPerSecond: 50
        ))
        draft.samples.append(LocationSample(
            timestamp: start.addingTimeInterval(900),
            latitude: 40.7, longitude: -38.99, horizontalAccuracy: 5,
            speedMetersPerSecond: 40
        ))

        let evidence = CyclingTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.peakReportedSpeedMetersPerSecond ?? 0, 7, accuracy: 0.001)
        guard case .cycling = classifier.verdict(for: evidence) else {
            return XCTFail("Expected cycling, got noMatch: \(evidence)")
        }
    }

    // MARK: - Helpers

    private func makeDraft(
        duration: TimeInterval,
        peakSpeed: Double,
        cyclingOffsets: [TimeInterval],
        vehicleConnectionObserved: Bool = false,
        speedless: Bool = false
    ) -> TripDraft {
        let offsets = Array(stride(from: 0.0, through: duration, by: 2))
        let peakIndex = offsets.count / 2
        let samples = offsets.enumerated().map { index, offset in
            LocationSample(
                timestamp: start.addingTimeInterval(offset),
                latitude: 40.70 + offset * 6 / 111_111,
                longitude: -38.99,
                horizontalAccuracy: 8,
                speedMetersPerSecond: speedless ? nil : (index == peakIndex ? peakSpeed : peakSpeed * 0.6),
                motionHint: .automotive
            )
        }
        return TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            samples: samples,
            distanceMeters: duration * 6,
            cyclingMotionDates: cyclingOffsets.map { start.addingTimeInterval($0) },
            vehicleConnectionObserved: vehicleConnectionObserved
        )
    }
}
