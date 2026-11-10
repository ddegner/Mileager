import XCTest
@testable import AppCore

/// Flight signatures reconstructed with shifted coordinates and relative
/// timestamps so the tests retain their displacement and speed evidence.
final class AircraftTripClassifierTests: XCTestCase {
    private let classifier = AircraftTripClassifier()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // Slow taxi fixes, a GPS blackout, then a 215.9 m/s fix 460 km away.
    func testCruiseFixAfterBlackoutIsAircraft() {
        var samples = taxiSamples(
            from: 0, to: 1_920, interval: 2,
            around: (40.7773, -38.8756), speed: 2
        )
        samples.append(sample(
            at: 4_497, latitude: 41.0776, longitude: -44.3515,
            speed: 215.9, speedAccuracy: 2.7, accuracy: 5
        ))
        let draft = makeDraft(duration: 4_680, samples: samples)

        let evidence = AircraftTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 1)
        XCTAssertEqual(evidence.blackoutJumpCount, 1)
        XCTAssertGreaterThan(evidence.longestBlackoutDisplacementMeters, 400_000)
        guard case .aircraft(let reason) = classifier.verdict(for: evidence) else {
            return XCTFail("Expected aircraft, got noMatch: \(evidence)")
        }
        XCTAssertTrue(reason.contains("corroborated"), reason)
        XCTAssertTrue(reason.contains("peak=216"), reason)
    }

    // A fast approach fix, a 636 s blackout across 38 km, and a
    // decelerating landing rollout followed by taxiing.
    func testLandingApproachWithBlackoutIsAircraft() {
        var samples = [
            sample(at: 0, latitude: 41.0590, longitude: -38.6350, speed: 142.6, speedAccuracy: 1.3, accuracy: 2),
            sample(at: 636, latitude: 40.7769, longitude: -38.8740, speed: 67.7, speedAccuracy: 0.9, accuracy: 8),
            sample(at: 695, latitude: 40.7752, longitude: -38.8705, speed: 46.7, speedAccuracy: 0.9, accuracy: 3),
            sample(at: 696, latitude: 40.7751, longitude: -38.8700, speed: 43.7, speedAccuracy: 0.9, accuracy: 2),
            sample(at: 697, latitude: 40.7750, longitude: -38.8695, speed: 40.9, speedAccuracy: 0.9, accuracy: 2)
        ]
        samples += taxiSamples(from: 700, to: 1_320, interval: 2, around: (40.7745, -38.8719), speed: 4)
        let draft = makeDraft(duration: 1_325, samples: samples)

        let evidence = AircraftTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 1)
        XCTAssertEqual(evidence.blackoutJumpCount, 1)
        guard case .aircraft = classifier.verdict(for: evidence) else {
            return XCTFail("Expected aircraft, got noMatch: \(evidence)")
        }
    }

    // A takeoff roll from 40.1 to 58.6 m/s over ten seconds can resemble
    // acceleration by a fast road vehicle.
    func testTakeoffRollAtRoadSpeedsIsNoMatch() {
        var samples = taxiSamples(from: 0, to: 286, interval: 2, around: (42.8819, -50.5295), speed: 6)
        for step in 0..<10 {
            samples.append(sample(
                at: 287 + Double(step),
                latitude: 42.8819 + Double(step) * 0.0004,
                longitude: -50.5295,
                speed: 40.1 + Double(step) * 2.06,
                speedAccuracy: 0.5,
                accuracy: 3
            ))
        }
        let draft = makeDraft(duration: 296, samples: samples)

        let evidence = AircraftTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 0)
        XCTAssertEqual(evidence.peakReportedSpeedMetersPerSecond, 58.64, accuracy: 0.01)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testSustainedAircraftSpeedWithoutBlackoutIsAircraft() {
        // Climb-out with a window-seat GPS lock: continuous fixes, no blackout.
        var samples: [LocationSample] = []
        for step in 0..<3 {
            samples.append(sample(
                at: Double(step), latitude: 40.80 + Double(step) * 0.001, longitude: -38.80,
                speed: 95 + Double(step), speedAccuracy: 1, accuracy: 5
            ))
        }
        let draft = makeDraft(duration: 10, samples: samples)

        let evidence = AircraftTripEvidence.extract(draft: draft)
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 3)
        XCTAssertEqual(evidence.blackoutJumpCount, 0)
        guard case .aircraft(let reason) = classifier.verdict(for: evidence) else {
            return XCTFail("Expected aircraft, got noMatch: \(evidence)")
        }
        XCTAssertTrue(reason.contains("sustained"), reason)
    }

    func testTwoAircraftSpeedFixesWithoutBlackoutFailOpen() {
        let samples = [
            sample(at: 0, latitude: 40.80, longitude: -38.80, speed: 120, speedAccuracy: 1, accuracy: 5),
            sample(at: 1, latitude: 40.801, longitude: -38.80, speed: 121, speedAccuracy: 1, accuracy: 5)
        ]
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 10, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 2)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testSingleFastGlitchInContinuousDriveIsNoMatch() {
        // One Doppler glitch mid-drive with otherwise continuous highway fixes.
        var samples = highwaySamples(from: 0, to: 1_200, interval: 2)
        samples[300] = sample(
            at: 600, latitude: samples[300].latitude, longitude: samples[300].longitude,
            speed: 142.6, speedAccuracy: 1.3, accuracy: 2
        )
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 1_200, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 1)
        XCTAssertEqual(evidence.blackoutJumpCount, 0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testRepeatedDeliveryOfOneFastGlitchIsNoMatch() {
        var samples = highwaySamples(from: 0, to: 1_200, interval: 2)
        let glitch = sample(
            at: 600, latitude: samples[300].latitude, longitude: samples[300].longitude,
            speed: 142.6, speedAccuracy: 1.3, accuracy: 2
        )
        samples[300] = glitch
        samples.append(contentsOf: [glitch, glitch])
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 1_200, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 1)
        XCTAssertEqual(evidence.blackoutJumpCount, 0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testConflictingFixesAtOneTimeCannotCreateBlackoutEvidence() {
        let first = sample(at: 0, latitude: 40.80, longitude: -38.80, speed: 120, speedAccuracy: 1, accuracy: 5)
        let near = sample(at: 120, latitude: 40.801, longitude: -38.80, speed: 30, speedAccuracy: 1, accuracy: 5)
        let far = sample(at: 120, latitude: 41.00, longitude: -38.80, speed: 120, speedAccuracy: 1, accuracy: 5)
        let last = sample(at: 240, latitude: 41.01, longitude: -38.80, speed: 30, speedAccuracy: 1, accuracy: 5)
        for middle in [[near, far], [far, near]] {
            let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 240, samples: [first] + middle + [last]))
            XCTAssertEqual(evidence.aircraftSpeedSampleCount, 1)
            XCTAssertEqual(evidence.blackoutJumpCount, 0)
            XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
        }
    }

    func testAutobahnBlackoutWithoutAircraftSpeedIsNoMatch() {
        // Four dark minutes at 200 km/h: 13 km displacement, implied 55 m/s,
        // but every reported speed stays below 60 m/s.
        var samples = highwaySamples(from: 0, to: 600, interval: 2, speed: 55)
        samples += highwaySamples(
            from: 840, to: 1_440, interval: 2, speed: 55,
            startLatitude: samples.last!.latitude + 0.118
        )
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 1_440, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 0)
        XCTAssertEqual(evidence.blackoutJumpCount, 1)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testTeleportingFixPairIsNotABlackoutJump() {
        // A 20 km position glitch between fixes one second apart is a bad fix,
        // not a dark stretch, even next to a genuine fast fix.
        let samples = [
            sample(at: 0, latitude: 40.80, longitude: -38.80, speed: 30, speedAccuracy: 1, accuracy: 5),
            sample(at: 1, latitude: 40.98, longitude: -38.80, speed: 142.6, speedAccuracy: 1.3, accuracy: 5),
            sample(at: 2, latitude: 40.80, longitude: -38.80, speed: 30, speedAccuracy: 1, accuracy: 5)
        ]
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 10, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 1)
        XCTAssertEqual(evidence.blackoutJumpCount, 0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testLooseSpeedAccuracyAndWeakFixesDoNotCount() {
        var samples = taxiSamples(from: 0, to: 600, interval: 2, around: (40.7773, -38.8756), speed: 2)
        // Fast fix with an untrustworthy speed error bar.
        samples.append(sample(at: 2_000, latitude: 41.0776, longitude: -44.3515, speed: 215.9, speedAccuracy: 25, accuracy: 5))
        // Fast fix with weak horizontal accuracy.
        samples.append(sample(at: 2_100, latitude: 41.2, longitude: -44.5, speed: 215.9, speedAccuracy: 2, accuracy: 300))
        // Fast fix with no speed accuracy at all.
        samples.append(sample(at: 2_200, latitude: 41.3, longitude: -44.6, speed: 215.9, speedAccuracy: nil, accuracy: 5))
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 2_400, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    func testSamplesOutsideTripWindowAreIgnored() {
        var samples = taxiSamples(from: 0, to: 600, interval: 2, around: (40.7773, -38.8756), speed: 2)
        samples.append(sample(at: 5_000, latitude: 41.0776, longitude: -44.3515, speed: 215.9, speedAccuracy: 2.7, accuracy: 5))
        let evidence = AircraftTripEvidence.extract(draft: makeDraft(duration: 1_000, samples: samples))
        XCTAssertEqual(evidence.aircraftSpeedSampleCount, 0)
        XCTAssertEqual(evidence.blackoutJumpCount, 0)
        XCTAssertEqual(classifier.verdict(for: evidence), .noMatch)
    }

    // MARK: - Helpers

    private func makeDraft(duration: TimeInterval, samples: [LocationSample]) -> TripDraft {
        TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            samples: samples,
            distanceMeters: 2_000
        )
    }

    private func sample(
        at offset: TimeInterval,
        latitude: Double,
        longitude: Double,
        speed: Double?,
        speedAccuracy: Double?,
        accuracy: Double
    ) -> LocationSample {
        LocationSample(
            timestamp: start.addingTimeInterval(offset),
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: accuracy,
            speedMetersPerSecond: speed,
            speedAccuracyMetersPerSecond: speedAccuracy,
            motionHint: .automotive
        )
    }

    /// Slow fixes drifting around one spot: gate, taxiway, or ramp.
    private func taxiSamples(
        from startOffset: TimeInterval,
        to endOffset: TimeInterval,
        interval: TimeInterval,
        around center: (Double, Double),
        speed: Double
    ) -> [LocationSample] {
        stride(from: startOffset, to: endOffset, by: interval).enumerated().map { index, offset in
            sample(
                at: offset,
                latitude: center.0 + Double(index % 20) * 0.00002,
                longitude: center.1,
                speed: speed,
                speedAccuracy: 1,
                accuracy: 4
            )
        }
    }

    /// Fixes moving north at a steady highway speed.
    private func highwaySamples(
        from startOffset: TimeInterval,
        to endOffset: TimeInterval,
        interval: TimeInterval,
        speed: Double = 32,
        startLatitude: Double = 41.0
    ) -> [LocationSample] {
        stride(from: startOffset, to: endOffset, by: interval).map { offset in
            let meters = (offset - startOffset) * speed
            return sample(
                at: offset,
                latitude: startLatitude + (meters / 6_371_000) * 180 / .pi,
                longitude: -38.9,
                speed: speed,
                speedAccuracy: 1,
                accuracy: 5
            )
        }
    }
}
