import AppCoreModels
import AppCorePersistence
import Foundation

/// Estimated odometer state across a report period, derived from sparse
/// user-entered checkpoints (typically two per year).
public enum OdometerPeriodEstimate: Equatable, Sendable {
    public enum BoundaryKind: Equatable, Sendable {
        /// A checkpoint exists exactly at this boundary instant.
        case exact
        /// Linearly interpolated between the two surrounding checkpoints.
        case interpolated
        /// Boundary lies outside the checkpoint span; nearest reading reused.
        case clamped
    }

    public struct Boundary: Equatable, Sendable {
        public var miles: Double
        public var kind: BoundaryKind

        public init(miles: Double, kind: BoundaryKind) {
            self.miles = miles
            self.kind = kind
        }
    }

    case none
    case singleReading(OdometerCheckpoint)
    case range(start: Boundary, end: Boundary, firstCheckpointDate: Date, lastCheckpointDate: Date)

    public var isEstimated: Bool {
        guard case let .range(start, end, _, _) = self else { return false }
        return start.kind != .exact || end.kind != .exact
    }

    public var totalMiles: Double? {
        guard case let .range(start, end, _, _) = self else { return nil }
        return end.miles - start.miles
    }

    /// Business miles as a fraction of estimated period vehicle miles, in
    /// percent. Nil when the estimate cannot support a defensible ratio:
    /// no range, non-positive total (typo'd checkpoints), or a ratio over
    /// 100% (the estimate is too coarse to be worth printing).
    public func businessUsePercent(businessMiles: Double) -> Double? {
        guard let total = totalMiles, total > 0 else { return nil }
        let percent = businessMiles / total * 100
        guard percent >= 0, percent <= 100 else { return nil }
        return percent
    }
}

public enum OdometerInterpolator {
    public static func estimate(
        checkpoints: [OdometerCheckpoint],
        start: Date,
        end: Date
    ) -> OdometerPeriodEstimate {
        let sorted = checkpoints.sorted {
            ($0.date, $0.odometerMiles) < ($1.date, $1.odometerMiles)
        }
        guard let first = sorted.first, let last = sorted.last else { return .none }
        if sorted.count == 1 { return .singleReading(first) }
        // Never extrapolate beyond the recorded span: readings entirely on
        // one side of the period can only vouch for a single point in time.
        if last.date < start { return .singleReading(last) }
        if first.date > end { return .singleReading(first) }

        return .range(
            start: value(at: start, in: sorted),
            end: value(at: end, in: sorted),
            firstCheckpointDate: first.date,
            lastCheckpointDate: last.date
        )
    }

    private static func value(at instant: Date, in sorted: [OdometerCheckpoint]) -> OdometerPeriodEstimate.Boundary {
        guard let first = sorted.first, let last = sorted.last else {
            return .init(miles: 0, kind: .clamped)
        }
        if instant <= first.date {
            return .init(miles: first.odometerMiles, kind: instant == first.date ? .exact : .clamped)
        }
        if instant >= last.date {
            return .init(miles: last.odometerMiles, kind: instant == last.date ? .exact : .clamped)
        }

        // Largest index whose date is <= instant; the guards above ensure
        // both it and a successor exist.
        let lowerIndex = sorted.lastIndex { $0.date <= instant } ?? 0
        let lower = sorted[lowerIndex]
        let upper = sorted[lowerIndex + 1]
        if lower.date == instant {
            return .init(miles: lower.odometerMiles, kind: .exact)
        }
        if lower.date == upper.date {
            return .init(miles: upper.odometerMiles, kind: .exact)
        }

        let fraction = instant.timeIntervalSince(lower.date) / upper.date.timeIntervalSince(lower.date)
        let miles = lower.odometerMiles + (upper.odometerMiles - lower.odometerMiles) * fraction
        return .init(miles: miles, kind: .interpolated)
    }
}
