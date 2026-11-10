import AppCoreModels
import Foundation

/// Whole-trip speed evidence extracted from a finished draft. A flight leaves
/// a signature no road vehicle reproduces: fixes whose reported speed is far
/// above anything a car does, usually bracketed by a GPS blackout in which the
/// device re-emerged tens of kilometers away.
///
/// A cruise fix at 216 m/s after a long GPS blackout is strong evidence of
/// flight. A takeoff roll that accelerates smoothly from 40 to 59 m/s can
/// resemble a fast road vehicle and stays below the classifier's speed floor.
public struct AircraftTripEvidence: Equatable, Sendable {
    /// Usable in-trip fixes reporting at least
    /// `AircraftTripClassifier.aircraftSpeedFloorMetersPerSecond` with a
    /// trustworthy speed accuracy.
    public var aircraftSpeedSampleCount: Int
    /// Consecutive usable fixes separated by at least a minute whose
    /// straight-line displacement and implied speed both exceed the blackout
    /// thresholds: the device traveled a long way, fast, while GPS was dark.
    public var blackoutJumpCount: Int
    public var peakReportedSpeedMetersPerSecond: Double
    public var longestBlackoutDisplacementMeters: Double

    public init(
        aircraftSpeedSampleCount: Int,
        blackoutJumpCount: Int,
        peakReportedSpeedMetersPerSecond: Double,
        longestBlackoutDisplacementMeters: Double
    ) {
        self.aircraftSpeedSampleCount = aircraftSpeedSampleCount
        self.blackoutJumpCount = blackoutJumpCount
        self.peakReportedSpeedMetersPerSecond = peakReportedSpeedMetersPerSecond
        self.longestBlackoutDisplacementMeters = longestBlackoutDisplacementMeters
    }

    /// Samples outside `[draft.startDate, draft.endDate]`, with invalid
    /// coordinates, or with weak horizontal accuracy are ignored.
    public static func extract(draft: TripDraft) -> AircraftTripEvidence {
        let usable = draft.samples
            .filter { sample in
                sample.timestamp >= draft.startDate
                    && sample.timestamp <= draft.endDate
                    && Self.hasValidCoordinate(sample)
                    && sample.horizontalAccuracy.isFinite
                    && sample.horizontalAccuracy >= 0
                    && sample.horizontalAccuracy <= AircraftTripClassifier.usableAccuracyCeilingMeters
            }
        // Replayed fixes are one observation, not sustained speed. Conflicting
        // fixes at one timestamp are ambiguous; retain a gap marker so removing
        // them cannot manufacture a blackout across that point.
        let observations: [LocationSample?] = Dictionary(grouping: usable, by: \.timestamp)
            .sorted { $0.key < $1.key }
            .map { _, samples in
                let first = samples[0]
                return samples.allSatisfy {
                    $0.latitude == first.latitude
                        && $0.longitude == first.longitude
                        && $0.horizontalAccuracy == first.horizontalAccuracy
                        && $0.speedMetersPerSecond == first.speedMetersPerSecond
                        && $0.speedAccuracyMetersPerSecond == first.speedAccuracyMetersPerSecond
                } ? first : nil
            }

        var aircraftSpeedSampleCount = 0
        var peakReportedSpeed = 0.0
        for sample in observations.compactMap({ $0 }) {
            guard let speed = sample.speedMetersPerSecond,
                  speed.isFinite,
                  speed >= 0,
                  let speedAccuracy = sample.speedAccuracyMetersPerSecond,
                  speedAccuracy.isFinite,
                  speedAccuracy >= 0,
                  speedAccuracy <= AircraftTripClassifier.maximumSpeedAccuracyMetersPerSecond else {
                continue
            }
            peakReportedSpeed = max(peakReportedSpeed, speed)
            if speed >= AircraftTripClassifier.aircraftSpeedFloorMetersPerSecond {
                aircraftSpeedSampleCount += 1
            }
        }

        var blackoutJumpCount = 0
        var longestBlackoutDisplacement = 0.0
        if observations.count >= 2 {
            for index in 1..<observations.count {
                guard let previous = observations[index - 1],
                      let current = observations[index] else { continue }
                let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
                guard elapsed >= AircraftTripClassifier.minimumBlackoutSeconds else { continue }
                let displacement = DistanceCalculator.distanceMeters(
                    from: Coordinate(latitude: previous.latitude, longitude: previous.longitude),
                    to: Coordinate(latitude: current.latitude, longitude: current.longitude)
                )
                guard displacement.isFinite,
                      displacement >= AircraftTripClassifier.minimumBlackoutDisplacementMeters,
                      displacement / elapsed >= AircraftTripClassifier.minimumBlackoutImpliedSpeedMetersPerSecond else {
                    continue
                }
                blackoutJumpCount += 1
                longestBlackoutDisplacement = max(longestBlackoutDisplacement, displacement)
            }
        }

        return AircraftTripEvidence(
            aircraftSpeedSampleCount: aircraftSpeedSampleCount,
            blackoutJumpCount: blackoutJumpCount,
            peakReportedSpeedMetersPerSecond: peakReportedSpeed,
            longestBlackoutDisplacementMeters: longestBlackoutDisplacement
        )
    }

