import AppCoreModels
import Foundation

/// Whole-capture evidence that a recorded "drive" was a bicycle ride.
///
/// CoreMotion has a cycling class, but the reducer kills a candidate the
/// moment it reports one, so a ride is only ever recorded during the stretch
/// where CoreMotion mislabels fast cycling as `automotive` — and every sample
/// inside that stretch inherits the wrong label. The cycling reports land just
/// before the capture (the candidates they killed) and at its end (the
/// snapshot that parked it). The reducer carries those timestamps on
/// `TripDraft.cyclingMotionDates`; nothing else sees them in time.
///
/// Field captures included rides with cycling reports minutes before the
/// start and a return to cycling shortly after the end, as well as rides with
/// cycling reports before and during the capture. The reviewed car trips had
/// no high-confidence cycling report in the 15 minutes before starting.
public struct CyclingTripEvidence: Equatable, Sendable {
    /// High-confidence cycling snapshots inside the lead-in before the start.
    public var cyclingBeforeStartCount: Int
    /// Cycling snapshots during the capture, plus in-trip fixes whose own
    /// motion data says cycling.
    public var cyclingDuringCount: Int
    /// Cycling snapshots inside the tail after the end — normally the one
    /// that parked the recording.
    public var cyclingAfterEndCount: Int
    /// A trusted vehicle connection was present around the capture, from
    /// the reducer, the draft's vehicle attribution, or the stores.
    public var vehicleConnectionObserved: Bool
    /// Fastest reported speed among usable in-trip fixes. `nil` when no fix
    /// reported a speed, which fails open.
    public var peakReportedSpeedMetersPerSecond: Double?

    public init(
        cyclingBeforeStartCount: Int,
        cyclingDuringCount: Int,
        cyclingAfterEndCount: Int,
        vehicleConnectionObserved: Bool,
        peakReportedSpeedMetersPerSecond: Double?
    ) {
        self.cyclingBeforeStartCount = cyclingBeforeStartCount
        self.cyclingDuringCount = cyclingDuringCount
        self.cyclingAfterEndCount = cyclingAfterEndCount
        self.vehicleConnectionObserved = vehicleConnectionObserved
        self.peakReportedSpeedMetersPerSecond = peakReportedSpeedMetersPerSecond
    }

    /// `vehicleConnectionObserved` is OR-ed with the draft's own flag so the
    /// caller can add store-backed evidence the reducer never saw.
    public static func extract(draft: TripDraft, vehicleConnectionObserved: Bool = false) -> CyclingTripEvidence {
        let start = draft.startDate
        let end = draft.endDate
        let leadStart = start.addingTimeInterval(-CyclingTripClassifier.leadInSeconds)
        let tailEnd = end.addingTimeInterval(CyclingTripClassifier.tailSeconds)

        var before = 0
        var during = 0
        var after = 0
        for date in draft.cyclingMotionDates {
            if date >= leadStart, date < start {
                before += 1
            } else if date >= start, date <= end {
                during += 1
            } else if date > end, date <= tailEnd {
                after += 1
            }
        }

        var peak: Double?
        for sample in draft.samples {
            guard sample.timestamp >= start,
                  sample.timestamp <= end,
                  sample.horizontalAccuracy.isFinite,
                  sample.horizontalAccuracy >= 0,
                  sample.horizontalAccuracy <= CyclingTripClassifier.usableAccuracyCeilingMeters else {
                continue
            }
            if sample.motionHint == .cycling
                || (sample.motionActivity.map { $0.confidence == .high && $0.contains(.cycling) } ?? false) {
                during += 1
            }
            if let speed = sample.speedMetersPerSecond, speed.isFinite, speed >= 0 {
                peak = max(peak ?? 0, speed)
            }
        }

        return CyclingTripEvidence(
            cyclingBeforeStartCount: before,
            cyclingDuringCount: during,
            cyclingAfterEndCount: after,
            vehicleConnectionObserved: vehicleConnectionObserved || draft.vehicleConnectionObserved,
            peakReportedSpeedMetersPerSecond: peak
        )
    }
}

public enum CyclingTripVerdict: Equatable, Sendable {
    case cycling(reason: String)
    case noMatch
}

/// Post-completion classifier for captures that were bicycle rides. Pure
/// function over `CyclingTripEvidence`; the completion coordinator supplies
/// the store-backed vehicle evidence and discards the capture before it is
/// persisted.
///
/// All four conditions must hold. Cars do pick up stray cycling reports
/// mid-drive and right after parking (22 of 166 reviewed drives had one
/// somewhere nearby), which is why the lead-in half of the bracket is
/// required; a car connection or car speed each independently keeps the trip.
public struct CyclingTripClassifier: Sendable {
    /// Mirrors the live gate `DriveCaptureConfiguration.maxHorizontalAccuracyMeters`.
    public static let usableAccuracyCeilingMeters: Double = 65
    /// Cycling must have been reported this long before the start, or sooner.
    public static let leadInSeconds: TimeInterval = 15 * 60
    /// …and again during the capture or this long after its end.
    public static let tailSeconds: TimeInterval = 5 * 60
    /// A trusted vehicle connection this far before the start still vetoes.
    public static let vehicleConnectionLeadSeconds: TimeInterval = 10 * 60
    /// 47 km/h. Reviewed bicycle captures peaked between 6.8 and 11.7 m/s,
    /// while a car capture with cycling reports peaked at 18.7 m/s.
    public static let maximumReportedSpeedMetersPerSecond: Double = 13

    public init() {}

    public func verdict(for evidence: CyclingTripEvidence) -> CyclingTripVerdict {
        guard evidence.cyclingBeforeStartCount >= 1,
              evidence.cyclingDuringCount + evidence.cyclingAfterEndCount >= 1,
              !evidence.vehicleConnectionObserved,
              let peak = evidence.peakReportedSpeedMetersPerSecond,
              peak <= Self.maximumReportedSpeedMetersPerSecond else {
            return .noMatch
        }
        return .cycling(
            reason: String(
                format: "Cycling bracket before=%d during=%d after=%d peak=%.1f m/s",
                evidence.cyclingBeforeStartCount,
                evidence.cyclingDuringCount,
                evidence.cyclingAfterEndCount,
                peak
            )
        )
    }
}
