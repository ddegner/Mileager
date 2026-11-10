import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import Foundation

public struct ResolvedDrivingRoute: Equatable, Sendable {
    public var startCoordinate: Coordinate
    public var endCoordinate: Coordinate
    public var routePolyline: String?
    public var distanceMeters: Double

    public init(
        startCoordinate: Coordinate,
        endCoordinate: Coordinate,
        routePolyline: String?,
        distanceMeters: Double
    ) {
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.routePolyline = routePolyline
        self.distanceMeters = distanceMeters
    }
}

public enum AutomaticRouteFillDecision: Equatable, Sendable {
    case filled(AutomaticRouteFillResult)
    case retryableFailure(category: TripEnrichmentFailureCategory, reason: String)
    case terminalSkip(category: TripEnrichmentFailureCategory, reason: String)
    case cancelled
}

public struct AutomaticRouteFillResult: Equatable, Sendable {
    public var route: ResolvedDrivingRoute
    public var rawDistanceMeters: Double
    public var routeRawRatio: Double?
    public var corridorP95Meters: Double?
    public var corridorMaxMeters: Double?
    public var useFilledDistance: Bool
    public var attentionReason: String?
    public var anchorCount: Int
    public var routedSegmentCount: Int
    public var fallbackSegmentCount: Int
    public var fallbackDistanceMeters: Double
    public var maxAnchorGapMeters: Double

    public init(
        route: ResolvedDrivingRoute,
        rawDistanceMeters: Double,
        routeRawRatio: Double? = nil,
        corridorP95Meters: Double? = nil,
        corridorMaxMeters: Double? = nil,
        useFilledDistance: Bool,
        attentionReason: String?,
        anchorCount: Int,
        routedSegmentCount: Int,
        fallbackSegmentCount: Int,
        fallbackDistanceMeters: Double,
        maxAnchorGapMeters: Double
    ) {
        self.route = route
        self.rawDistanceMeters = rawDistanceMeters
        self.routeRawRatio = routeRawRatio
        self.corridorP95Meters = corridorP95Meters
        self.corridorMaxMeters = corridorMaxMeters
        self.useFilledDistance = useFilledDistance
        self.attentionReason = attentionReason
        self.anchorCount = anchorCount
        self.routedSegmentCount = routedSegmentCount
        self.fallbackSegmentCount = fallbackSegmentCount
        self.fallbackDistanceMeters = fallbackDistanceMeters
        self.maxAnchorGapMeters = maxAnchorGapMeters
    }
}

@MainActor
public protocol DrivingRouteResolving {
    func resolveDrivingRoute(start: Coordinate, end: Coordinate) async throws -> ResolvedDrivingRoute
}

@MainActor
public struct AutomaticRouteFiller {
    public nonisolated static let lowConfidenceAttentionReason = "Route fill had low confidence."

    private let resolver: any DrivingRouteResolving
    private let requestTimeoutSeconds: TimeInterval
    private let totalTimeoutSeconds: TimeInterval
    private let maximumAnchorCount = 40
    private let minimumRoutedSegmentRatio = 0.70
    private let maximumFallbackDistanceRatio = 0.20
    private let maximumAnchorGapRatio = 0.35
    private let minimumFilledToRawDistanceRatio = 0.65
    private let maximumFilledToRawDistanceRatio = 1.60
    private let suspiciousRouteRawRatio = 1.12
    private let suspiciousCorridorP95Meters = 40.0
    private let suspiciousCorridorMaxMeters = 120.0
    private let minimumRoutableSegmentMeters = 30.0
    private static let maximumRoutedSegmentExpansion = 3.0
    /// Cold-start GPS fixes after a drive begins are imprecise and position-biased. Ignore the
    /// leading run worse than this so the first routed segment targets the first *accurate*
    /// reading — routing to a biased early fix draws a real road path to the wrong place.
    private let leadingAccuracyCeilingMeters = 25.0

    public init(
        resolver: any DrivingRouteResolving,
        requestTimeoutSeconds: TimeInterval = 15,
        totalTimeoutSeconds: TimeInterval = 60
    ) {
        self.resolver = resolver
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.totalTimeoutSeconds = totalTimeoutSeconds
    }

