import AppCoreEnrichment
import AppCoreModels
import XCTest

final class WaterTripClassifierTests: XCTestCase {
    private let classifier = WaterTripClassifier()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlanProducesDistinctQuarterPathProbes() throws {
        let samples = routeSamples(count: 9, spacingMeters: 150)

        let plan = try XCTUnwrap(classifier.probePlan(for: trip(for: samples), samples: samples))

        XCTAssertEqual(plan.usablePathDistanceMeters, 1_200, accuracy: 1)
        XCTAssertEqual(plan.probeSamples.map(\.timestamp), [samples[2], samples[4], samples[6]].map(\.timestamp))
    }

    func testPowerboatLabeledAutomotiveStillPlans() throws {
        // CoreMotion can label a powerboat as automotive with high confidence.
        let samples = routeSamples(count: 100, spacingMeters: 12, automotive: true)

        XCTAssertNotNil(classifier.probePlan(for: trip(for: samples), samples: samples))
    }

    func testMissingMotionDataDoesNotAbstain() throws {
        let samples = routeSamples(count: 10, spacingMeters: 120, motionCovered: false)

        XCTAssertNotNil(classifier.probePlan(for: trip(for: samples), samples: samples))
    }

    func testShortPathRejects() {
        let samples = routeSamples(count: 8, spacingMeters: 100)

        XCTAssertNil(classifier.probePlan(for: trip(for: samples), samples: samples))
    }

    func testFewerThanThreeUsableSamplesRejects() {
        let samples = routeSamples(count: 2, spacingMeters: 1_000)

        XCTAssertNil(classifier.probePlan(for: trip(for: samples), samples: samples))
    }

    func testDominantSegmentDoesNotVetoOtherwiseEligibleTrip() throws {
        // The first segment is two thirds of the path, mirroring a GPS
        // re-acquisition jump. It remains evidence; no segment-size veto exists.
        let samples = samples(atMetersNorth: [0, 800, 900, 1_000, 1_100, 1_200])

        let plan = try XCTUnwrap(classifier.probePlan(for: trip(for: samples), samples: samples))

        XCTAssertEqual(plan.probeSamples.map(\.timestamp), [samples[0], samples[1], samples[2]].map(\.timestamp))
    }

    func testDuplicateNearestProbeRejects() {
        // The long middle segment makes the 50% and 75% targets resolve to the
        // same recorded sample. The classifier does not invent coordinates.
        let samples = samples(atMetersNorth: [0, 100, 900, 1_000, 1_100])

        XCTAssertNil(classifier.probePlan(for: trip(for: samples), samples: samples))
    }

    func testAccuracyGateReusesAutomaticCaptureCeiling() throws {
        var samples = routeSamples(count: 9, spacingMeters: 150)
        samples[4].horizontalAccuracy = 65

        XCTAssertNotNil(classifier.probePlan(for: trip(for: samples), samples: samples))

        samples[4].horizontalAccuracy = 65.01
        let plan = try XCTUnwrap(classifier.probePlan(for: trip(for: samples), samples: samples))
        XCTAssertFalse(plan.probeSamples.contains { $0.timestamp == samples[4].timestamp })
    }

    func testTwoOfThreeResolvedWaterFlagsPass() {
        XCTAssertTrue(classifier.isWaterTrip(resolvedWaterFlags: [true, false, true]))
        XCTAssertTrue(classifier.isWaterTrip(resolvedWaterFlags: [true, true, true]))
    }

    func testIncompleteOrOneOfThreeWaterFlagsFail() {
        XCTAssertFalse(classifier.isWaterTrip(resolvedWaterFlags: [true, false]))
        XCTAssertFalse(classifier.isWaterTrip(resolvedWaterFlags: [true, false, false]))
        XCTAssertFalse(classifier.isWaterTrip(resolvedWaterFlags: [true, true, false, false]))
    }

    func testOpenWaterProbesAreWaterSurfaces() {
        XCTAssertTrue(WaterTripClassifier.isWaterSurface(
            ocean: "", inlandWater: "Example Lake", thoroughfare: nil
        ))
        XCTAssertTrue(WaterTripClassifier.isWaterSurface(
            ocean: "North Atlantic Ocean", inlandWater: nil, thoroughfare: ""
        ))
        XCTAssertTrue(WaterTripClassifier.isWaterSurface(
            ocean: nil, inlandWater: "Example Lake", thoroughfare: "   "
        ))
    }

