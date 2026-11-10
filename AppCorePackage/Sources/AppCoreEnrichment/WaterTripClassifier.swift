import AppCoreModels
import DriveCaptureEngine
import Foundation

/// The inexpensive, local evidence required before performing three water
/// reverse-geocoding lookups for a finished trip.
public struct WaterTripProbePlan: Equatable, Sendable {
    public var tripID: UUID
    public var usablePathDistanceMeters: Double
    /// Distinct recorded samples nearest 25%, 50%, and 75% of usable path
    /// distance, in that order.
    public var probeSamples: [LocationSample]

    public init(
        tripID: UUID,
        usablePathDistanceMeters: Double,
        probeSamples: [LocationSample]
    ) {
        self.tripID = tripID
        self.usablePathDistanceMeters = usablePathDistanceMeters
        self.probeSamples = probeSamples
    }
}

/// Pure, conservative preflight for water-based Not-a-Drive classification.
/// Map lookups and persistence remain the caller's responsibility.
///
/// CoreMotion can report a powerboat as `automotive` with high confidence,
/// so the preflight uses path geometry. MapKit can report the river beneath
/// a bridge, so `isWaterSurface` checks the thoroughfare at each probe. A
/// short bridge crossing can put two of the three probes over water.
public struct WaterTripClassifier: Sendable {
    public static let minimumUsablePathDistanceMeters = 804.672
    public static let probeFractions = [0.25, 0.5, 0.75]

    public init() {}

    /// Whether a reverse-geocoded probe lies on a water *surface*.
    ///
    /// Measured with `MKReverseGeocodingRequest` on 2026-10-25: the mid-span
    /// points of the Brooklyn, Manhattan, Williamsburg, George Washington,
    /// Whitestone, Throgs Neck, Tappan Zee, Verrazzano, Harvard, and Pell
    /// bridges and the Hugh Carey tunnel all come back with `inlandWater` or
    /// `ocean` set — and with the bridge or tunnel as the `thoroughfare`.
    /// Open water probes have an empty thoroughfare. A road snapped under
    /// the point means the phone was on that road, whatever lies beneath it.
    /// Use the structured MapKit fields to support all locales.
    public static func isWaterSurface(
        ocean: String?,
        inlandWater: String?,
        thoroughfare: String?
    ) -> Bool {
        let hasWaterBody = Self.nonEmpty(ocean) != nil || Self.nonEmpty(inlandWater) != nil
        return hasWaterBody && Self.nonEmpty(thoroughfare) == nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the three locations worth reverse geocoding, or `nil` when the
    /// recorded path is too short or too sparse to justify those lookups.
    public func probePlan(
        for trip: TripSummary,
        samples: [LocationSample]
    ) -> WaterTripProbePlan? {
        let maximumAccuracy = DriveCaptureConfiguration.automatic.maxHorizontalAccuracyMeters
        let usable = samples.enumerated()
            .filter { _, sample in
                sample.timestamp >= trip.startDate
                    && sample.timestamp <= trip.endDate
                    && sample.horizontalAccuracy.isFinite
                    && sample.horizontalAccuracy >= 0
                    && sample.horizontalAccuracy <= maximumAccuracy
                    && Self.hasValidCoordinate(sample)
            }
            .sorted { first, second in
                if first.element.timestamp == second.element.timestamp {
                    return first.offset < second.offset
                }
                return first.element.timestamp < second.element.timestamp
            }
            .map(\.element)

        guard usable.count >= Self.probeFractions.count else { return nil }

        var cumulativeDistances = [Double](repeating: 0, count: usable.count)
        for index in 1..<usable.count {
            let previous = usable[index - 1]
            let current = usable[index]
            let segmentDistance = DistanceCalculator.distanceMeters(
                from: Coordinate(latitude: previous.latitude, longitude: previous.longitude),
                to: Coordinate(latitude: current.latitude, longitude: current.longitude)
            )
            guard segmentDistance.isFinite else { return nil }
            cumulativeDistances[index] = cumulativeDistances[index - 1] + segmentDistance
        }

        guard let totalDistance = cumulativeDistances.last,
              totalDistance >= Self.minimumUsablePathDistanceMeters else {
            return nil
        }

        let probeIndexes = Self.probeFractions.map { fraction in
            let targetDistance = totalDistance * fraction
            return cumulativeDistances.indices.min { first, second in
                abs(cumulativeDistances[first] - targetDistance)
                    < abs(cumulativeDistances[second] - targetDistance)
            } ?? cumulativeDistances.startIndex
        }
        guard Set(probeIndexes).count == Self.probeFractions.count else { return nil }

        return WaterTripProbePlan(
            tripID: trip.id,
            usablePathDistanceMeters: totalDistance,
            probeSamples: probeIndexes.map { usable[$0] }
        )
    }

    /// The three reverse-geocoding requests must all resolve, and at least two
    /// of their structured results must identify ocean or inland water.
    public func isWaterTrip(resolvedWaterFlags: [Bool]) -> Bool {
        resolvedWaterFlags.count == Self.probeFractions.count
            && resolvedWaterFlags.filter { $0 }.count >= 2
    }

    private static func hasValidCoordinate(_ sample: LocationSample) -> Bool {
        sample.latitude.isFinite
            && sample.longitude.isFinite
            && (-90...90).contains(sample.latitude)
            && (-180...180).contains(sample.longitude)
    }
}