    public func fill(
        trip: TripSummary,
        samples: [LocationSample]
    ) async -> AutomaticRouteFillDecision {
        do {
            return try await withTripEnrichmentTimeout(seconds: totalTimeoutSeconds) { [self] in
                await fillWithinTotalBudget(trip: trip, samples: samples)
            }
        } catch {
            let category = TripEnrichmentFailureClassifier.category(for: error)
            if Task.isCancelled || category == .cancelled {
                return .cancelled
            }
            return .retryableFailure(
                category: category,
                reason: "Automatic route fill exceeded its total time budget."
            )
        }
    }

    private func fillWithinTotalBudget(
        trip: TripSummary,
        samples: [LocationSample]
    ) async -> AutomaticRouteFillDecision {
        guard trip.captureSource == "automatic" else {
            return .terminalSkip(category: .invalidInput, reason: "Trip is not automatic.")
        }

        let configuration = DriveCaptureConfiguration.automatic
        let usableSamples = samples
            .filter { sample in
                Coordinate(latitude: sample.latitude, longitude: sample.longitude).isValid &&
                    sample.horizontalAccuracy.isFinite &&
                    sample.horizontalAccuracy >= 0 &&
                    sample.horizontalAccuracy <= configuration.maxHorizontalAccuracyMeters
            }
            .sorted { $0.timestamp < $1.timestamp }

        guard usableSamples.count >= 2 else {
            return .terminalSkip(category: .missingSamples, reason: "Not enough reliable GPS samples.")
        }

        // Ignore imprecise cold-start fixes so the first routed segment targets the first
        // *accurate* reading rather than a position-biased early fix (which routes a real road
        // path to the wrong place — the "phantom through Union Square").
        let routeSamples = Self.ignoringImpreciseStartFixes(usableSamples, ceilingMeters: leadingAccuracyCeilingMeters)
        let anchors = Self.simplifiedAnchors(
            routeSamples,
            toleranceMeters: configuration.routeSimplificationToleranceMeters
        )
        guard anchors.count >= 2 else {
            return .terminalSkip(category: .missingSamples, reason: "Not enough route anchors.")
        }
        guard anchors.count <= maximumAnchorCount else {
            return .terminalSkip(category: .invalidInput, reason: "Too many route anchors: \(anchors.count).")
        }

        var stitchedCoordinates: [Coordinate] = []
        var filledDistanceMeters = 0.0
        var fallbackDistanceMeters = 0.0
        var maxAnchorGapMeters = 0.0
        var routedSegmentCount = 0
        var fallbackSegmentCount = 0
        let segmentCount = anchors.count - 1

        for (startSample, endSample) in zip(anchors, anchors.dropFirst()) {
            let start = startSample.coordinate
            let end = endSample.coordinate
            let straightLineDistance = DistanceCalculator.distanceMeters(from: start, to: end)
            maxAnchorGapMeters = max(maxAnchorGapMeters, straightLineDistance)

            if straightLineDistance < minimumRoutableSegmentMeters {
                Self.appendSegment([start, end], to: &stitchedCoordinates)
                filledDistanceMeters += straightLineDistance
                fallbackDistanceMeters += straightLineDistance
                fallbackSegmentCount += 1
                continue
            }

            do {
                let route = try await withTripEnrichmentTimeout(seconds: requestTimeoutSeconds) { [resolver] in
                    try await resolver.resolveDrivingRoute(start: start, end: end)
                }
                if Self.isPlausible(
                    route: route,
                    from: startSample,
                    to: endSample,
                    straightLineDistance: straightLineDistance,
                    maximumSegmentSpeed: configuration.maxSegmentSpeedMetersPerSecond
                ),
                   let routePolyline = route.routePolyline,
                   let decodedRoute = EncodedPolyline.decode(routePolyline),
                   decodedRoute.count >= 2 {
                    Self.appendSegment(decodedRoute, to: &stitchedCoordinates)
                    filledDistanceMeters += route.distanceMeters
                    routedSegmentCount += 1
                } else {
                    Self.appendSegment([start, end], to: &stitchedCoordinates)
                    filledDistanceMeters += straightLineDistance
                    fallbackDistanceMeters += straightLineDistance
                    fallbackSegmentCount += 1
                }
            } catch {
                let category = TripEnrichmentFailureClassifier.category(for: error)
                if Task.isCancelled || category == .cancelled {
                    return .cancelled
                }
                guard TripEnrichmentFailureClassifier.isTerminal(category) else {
                    return .retryableFailure(
                        category: category,
                        reason: "A driving-route request did not complete."
                    )
                }
                Self.appendSegment([start, end], to: &stitchedCoordinates)
                filledDistanceMeters += straightLineDistance
                fallbackDistanceMeters += straightLineDistance
                fallbackSegmentCount += 1
            }
        }

        guard routedSegmentCount > 0 else {
            return .terminalSkip(category: .invalidInput, reason: "No route-filled segments were accepted.")
        }
        guard stitchedCoordinates.count >= 2 else {
            return .terminalSkip(category: .invalidInput, reason: "Filled route had no drawable shape.")
        }

        let rawDistanceMeters = trip.distanceMeters > 0
            ? trip.distanceMeters
            : DistanceCalculator.routeDistanceMeters(
                samples: usableSamples,
                maxAccuracy: configuration.maxHorizontalAccuracyMeters,
                maxSegmentSpeedMetersPerSecond: configuration.maxSegmentSpeedMetersPerSecond
            )
        let baseUseFilledDistance = Self.shouldUseFilledDistance(
            filledDistanceMeters: filledDistanceMeters,
            rawDistanceMeters: rawDistanceMeters,
            segmentCount: segmentCount,
            routedSegmentCount: routedSegmentCount,
            fallbackDistanceMeters: fallbackDistanceMeters,
            maxAnchorGapMeters: maxAnchorGapMeters,
            minimumRoutedSegmentRatio: minimumRoutedSegmentRatio,
            maximumFallbackDistanceRatio: maximumFallbackDistanceRatio,
            maximumAnchorGapRatio: maximumAnchorGapRatio,
            minimumFilledToRawDistanceRatio: minimumFilledToRawDistanceRatio,
            maximumFilledToRawDistanceRatio: maximumFilledToRawDistanceRatio
        )
        let routeRawRatio = Self.routeRawRatio(
            filledDistanceMeters: filledDistanceMeters,
            rawDistanceMeters: rawDistanceMeters
        )
        let corridorMetrics = Self.corridorDeviationMetrics(
            routeCoordinates: stitchedCoordinates,
            rawSamples: usableSamples
        )
        let suspiciousCorridor = Self.hasSuspiciousCorridorDeviation(
            routeRawRatio: routeRawRatio,
            corridorMetrics: corridorMetrics,
            minimumRouteRawRatio: suspiciousRouteRawRatio,
            maximumP95Meters: suspiciousCorridorP95Meters,
            maximumMaxMeters: suspiciousCorridorMaxMeters
        )
        let useFilledDistance = baseUseFilledDistance && !suspiciousCorridor
        let route = ResolvedDrivingRoute(
            startCoordinate: anchors[0].coordinate,
            endCoordinate: anchors[anchors.count - 1].coordinate,
            routePolyline: EncodedPolyline.encode(stitchedCoordinates),
            distanceMeters: filledDistanceMeters
        )

        return .filled(AutomaticRouteFillResult(
            route: route,
            rawDistanceMeters: rawDistanceMeters,
            routeRawRatio: routeRawRatio,
            corridorP95Meters: corridorMetrics?.p95Meters,
            corridorMaxMeters: corridorMetrics?.maxMeters,
            useFilledDistance: useFilledDistance,
            attentionReason: useFilledDistance ? nil : Self.lowConfidenceAttentionReason,
            anchorCount: anchors.count,
            routedSegmentCount: routedSegmentCount,
            fallbackSegmentCount: fallbackSegmentCount,
            fallbackDistanceMeters: fallbackDistanceMeters,
            maxAnchorGapMeters: maxAnchorGapMeters
        ))
    }

