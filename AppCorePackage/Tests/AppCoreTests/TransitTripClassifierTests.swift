import XCTest
@testable import AppCore

final class TransitTripClassifierTests: XCTestCase {
    private let classifier = TransitTripClassifier()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testSubwayLikeTripIsTransit() {
        // 20-min ride: usable GPS only for the first third (elevated/bridge),
        // junk cell fixes underground, boarding blackout before the start.
        let draft = makeDraft(duration: 1_200)
        var samples = makeSamples(from: 0, to: 396, interval: 2, accuracy: 10)
        samples += makeSamples(from: 396, to: 1_200, interval: 2, accuracy: 611)
        samples[20].detectionReason = "Impossible GPS jump"

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        guard case .transit(let reason) = classifier.verdict(for: evidence) else {
            return XCTFail("Expected transit, got noMatch: \(evidence)")
        }
        XCTAssertTrue(reason.contains("usable=0.33"), reason)
        XCTAssertTrue(reason.contains("jumps=1"), reason)
    }

    func testContinuousCarDriveIsNoMatch() {
        let draft = makeDraft(duration: 1_200)
        var samples = makeSamples(from: 0, to: 1_200, interval: 2, accuracy: 8)
        // Parked one second before departure: no boarding blackout.
        samples.append(makeSample(at: -1, accuracy: 8))

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.usableAccuracyFraction, 1.0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testTunnelCarDriveIsNoMatch() {
        // 3-minute mid-trip blackout; clean GPS otherwise. Tunnels go dark,
        // they don't deliver junk samples — both fractions stay high.
        let draft = makeDraft(duration: 1_200, attentionReasons: ["Impossible GPS jump"])
        var samples = makeSamples(from: 0, to: 600, interval: 2, accuracy: 8)
        samples += makeSamples(from: 780, to: 1_200, interval: 2, accuracy: 8)

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.usableAccuracyFraction, 1.0)
        XCTAssertGreaterThanOrEqual(evidence.coverageFraction, 0.8)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testUrbanCanyonDriveIsNoMatch() {
        // Noisy but mostly-usable accuracy with full coverage.
        let draft = makeDraft(duration: 1_200)
        var samples: [DiagnosticLocationSample] = []
        for (index, offset) in stride(from: 0.0, to: 1_200, by: 2).enumerated() {
            samples.append(makeSample(at: offset, accuracy: index % 10 < 7 ? 40 : 120))
        }

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.usableAccuracyFraction, 0.7, accuracy: 0.01)
        XCTAssertEqual(evidence.coverageFraction, 1.0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testPowerConnectedVetoesTransit() {
        let draft = makeDraft(duration: 1_200)
        var samples = makeSamples(from: 0, to: 396, interval: 2, accuracy: 10)
        samples += makeSamples(from: 396, to: 1_200, interval: 2, accuracy: 611)
        samples[40].powerConnected = true
        samples[41].detectionReason = "Impossible GPS jump"

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.powerConnectedSampleCount, 1)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testTrustedBluetoothVetoesTransitEvenBeforeStart() {
        let draft = makeDraft(duration: 1_200)
        var samples = makeSamples(from: 0, to: 396, interval: 2, accuracy: 10)
        samples += makeSamples(from: 396, to: 1_200, interval: 2, accuracy: 611)
        samples[10].detectionReason = "Impossible GPS jump"
        // The car was connected five minutes before the backdated start.
        var preTrip = makeSample(at: -300, accuracy: 15)
        preTrip.trustedBluetoothVehicleHint = true
        samples.append(preTrip)

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.trustedBluetoothSampleCount, 1)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testLongPreTripGapAloneCorroborates() {
        // No impossible jump, but the last sample before the trip is a
        // 2131-second blackout — the boarding signature.
        let draft = makeDraft(duration: 1_200)
        var samples = makeSamples(from: 0, to: 396, interval: 2, accuracy: 10)
        samples += makeSamples(from: 396, to: 1_200, interval: 2, accuracy: 611)
        samples.append(makeSample(at: -2_131, accuracy: 12))

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.impossibleJumpCount, 0)
        guard case .transit(let reason) = classifier.verdict(for: evidence) else {
            return XCTFail("Expected transit: \(evidence)")
        }
        XCTAssertTrue(reason.contains("preGap=2131s"), reason)
    }

    func testDegradedTripWithoutCorroboratorIsNoMatch() {
        let draft = makeDraft(duration: 1_200)
        var samples = makeSamples(from: 0, to: 396, interval: 2, accuracy: 10)
        samples += makeSamples(from: 396, to: 1_200, interval: 2, accuracy: 611)
        // Recent pre-trip fix: no blackout, and no jump anywhere.
        samples.append(makeSample(at: -120, accuracy: 12))

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testShortFragmentsNeverAutoMark() {
        let draft = makeDraft(duration: 300)
        let samples = makeSamples(from: 0, to: 300, interval: 2, accuracy: 611)

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testTooFewSamplesNeverAutoMark() {
        let draft = makeDraft(duration: 900)
        let samples = makeSamples(from: 0, to: 900, interval: 60, accuracy: 611)

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertLessThan(evidence.diagnosticSampleCount, TransitTripClassifier.minimumDiagnosticSampleCount)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testRealJune10SubwayNumbersAreTransit() {
        // The actual June 10 ride: 652 samples, 212 usable (32.5%), 17 of 42
        // thirty-second windows covered, one impossible jump, 35-min blackout.
        let draft = makeDraft(duration: 1_245, attentionReasons: ["Impossible GPS jump"])
        var samples: [DiagnosticLocationSample] = []
        for index in 0..<212 {
            samples.append(makeSample(at: Double(index) / 212.0 * 509.0, accuracy: 9))
        }
        for index in 0..<440 {
            samples.append(makeSample(at: 510 + Double(index) / 440.0 * 734.0, accuracy: 611))
        }

        let evidence = TransitTripEvidence.extract(draft: draft, diagnosticSamples: samples)
        XCTAssertEqual(evidence.diagnosticSampleCount, 652)
        XCTAssertEqual(evidence.usableAccuracyFraction, 0.325, accuracy: 0.001)
        XCTAssertEqual(evidence.coverageFraction, 17.0 / 42.0, accuracy: 0.001)
        XCTAssertNil(evidence.preTripGapSeconds)

        guard case .transit = classifier.verdict(for: evidence) else {
            return XCTFail("Expected transit: \(evidence)")
        }
    }

    // MARK: - Helpers

    private func makeDraft(duration: TimeInterval, attentionReasons: [String] = []) -> TripDraft {
        TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            samples: [
                LocationSample(timestamp: start, latitude: 40.0, longitude: -73.0, horizontalAccuracy: 10),
                LocationSample(timestamp: start.addingTimeInterval(duration), latitude: 40.05, longitude: -73.0, horizontalAccuracy: 10)
            ],
            distanceMeters: 6_000,
            attentionReasons: attentionReasons
        )
    }

    private func makeSamples(
        from startOffset: TimeInterval,
        to endOffset: TimeInterval,
        interval: TimeInterval,
        accuracy: Double
    ) -> [DiagnosticLocationSample] {
        stride(from: startOffset, to: endOffset, by: interval).map { offset in
            makeSample(at: offset, accuracy: accuracy)
        }
    }

    private func makeSample(at offset: TimeInterval, accuracy: Double) -> DiagnosticLocationSample {
        let timestamp = start.addingTimeInterval(offset)
        return DiagnosticLocationSample(
            monitoringSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            receivedAt: timestamp,
            sample: LocationSample(
                timestamp: timestamp,
                latitude: 40.0 + offset / 111_111,
                longitude: -73.0,
                horizontalAccuracy: accuracy
            ),
            trackingPhase: "recording",
            powerConnected: false,
            recentPowerConnected: false,
            recentPowerDisconnected: false,
            trustedBluetoothVehicleHint: false,
            acceptedForDetection: true,
            expiresAt: timestamp.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }
}