    private static func hasValidCoordinate(_ sample: LocationSample) -> Bool {
        sample.latitude.isFinite
            && sample.longitude.isFinite
            && (-90...90).contains(sample.latitude)
            && (-180...180).contains(sample.longitude)
    }
}

public enum AircraftTripVerdict: Equatable, Sendable {
    case aircraft(reason: String)
    case noMatch
}

/// Post-completion classifier for captures that rode an aircraft. Pure
/// function over `AircraftTripEvidence`; the completion coordinator does the
/// I/O and discards the capture before it is ever persisted.
///
/// Two independent routes, either sufficient:
/// - sustained: three or more fixes at or above 90 m/s (324 km/h). No road
///   vehicle holds that; a jet on climb-out or approach with a window seat's
///   GPS lock produces hundreds.
/// - corroborated: a single such fix plus a blackout jump — GPS dark for at
///   least a minute while the device covered 10 km or more at 45 m/s or
///   faster. Either half alone fails open: one fast fix can be a glitch, and a
///   long fast blackout alone is an autobahn drive whose GPS was throttled.
public struct AircraftTripClassifier: Sendable {
    /// Mirrors the live gate `DriveCaptureConfiguration.maxHorizontalAccuracyMeters`.
    public static let usableAccuracyCeilingMeters: Double = 65
    /// 324 km/h. Autobahn traffic tops out well under 250 km/h; jets rotate
    /// at roughly 70–80 m/s and climb through 120 m/s within a minute.
    public static let aircraftSpeedFloorMetersPerSecond: Double = 90
    /// Core Location's Doppler speed is only trusted with a tight error bar.
    public static let maximumSpeedAccuracyMetersPerSecond: Double = 10
    public static let minimumSustainedAircraftSpeedSampleCount = 3
    public static let minimumCorroboratedAircraftSpeedSampleCount = 1
    /// A blackout is time passing, not a teleporting fix pair.
    public static let minimumBlackoutSeconds: TimeInterval = 60
    public static let minimumBlackoutDisplacementMeters: Double = 10_000
    /// 162 km/h averaged across the whole dark stretch.
    public static let minimumBlackoutImpliedSpeedMetersPerSecond: Double = 45

    public init() {}

    public func verdict(for evidence: AircraftTripEvidence) -> AircraftTripVerdict {
        let isSustained = evidence.aircraftSpeedSampleCount
            >= Self.minimumSustainedAircraftSpeedSampleCount
        let isCorroborated = evidence.aircraftSpeedSampleCount
            >= Self.minimumCorroboratedAircraftSpeedSampleCount
            && evidence.blackoutJumpCount >= 1
        guard isSustained || isCorroborated else {
            return .noMatch
        }
        return .aircraft(
            reason: String(
                format: "Aircraft %@ fastSamples=%d peak=%.0f m/s blackoutJumps=%d longest=%.0f m",
                isSustained ? "sustained" : "corroborated",
                evidence.aircraftSpeedSampleCount,
                evidence.peakReportedSpeedMetersPerSecond,
                evidence.blackoutJumpCount,
                evidence.longestBlackoutDisplacementMeters
            )
        )
    }
}