    private static func isPlausible(
        route: ResolvedDrivingRoute,
        from startSample: LocationSample,
        to endSample: LocationSample,
        straightLineDistance: Double,
        maximumSegmentSpeed: Double
    ) -> Bool {
        guard let routePolyline = route.routePolyline,
              let decodedRoute = EncodedPolyline.decode(routePolyline),
              decodedRoute.count >= 2 else {
            return false
        }
        guard route.distanceMeters.isFinite, route.distanceMeters > 0 else {
            return false
        }

        let minimumDistance = max(straightLineDistance * 0.85, minimumPositiveRouteDistance(straightLineDistance))
        guard route.distanceMeters >= minimumDistance else {
            return false
        }

        let maximumDistance = straightLineDistance * Self.maximumRoutedSegmentExpansion
        guard route.distanceMeters <= maximumDistance else {
            return false
        }

        let elapsed = max(endSample.timestamp.timeIntervalSince(startSample.timestamp), 1)
        return route.distanceMeters / elapsed <= maximumSegmentSpeed
    }

    private static func minimumPositiveRouteDistance(_ straightLineDistance: Double) -> Double {
        straightLineDistance < 50 ? 1 : 10
    }

    private static func shouldUseFilledDistance(
        filledDistanceMeters: Double,
        rawDistanceMeters: Double,
        segmentCount: Int,
        routedSegmentCount: Int,
        fallbackDistanceMeters: Double,
        maxAnchorGapMeters: Double,
        minimumRoutedSegmentRatio: Double,
        maximumFallbackDistanceRatio: Double,
        maximumAnchorGapRatio: Double,
        minimumFilledToRawDistanceRatio: Double,
        maximumFilledToRawDistanceRatio: Double
    ) -> Bool {
        guard filledDistanceMeters.isFinite,
              filledDistanceMeters > 0,
              rawDistanceMeters.isFinite,
              rawDistanceMeters > 0,
              segmentCount > 0 else {
            return false
        }

        let routedRatio = Double(routedSegmentCount) / Double(segmentCount)
        let fallbackRatio = fallbackDistanceMeters / filledDistanceMeters
        let maxGapRatio = maxAnchorGapMeters / rawDistanceMeters
        let distanceRatio = filledDistanceMeters / rawDistanceMeters

        return routedRatio >= minimumRoutedSegmentRatio &&
            fallbackRatio <= maximumFallbackDistanceRatio &&
            maxGapRatio <= maximumAnchorGapRatio &&
            distanceRatio >= minimumFilledToRawDistanceRatio &&
            distanceRatio <= maximumFilledToRawDistanceRatio
    }

