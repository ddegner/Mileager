import Foundation

/// The user-entered reimbursement rate, quoted per the distance unit it was
/// entered in. Converting units keeps the payout invariant.
public struct MileageRate: Codable, Equatable, Sendable {
    public var amountPerUnit: Double
    public var unit: DistanceUnit

    public static let `default` = MileageRate(amountPerUnit: 0.76, unit: .miles)

    public init(amountPerUnit: Double, unit: DistanceUnit) {
        self.amountPerUnit = amountPerUnit
        self.unit = unit
    }

    public var amountPerMeter: Double {
        amountPerUnit / unit.metersPerUnit
    }

    public func converted(to newUnit: DistanceUnit) -> MileageRate {
        guard newUnit != unit else { return self }
        return MileageRate(amountPerUnit: amountPerMeter * newUnit.metersPerUnit, unit: newUnit)
    }
}