    // Mid-span probes can report the river beneath a crossing and the
    // bridge or tunnel as the thoroughfare.
    func testBridgeAndTunnelProbesAreNotWaterSurfaces() {
        let crossings: [(ocean: String?, inland: String?, road: String)] = [
            ("East River", "East River", "Brooklyn Bridge"),
            ("East River", "East River", "Manhattan Bridge"),
            ("", "Hudson River", "George Washington Bridge S"),
            ("", "Hudson River", "Gov Mario M Cuomo Bridge"),
            ("East River", "East River", "Throgs Neck Bridge"),
            ("", "The Narrows", "Verrazzano-Narrows Bridge"),
            ("", "Charles River", "Harvard Bridge"),
            ("North Atlantic Ocean", "", "Claiborne Pell Newport Bridge"),
            ("", "Upper New York Bay", "Hugh L Carey Tunnel")
        ]
        for crossing in crossings {
            XCTAssertFalse(
                WaterTripClassifier.isWaterSurface(
                    ocean: crossing.ocean,
                    inlandWater: crossing.inland,
                    thoroughfare: crossing.road
                ),
                crossing.road
            )
        }
    }

    // A probe snapped to a shoreline address can still name the lake.
    func testShorelineAddressProbeIsNotAWaterSurface() {
        XCTAssertFalse(WaterTripClassifier.isWaterSurface(
            ocean: nil, inlandWater: "Example Lake", thoroughfare: "Lakeside Road"
        ))
    }

    func testDryLandIsNeverAWaterSurface() {
        XCTAssertFalse(WaterTripClassifier.isWaterSurface(ocean: nil, inlandWater: nil, thoroughfare: nil))
        XCTAssertFalse(WaterTripClassifier.isWaterSurface(ocean: "", inlandWater: " ", thoroughfare: nil))
        XCTAssertFalse(WaterTripClassifier.isWaterSurface(ocean: nil, inlandWater: nil, thoroughfare: "Western Ave"))
    }

    // MARK: - Helpers

    private func routeSamples(
        count: Int,
        spacingMeters: Double,
        automotive: Bool = false,
        motionCovered: Bool = true
    ) -> [LocationSample] {
        (0..<count).map { index in
            sample(
                metersNorth: Double(index) * spacingMeters,
                seconds: Double(index),
                motionCovered: motionCovered,
                automotive: automotive
            )
        }
    }

    private func samples(atMetersNorth distances: [Double]) -> [LocationSample] {
        distances.enumerated().map { index, distance in
            sample(
                metersNorth: distance,
                seconds: Double(index),
                motionCovered: true,
                automotive: false
            )
        }
    }

    private func sample(
        metersNorth: Double,
        seconds: TimeInterval,
        motionCovered: Bool,
        automotive: Bool
    ) -> LocationSample {
        let hint: MotionHint = automotive ? .automotive : .unknown
        let activity = motionCovered
            ? MotionActivitySnapshot(
                startDate: start.addingTimeInterval(seconds),
                confidence: .high,
                hints: [hint]
            )
            : nil
        return LocationSample(
            timestamp: start.addingTimeInterval(seconds),
            latitude: 40 + metersNorth / 111_111,
            longitude: -74,
            horizontalAccuracy: 10,
            motionHint: hint,
            motionActivity: activity
        )
    }

    private func trip(for samples: [LocationSample]) -> TripSummary {
        let first = samples.map(\.timestamp).min() ?? start
        let last = samples.map(\.timestamp).max() ?? start.addingTimeInterval(1)
        return TripSummary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042") ?? UUID(),
            createdAt: first,
            updatedAt: first,
            captureSource: "automatic",
            startDate: first,
            endDate: last,
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: nil,
            endAddress: nil,
            distanceMeters: 0,
            routePolyline: nil,
            classification: nil,
            reviewStatus: .needsReview,
            businessPurpose: nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
    }
}