    private static func routeRawRatio(filledDistanceMeters: Double, rawDistanceMeters: Double) -> Double? {
        guard filledDistanceMeters.isFinite,
              rawDistanceMeters.isFinite,
              rawDistanceMeters > 0 else {
            return nil
        }
        return filledDistanceMeters / rawDistanceMeters
    }

    private static func hasSuspiciousCorridorDeviation(
        routeRawRatio: Double?,
        corridorMetrics: (p95Meters: Double, maxMeters: Double)?,
        minimumRouteRawRatio: Double,
        maximumP95Meters: Double,
        maximumMaxMeters: Double
    ) -> Bool {
        guard let routeRawRatio,
              let corridorMetrics,
              routeRawRatio >= minimumRouteRawRatio else {
            return false
        }
        return corridorMetrics.p95Meters > maximumP95Meters ||
            corridorMetrics.maxMeters > maximumMaxMeters
    }

    private static func corridorDeviationMetrics(
        routeCoordinates: [Coordinate],
        rawSamples: [LocationSample]
    ) -> (p95Meters: Double, maxMeters: Double)? {
        let rawCoordinates = rawSamples.map(\.coordinate)
        guard routeCoordinates.count >= 2,
              rawCoordinates.count >= 2 else {
            return nil
        }
        let deviations = routeCoordinates
            .map { coordinate in
                nearestDistance(from: coordinate, toPolyline: rawCoordinates)
            }
            .filter { $0.isFinite }
            .sorted()
        guard let maxDeviation = deviations.last else { return nil }
        let p95Index = min(
            deviations.count - 1,
            max(0, Int(ceil(Double(deviations.count) * 0.95)) - 1)
        )
        return (deviations[p95Index], maxDeviation)
    }

