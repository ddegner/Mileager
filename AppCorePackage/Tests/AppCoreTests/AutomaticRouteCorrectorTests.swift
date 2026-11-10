import XCTest
@testable import AppCore

@MainActor
final class AutomaticRouteFillerTests: XCTestCase {
    func testFillsRouteThroughGPSAnchorsInsteadOfEndpointOnly() async {
        let samples = zigZagSamples()
        let rawDistance = DistanceCalculator.routeDistanceMeters(samples: samples)
        let trip = tripSummary(samples: samples, distanceMeters: rawDistance)
        let resolver = RecordingDrivingRouteResolver { start, end in
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, midpoint(from: start, to: end), end]),
                distanceMeters: distance * 1.1
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(
            trip: trip,
            samples: samples
        )

        guard case .filled(let result) = decision else {
            return XCTFail("Expected route fill to succeed.")
        }
        XCTAssertEqual(result.anchorCount, samples.count)
        XCTAssertEqual(result.routedSegmentCount, samples.count - 1)
        XCTAssertEqual(result.fallbackSegmentCount, 0)
        XCTAssertTrue(result.useFilledDistance)
        XCTAssertEqual(resolver.calls.count, samples.count - 1)
        XCTAssertFalse(resolver.calls.contains { call in
            call.start == samples.first?.coordinate && call.end == samples.last?.coordinate
        })
    }

    func testImplausibleSegmentsFallBackToRawGPS() async {
        let samples = [
            sample(latitude: 40.0000, longitude: -74.0000, seconds: 0),
            sample(latitude: 40.0000, longitude: -73.9800, seconds: 240),
            sample(latitude: 40.0150, longitude: -73.9800, seconds: 480)
        ]
        let trip = tripSummary(samples: samples, distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples))
        var callCount = 0
        let resolver = RecordingDrivingRouteResolver { start, end in
            callCount += 1
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            if callCount == 1 {
                return ResolvedDrivingRoute(
                    startCoordinate: start,
                    endCoordinate: end,
                    routePolyline: EncodedPolyline.encode([start, end]),
                    distanceMeters: 100_000
                )
            }
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, midpoint(from: start, to: end), end]),
                distanceMeters: distance * 1.1
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(
            trip: trip,
            samples: samples
        )

        guard case .filled(let result) = decision else {
            return XCTFail("Expected partial route fill to produce a display route.")
        }
        XCTAssertEqual(result.routedSegmentCount, 1)
        XCTAssertEqual(result.fallbackSegmentCount, 1)
        XCTAssertFalse(result.useFilledDistance)
        XCTAssertEqual(result.attentionReason, AutomaticRouteFiller.lowConfidenceAttentionReason)
    }

    func testShortSegmentsUnderThirtyMetersDoNotCallResolver() async {
        let samples = [
            sample(latitude: 40.00000, longitude: -74.00000, seconds: 0),
            sample(latitude: 40.00018, longitude: -74.00000, seconds: 15),
            sample(latitude: 40.00018, longitude: -73.99950, seconds: 60)
        ]
        let trip = tripSummary(samples: samples, distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples))
        let resolver = RecordingDrivingRouteResolver { start, end in
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, midpoint(from: start, to: end), end]),
                distanceMeters: distance * 1.1
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(
            trip: trip,
            samples: samples
        )

        guard case .filled(let result) = decision else {
            return XCTFail("Expected the longer segment to produce a filled route.")
        }
        XCTAssertEqual(result.routedSegmentCount, 1)
        XCTAssertEqual(result.fallbackSegmentCount, 1)
        XCTAssertEqual(resolver.calls.count, 1)
        XCTAssertEqual(resolver.calls.first?.start, samples[1].coordinate)
        XCTAssertEqual(resolver.calls.first?.end, samples[2].coordinate)

        guard let routePolyline = result.route.routePolyline,
              let decoded = EncodedPolyline.decode(routePolyline) else {
            return XCTFail("Expected a display route.")
        }
        XCTAssertEqual(decoded.first, samples[0].coordinate)
        XCTAssertEqual(decoded.dropFirst().first, samples[1].coordinate)
    }

    func testSegmentsLongerThanThreeTimesStraightLineFallBackToRawGPS() async {
        let samples = [
            sample(latitude: 40.0000, longitude: -74.0000, seconds: 0),
            sample(latitude: 40.0000, longitude: -73.9990, seconds: 120),
            sample(latitude: 40.0010, longitude: -73.9990, seconds: 240)
        ]
        let trip = tripSummary(samples: samples, distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples))
        var callCount = 0
        let resolver = RecordingDrivingRouteResolver { start, end in
            callCount += 1
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, midpoint(from: start, to: end), end]),
                distanceMeters: callCount == 1 ? distance * 3.01 : distance * 1.1
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(
            trip: trip,
            samples: samples
        )

        guard case .filled(let result) = decision else {
            return XCTFail("Expected the plausible segment to produce a filled route.")
        }
        XCTAssertEqual(result.routedSegmentCount, 1)
        XCTAssertEqual(result.fallbackSegmentCount, 1)
        XCTAssertFalse(result.useFilledDistance)
        XCTAssertEqual(result.attentionReason, AutomaticRouteFiller.lowConfidenceAttentionReason)

        guard let routePolyline = result.route.routePolyline,
              let decoded = EncodedPolyline.decode(routePolyline) else {
            return XCTFail("Expected a display route.")
        }
        XCTAssertEqual(Array(decoded.prefix(2)), Array(samples.prefix(2).map(\.coordinate)))
    }

    func testAllTransientlyFailedSegmentsReturnRetryableFailure() async {
        let samples = zigZagSamples()
        let trip = tripSummary(samples: samples, distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples))
        let resolver = RecordingDrivingRouteResolver { _, _ in
            throw TestRouteError.failed
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(
            trip: trip,
            samples: samples
        )

        guard case .retryableFailure(_, let reason) = decision else {
            return XCTFail("Expected route fill to be skipped.")
        }
        XCTAssertTrue(reason.contains("did not complete"))
    }

    func testPerRequestTimeoutReturnsRetryableTimedOutFailure() async {
        let samples = zigZagSamples()
        let trip = tripSummary(
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        )
        let resolver = RecordingDrivingRouteResolver { _, _ in
            try await Task.sleep(for: .seconds(5))
            throw TestRouteError.failed
        }

        let decision = await AutomaticRouteFiller(
            resolver: resolver,
            requestTimeoutSeconds: 0.01,
            totalTimeoutSeconds: 1
        ).fill(trip: trip, samples: samples)

        guard case .retryableFailure(let category, _) = decision else {
            return XCTFail("Expected a retryable timeout, got \(decision).")
        }
        XCTAssertEqual(category, .timedOut)
    }

    func testTotalRouteBudgetReturnsRetryableTimedOutFailure() async {
        let samples = zigZagSamples()
        let trip = tripSummary(
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        )
        let resolver = RecordingDrivingRouteResolver { _, _ in
            try await Task.sleep(for: .seconds(5))
            throw TestRouteError.failed
        }

        let decision = await AutomaticRouteFiller(
            resolver: resolver,
            requestTimeoutSeconds: 1,
            totalTimeoutSeconds: 0.01
        ).fill(trip: trip, samples: samples)

        guard case .retryableFailure(let category, let reason) = decision else {
            return XCTFail("Expected the total route budget to time out, got \(decision).")
        }
        XCTAssertEqual(category, .timedOut)
        XCTAssertTrue(reason.contains("total time budget"))
    }

    func testCallerCancellationDoesNotBecomeFailureOrTerminalSkip() async {
        let samples = zigZagSamples()
        let trip = tripSummary(
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        )
        let resolver = RecordingDrivingRouteResolver { _, _ in
            try await Task.sleep(for: .seconds(5))
            throw TestRouteError.failed
        }
        let task = Task { @MainActor in
            await AutomaticRouteFiller(
                resolver: resolver,
                requestTimeoutSeconds: 1,
                totalTimeoutSeconds: 2
            ).fill(trip: trip, samples: samples)
        }

        await Task.yield()
        task.cancel()

        let decision = await task.value
        XCTAssertEqual(decision, .cancelled)
    }

    func testLowAccuracySamplesSkipRouteFilling() async {
        let samples = [
            sample(latitude: 40.0000, longitude: -74.0000, seconds: 0, horizontalAccuracy: 200),
            sample(latitude: 40.0100, longitude: -74.0000, seconds: 120, horizontalAccuracy: 200)
        ]
        let trip = tripSummary(samples: samples, distanceMeters: 1_000)
        let resolver = RecordingDrivingRouteResolver { start, end in
            ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, end]),
                distanceMeters: 1_000
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(
            trip: trip,
            samples: samples
        )

        guard case .terminalSkip(_, let reason) = decision else {
            return XCTFail("Expected low-accuracy samples to be skipped.")
        }
        XCTAssertTrue(reason.contains("Not enough reliable GPS samples"))
        XCTAssertTrue(resolver.calls.isEmpty)
    }

    // The imprecise cold-start fix after the parked anchor must be ignored so route-fill targets
    // the first *accurate* reading — routing to a position-biased early fix draws a real road path
    // to the wrong place (the "phantom through Union Square").
    func testIgnoresImpreciseColdStartFixWhenRouting() async {
        let samples = [
            sample(latitude: 40.0000, longitude: -74.0000, seconds: 0, horizontalAccuracy: 8),     // parked anchor
            sample(latitude: 40.0100, longitude: -73.9940, seconds: 110, horizontalAccuracy: 45),  // imprecise, east-biased
            sample(latitude: 40.0100, longitude: -74.0000, seconds: 130, horizontalAccuracy: 8),   // first accurate fix
            sample(latitude: 40.0100, longitude: -73.9850, seconds: 220, horizontalAccuracy: 8)     // east bend keeps the accurate fix as an anchor
        ]
        let trip = tripSummary(samples: samples, distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples))
        let resolver = RecordingDrivingRouteResolver { start, end in
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, midpoint(from: start, to: end), end]),
                distanceMeters: max(distance, 1) * 1.1
            )
        }

        _ = await AutomaticRouteFiller(resolver: resolver).fill(trip: trip, samples: samples)

        let imprecise = Coordinate(latitude: 40.0100, longitude: -73.9940)
        XCTAssertFalse(resolver.calls.isEmpty)
        XCTAssertFalse(resolver.calls.contains { $0.start == imprecise || $0.end == imprecise })
        XCTAssertEqual(resolver.calls.first?.start, Coordinate(latitude: 40.0000, longitude: -74.0000))
        XCTAssertEqual(resolver.calls.first?.end, Coordinate(latitude: 40.0100, longitude: -74.0000))
    }

    // MARK: - Parked-start (SLC late-wake) gap backfill

    /// End-to-end seam for the SLC fallback case: the reducer prepends the parked anchor as
    /// the trip origin (proved in DriveCaptureReducerTests
    /// .testParkedStartInferenceBackdatesWithinDisplacementBound), and the filler then
    /// road-routes the leading parked-anchor→first-fix segment so the ~1 km the late wake
    /// missed is merged into the trip distance rather than dropped.
    func testParkedStartGapIsRoadRoutedAndMergedThroughTheReducerSeam() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Parked anchor ~1.3 km southwest of where GPS first locks, two minutes earlier —
        // a normal delayed-lock drive whose start the SLC wake missed.
        let anchor = LocationSample(
            timestamp: start.addingTimeInterval(-120),
            latitude: 40.7050,
            longitude: -74.0090,
            horizontalAccuracy: 8,
            speedMetersPerSecond: 0,
            speedAccuracyMetersPerSecond: 0.5,
            motionHint: .stationary
        )
        var state = DriveCaptureState()
        state.vehicleParkingAnchor = anchor
        var reducer = DriveCaptureReducer(state: state)
        let context = TripDetectionContext(trustedBluetoothVehicleHint: true)

        func drivingSample(_ latitude: Double, _ longitude: Double, _ seconds: TimeInterval) -> LocationSample {
            LocationSample(
                timestamp: start.addingTimeInterval(seconds),
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 13.4,
                speedAccuracyMetersPerSecond: 0.5,
                motionHint: .automotive
            )
        }
        let drive = [
            drivingSample(40.7150, -74.0010, 0),    // first lock, ~1.3 km from the parked anchor
            drivingSample(40.7150, -73.9800, 120),  // east
            drivingSample(40.7300, -73.9800, 240),  // north
            drivingSample(40.7300, -73.9550, 360)   // east
        ]
        for fix in drive {
            _ = reducer.apply(.location(fix, receivedAt: fix.timestamp, context: context, options: .normal))
        }

        XCTAssertEqual(reducer.state.phase, .recording, "trusted-vehicle drive should begin recording")
        // The parked anchor is prepended as the origin sample and the start is backdated.
        XCTAssertEqual(try XCTUnwrap(reducer.state.samples.first).latitude, anchor.latitude, accuracy: 0.0001)
        XCTAssertLessThan(try XCTUnwrap(reducer.state.startedAt), start)

        let samples = reducer.state.samples
        let straightLineDistance = DistanceCalculator.routeDistanceMeters(samples: samples)
        let trip = tripSummary(samples: samples, distanceMeters: straightLineDistance)
        let resolver = RecordingDrivingRouteResolver { segStart, segEnd in
            let distance = DistanceCalculator.distanceMeters(from: segStart, to: segEnd)
            return ResolvedDrivingRoute(
                startCoordinate: segStart,
                endCoordinate: segEnd,
                routePolyline: EncodedPolyline.encode([segStart, midpoint(from: segStart, to: segEnd), segEnd]),
                distanceMeters: max(distance, 1) * 1.1
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(trip: trip, samples: samples)

        guard case .filled(let result) = decision else {
            return XCTFail("Expected the parked-start gap to road-route. Got \(decision).")
        }
        // The first routed segment starts at the parked anchor — the gap is recovered, not dropped.
        XCTAssertEqual(resolver.calls.first?.start, Coordinate(latitude: anchor.latitude, longitude: anchor.longitude))
        XCTAssertTrue(result.useFilledDistance)
        XCTAssertGreaterThan(result.route.distanceMeters, straightLineDistance)
    }

    /// Documents the deliberate limitation (no behavior change): when the parked-start gap is
    /// large relative to a short captured drive (`maxAnchorGap / rawDistance > 0.35`), the
    /// road-route upgrade is withheld and the straight-line floor is kept. Pins the gate so a
    /// future change to it is a conscious decision rather than a silent regression.
    func testShortDriveWithLargeStartGapKeepsStraightLineDistance() async {
        let samples = [
            sample(latitude: 40.7050, longitude: -74.0090, seconds: 0),    // origin
            sample(latitude: 40.7230, longitude: -74.0090, seconds: 120),  // ~2.0 km north — the large start gap
            sample(latitude: 40.7230, longitude: -73.9990, seconds: 240)   // ~0.85 km east — short remainder
        ]
        let straightLineDistance = DistanceCalculator.routeDistanceMeters(samples: samples)
        let trip = tripSummary(samples: samples, distanceMeters: straightLineDistance)
        let resolver = RecordingDrivingRouteResolver { segStart, segEnd in
            let distance = DistanceCalculator.distanceMeters(from: segStart, to: segEnd)
            return ResolvedDrivingRoute(
                startCoordinate: segStart,
                endCoordinate: segEnd,
                routePolyline: EncodedPolyline.encode([segStart, midpoint(from: segStart, to: segEnd), segEnd]),
                distanceMeters: max(distance, 1) * 1.1
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(trip: trip, samples: samples)

        guard case .filled(let result) = decision else {
            return XCTFail("Expected a filled decision carrying the low-confidence flag. Got \(decision).")
        }
        XCTAssertFalse(result.useFilledDistance, "large start gap on a short drive must keep straight-line distance")
        XCTAssertEqual(result.attentionReason, AutomaticRouteFiller.lowConfidenceAttentionReason)
    }

    func testLoopingRouteOutsideRawCorridorKeepsRawDistance() async {
        let samples = [
            sample(latitude: 40.0000, longitude: -74.0000, seconds: 0),
            sample(latitude: 40.0000, longitude: -73.9900, seconds: 120),
            sample(latitude: 40.0000, longitude: -73.9800, seconds: 240)
        ]
        let rawDistance = DistanceCalculator.routeDistanceMeters(samples: samples)
        let trip = tripSummary(samples: samples, distanceMeters: rawDistance)
        let resolver = RecordingDrivingRouteResolver { start, end in
            let straightLine = DistanceCalculator.distanceMeters(from: start, to: end)
            let loop = Coordinate(latitude: start.latitude + 0.0040, longitude: (start.longitude + end.longitude) / 2)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, loop, end]),
                distanceMeters: straightLine * 1.20
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(trip: trip, samples: samples)

        guard case .filled(let result) = decision else {
            return XCTFail("Expected a filled route decision.")
        }
        XCTAssertFalse(result.useFilledDistance)
        XCTAssertEqual(result.attentionReason, AutomaticRouteFiller.lowConfidenceAttentionReason)
        XCTAssertGreaterThan(try XCTUnwrap(result.routeRawRatio), 1.12)
        XCTAssertGreaterThan(try XCTUnwrap(result.corridorMaxMeters), 150)
    }

    func testInflatedButCorridorAlignedRouteKeepsFilledDistance() async {
        let samples = zigZagSamples()
        let rawDistance = DistanceCalculator.routeDistanceMeters(samples: samples)
        let trip = tripSummary(samples: samples, distanceMeters: rawDistance)
        let resolver = RecordingDrivingRouteResolver { start, end in
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, midpoint(from: start, to: end), end]),
                distanceMeters: distance * 1.20
            )
        }

        let decision = await AutomaticRouteFiller(resolver: resolver).fill(trip: trip, samples: samples)

        guard case .filled(let result) = decision else {
            return XCTFail("Expected a filled route decision.")
        }
        XCTAssertTrue(result.useFilledDistance)
        XCTAssertNil(result.attentionReason)
        XCTAssertGreaterThan(try XCTUnwrap(result.routeRawRatio), 1.12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.corridorMaxMeters), 1)
    }

    private func tripSummary(samples: [LocationSample], distanceMeters: Double) -> TripSummary {
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let durationSeconds = samples.last?.timestamp.timeIntervalSince(samples.first?.timestamp ?? startDate) ?? 1
        return TripSummary(
            id: UUID(),
            createdAt: startDate,
            updatedAt: startDate,
            captureSource: "automatic",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(durationSeconds),
            startCoordinate: samples.first?.coordinate,
            endCoordinate: samples.last?.coordinate,
            startAddress: nil,
            endAddress: nil,
            distanceMeters: distanceMeters,
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

    private func zigZagSamples() -> [LocationSample] {
        [
            sample(latitude: 40.0000, longitude: -74.0000, seconds: 0),
            sample(latitude: 40.0000, longitude: -73.9800, seconds: 240),
            sample(latitude: 40.0150, longitude: -73.9800, seconds: 480),
            sample(latitude: 40.0150, longitude: -73.9600, seconds: 720)
        ]
    }

    private func sample(
        latitude: Double,
        longitude: Double,
        seconds: TimeInterval,
        horizontalAccuracy: Double = 10
    ) -> LocationSample {
        LocationSample(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            speedMetersPerSecond: 10,
            speedAccuracyMetersPerSecond: 0.5,
            motionHint: .automotive
        )
    }
}

private final class RecordingDrivingRouteResolver: DrivingRouteResolving {
    var calls: [(start: Coordinate, end: Coordinate)] = []
    private let resolve: (Coordinate, Coordinate) async throws -> ResolvedDrivingRoute

    init(resolve: @escaping (Coordinate, Coordinate) async throws -> ResolvedDrivingRoute) {
        self.resolve = resolve
    }

    func resolveDrivingRoute(start: Coordinate, end: Coordinate) async throws -> ResolvedDrivingRoute {
        calls.append((start, end))
        return try await resolve(start, end)
    }
}

private enum TestRouteError: Error {
    case failed
}

private func midpoint(from start: Coordinate, to end: Coordinate) -> Coordinate {
    Coordinate(
        latitude: (start.latitude + end.latitude) / 2,
        longitude: (start.longitude + end.longitude) / 2
    )
}

private extension LocationSample {
    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }
}
