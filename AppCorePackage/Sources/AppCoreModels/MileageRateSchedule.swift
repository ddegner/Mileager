import Foundation

public struct MileageRateEffectiveDate: Codable, Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Persisted rate dates are Gregorian logical dates. Presentation can use
    /// the user's calendar, but storage must agree with schedule validation.
    public init(
        _ date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    public func date(
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let components = calendar.dateComponents([.year, .month, .day], from: value)
        guard components.year == year, components.month == month, components.day == day else {
            return nil
        }
        return value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

public struct MileageRateRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var effectiveFrom: MileageRateEffectiveDate
    public var rate: MileageRate
    public var updatedAt: Date
    public var irsSource: IRSBusinessRatePeriod?

    public init(
        id: UUID = UUID(),
        effectiveFrom: MileageRateEffectiveDate,
        rate: MileageRate,
        updatedAt: Date = Date(),
        irsSource: IRSBusinessRatePeriod? = nil
    ) {
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.rate = rate
        self.updatedAt = updatedAt
        self.irsSource = irsSource
    }
}

public struct MileageRateSchedule: Codable, Equatable, Sendable {
    public var baseRate: MileageRate
    public var rules: [MileageRateRule]
    public var deletedRuleIDs: [UUID: Date]
    public var irsFollowingFrom: MileageRateEffectiveDate?
    public var sourceSelectionUpdatedAt: Date?
    /// An implicit fresh-install default yields to any saved user schedule.
    public var isAutomaticIRSDefault: Bool
    /// A fresh non-US setup has no meaningful reimbursement amount yet.
    public var requiresCustomRate: Bool

    public init(
        baseRate: MileageRate,
        rules: [MileageRateRule] = [],
        deletedRuleIDs: [UUID: Date] = [:],
        irsFollowingFrom: MileageRateEffectiveDate? = nil,
        sourceSelectionUpdatedAt: Date? = nil,
        isAutomaticIRSDefault: Bool = false,
        requiresCustomRate: Bool = false
    ) {
        self.baseRate = baseRate
        self.rules = rules
        self.deletedRuleIDs = deletedRuleIDs
        self.irsFollowingFrom = irsFollowingFrom
        self.sourceSelectionUpdatedAt = sourceSelectionUpdatedAt
        self.isAutomaticIRSDefault = isAutomaticIRSDefault
        self.requiresCustomRate = requiresCustomRate
    }

    public static let `default` = MileageRateSchedule(baseRate: .default)

    public func rate(
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MileageRate {
        var logicalCalendar = Calendar(identifier: .gregorian)
        logicalCalendar.timeZone = calendar.timeZone
        let effectiveDate = MileageRateEffectiveDate(date, calendar: logicalCalendar)
        return normalizedRules.last(where: { $0.effectiveFrom <= effectiveDate })?.rate
            ?? baseRate
    }

    public func mileageValue(
        meters: Double,
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Double {
        meters * rate(on: date, calendar: calendar).amountPerMeter
    }

    public var normalizedRules: [MileageRateRule] {
        rules.filter {
            guard let deletedAt = deletedRuleIDs[$0.id] else { return true }
            return $0.updatedAt > deletedAt
        }.sorted {
            if $0.effectiveFrom != $1.effectiveFrom {
                return $0.effectiveFrom < $1.effectiveFrom
            }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case baseRate
        case rules
        case deletedRuleIDs
        case irsFollowingFrom
        case sourceSelectionUpdatedAt
        case isAutomaticIRSDefault
        case requiresCustomRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseRate = try container.decode(MileageRate.self, forKey: .baseRate)
        rules = try container.decodeIfPresent([MileageRateRule].self, forKey: .rules) ?? []
        deletedRuleIDs = try container.decodeIfPresent(
            [UUID: Date].self,
            forKey: .deletedRuleIDs
        ) ?? [:]
        irsFollowingFrom = try container.decodeIfPresent(MileageRateEffectiveDate.self, forKey: .irsFollowingFrom)
        sourceSelectionUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .sourceSelectionUpdatedAt)
        isAutomaticIRSDefault = try container.decodeIfPresent(Bool.self, forKey: .isAutomaticIRSDefault) ?? false
        requiresCustomRate = try container.decodeIfPresent(Bool.self, forKey: .requiresCustomRate) ?? false
    }
}

public enum MileageRateScheduleError: LocalizedError, Equatable {
    case duplicateEffectiveDate
    case invalidEffectiveDate
    case ruleNotFound
    case invalidCurrency

    public var errorDescription: String? {
        switch self {
        case .duplicateEffectiveDate:
            String(
                localized: "Only one mileage rate can begin on the same date.",
                bundle: .appCoreStrings
            )
        case .invalidEffectiveDate:
            String(localized: "Choose a valid effective date.", bundle: .appCoreStrings)
        case .invalidCurrency:
            String(localized: "Choose a valid currency.", bundle: .appCoreStrings)
        case .ruleNotFound:
            String(localized: "The mileage rate no longer exists.", bundle: .appCoreStrings)
        }
    }
}