    private static func nearestDistance(from point: Coordinate, toPolyline polyline: [Coordinate]) -> Double {
        zip(polyline, polyline.dropFirst())
            .map { start, end in
                distance(from: point, toSegmentStart: start, end: end)
            }
            .min() ?? .infinity
    }

    private static func distance(from point: Coordinate, toSegmentStart start: Coordinate, end: Coordinate) -> Double {
        let referenceLatitude = ((point.latitude + start.latitude + end.latitude) / 3) * .pi / 180
        let metersPerDegreeLatitude = 111_132.0
        let metersPerDegreeLongitude = max(cos(referenceLatitude) * 111_320.0, 0.000_001)
        let referenceLongitude = point.longitude
        let referenceLatitudeDegrees = point.latitude

        func project(_ coordinate: Coordinate) -> (x: Double, y: Double) {
            (
                x: (coordinate.longitude - referenceLongitude) * metersPerDegreeLongitude,
                y: (coordinate.latitude - referenceLatitudeDegrees) * metersPerDegreeLatitude
            )
        }

        let p = project(point)
        let a = project(start)
        let b = project(end)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let segmentLengthSquared = dx * dx + dy * dy
        guard segmentLengthSquared > 0 else {
            return DistanceCalculator.distanceMeters(from: point, to: start)
        }

        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / segmentLengthSquared))
        let closestX = a.x + t * dx
        let closestY = a.y + t * dy
        return hypot(p.x - closestX, p.y - closestY)
    }

    /// Ignores imprecise cold-start GPS fixes so routing targets the first *accurate* reading.
    /// The first sample (the trip-start / parked anchor — the known origin) is kept; then the
    /// contiguous leading run of fixes worse than `ceilingMeters` is dropped until accuracy
    /// converges. Mid-drive fixes are untouched — only the leading settling run is removed.
    static func ignoringImpreciseStartFixes(_ samples: [LocationSample], ceilingMeters: Double) -> [LocationSample] {
        guard let first = samples.first else { return samples }
        var result = [first]
        var settling = true
        for sample in samples.dropFirst() {
            if settling, sample.horizontalAccuracy > ceilingMeters { continue }
            settling = false
            result.append(sample)
        }
        return result
    }

    private static func simplifiedAnchors(_ samples: [LocationSample], toleranceMeters: Double) -> [LocationSample] {
        guard samples.count > 2 else { return samples }

        var maxDistance = 0.0
        var index = 0
        let first = samples[0].coordinate
        let last = samples[samples.count - 1].coordinate
        for sampleIndex in 1..<(samples.count - 1) {
            let distance = DistanceCalculator.perpendicularDistanceMeters(
                from: samples[sampleIndex].coordinate,
                toSegmentFrom: first,
                to: last
            )
            if distance > maxDistance {
                index = sampleIndex
                maxDistance = distance
            }
        }

        if maxDistance > toleranceMeters {
            let left = simplifiedAnchors(Array(samples[0...index]), toleranceMeters: toleranceMeters)
            let right = simplifiedAnchors(Array(samples[index...]), toleranceMeters: toleranceMeters)
            return Array(left.dropLast()) + right
        }

        return [samples[0], samples[samples.count - 1]]
    }

    private static func appendSegment(_ coordinates: [Coordinate], to stitchedCoordinates: inout [Coordinate]) {
        guard !coordinates.isEmpty else { return }
        if stitchedCoordinates.isEmpty {
            stitchedCoordinates.append(contentsOf: coordinates)
        } else {
            stitchedCoordinates.append(contentsOf: coordinates.dropFirst())
        }
    }
}

private extension LocationSample {
    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }
}

private extension Coordinate {
    var isValid: Bool {
        latitude.isFinite &&
            longitude.isFinite &&
            (-90...90).contains(latitude) &&
            (-180...180).contains(longitude)
    }
}
