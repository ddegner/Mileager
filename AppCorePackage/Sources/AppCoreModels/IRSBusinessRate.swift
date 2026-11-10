import Foundation

/// A source-backed IRS business rate. Amounts are always USD per mile;
/// presentation and distance-unit conversion do not change this quote.
public struct IRSBusinessRatePeriod: Codable, Equatable, Sendable {
    public var effectiveFrom: MileageRateEffectiveDate
    public var effectiveThrough: MileageRateEffectiveDate
    public var amountPerMile: Double
    public var sourceURL: String
    public var rateEvidence: String
    public var periodEvidence: String

    public init(
        effectiveFrom: MileageRateEffectiveDate,
        effectiveThrough: MileageRateEffectiveDate,
        amountPerMile: Double,
        sourceURL: String,
        rateEvidence: String,
        periodEvidence: String
    ) {
        self.effectiveFrom = effectiveFrom
        self.effectiveThrough = effectiveThrough
        self.amountPerMile = amountPerMile
        self.sourceURL = sourceURL
        self.rateEvidence = rateEvidence
        self.periodEvidence = periodEvidence
    }

    public var rate: MileageRate {
        MileageRate(amountPerUnit: amountPerMile, unit: .miles)
    }

    /// Official table quote verified October 4, 2026. Foreground checks still
    /// verify coverage through today and backfill older recorded drives.
    public static let bundledCurrent = IRSBusinessRatePeriod(
        effectiveFrom: .init(year: 2026, month: 7, day: 1),
        effectiveThrough: .init(year: 2026, month: 12, day: 31),
        amountPerMile: 0.76,
        sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
        rateEvidence: "76",
        periodEvidence: "2026 (July 1 – Dec. 31)"
    )
}

public enum IRSBusinessRateScheduleError: Error, Equatable, Sendable {
    case invalidEffectiveDate
    case invalidPeriod
    case invalidAmount
    case overlappingPeriods
    case missingCoverage
    case overlappingManualRules([MileageRateRule])
}

/// Pure schedule updates, shared by the automatic check and explicit adoption.
/// The caller must first verify that the source and evidence are trustworthy.
public enum IRSBusinessRateScheduleUpdater {
    public static func initialSchedule(currencyCode: String, now: Date = Date()) -> MileageRateSchedule {
        guard currencyCode == "USD" else {
            return MileageRateSchedule(baseRate: .init(amountPerUnit: 0, unit: .miles), requiresCustomRate: true)
        }
        let period = IRSBusinessRatePeriod.bundledCurrent
        return MileageRateSchedule(
            baseRate: period.rate,
            rules: [.init(effectiveFrom: period.effectiveFrom, rate: period.rate, updatedAt: now, irsSource: period)],
            irsFollowingFrom: period.effectiveFrom,
            isAutomaticIRSDefault: true
        )
    }

    public static func validatedPeriods(
        _ periods: [IRSBusinessRatePeriod]
    ) throws -> [IRSBusinessRatePeriod] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        for period in periods {
            guard period.effectiveFrom.date(calendar: calendar) != nil,
                  period.effectiveThrough.date(calendar: calendar) != nil else {
                throw IRSBusinessRateScheduleError.invalidEffectiveDate
            }
            guard period.effectiveFrom <= period.effectiveThrough else {
                throw IRSBusinessRateScheduleError.invalidPeriod
            }
            guard period.amountPerMile.isFinite, period.amountPerMile > 0 else {
                throw IRSBusinessRateScheduleError.invalidAmount
            }
        }
        let sorted = periods.sorted { $0.effectiveFrom < $1.effectiveFrom }
        for index in sorted.indices.dropFirst() {
            guard sorted[index - 1].effectiveThrough < sorted[index].effectiveFrom else {
                throw IRSBusinessRateScheduleError.overlappingPeriods
            }
        }
        return sorted
    }

    public static func apply(
        periods: [IRSBusinessRatePeriod],
        to schedule: MileageRateSchedule,
        followingFrom: MileageRateEffectiveDate,
        replaceManual: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> MileageRateSchedule {
        let applicable = try coveredPeriods(periods, followingFrom: followingFrom, now: now, calendar: calendar)
        let last = applicable[applicable.count - 1]

        // An older manual rule remains the historical rate before adoption.
        // Rules beginning inside the adopted interval require explicit review.
        let conflicts = schedule.normalizedRules.filter {
            $0.irsSource == nil && $0.effectiveFrom >= followingFrom
                && $0.effectiveFrom <= last.effectiveThrough
        }
        if !replaceManual, !conflicts.isEmpty {
            throw IRSBusinessRateScheduleError.overlappingManualRules(conflicts)
        }

        var result = schedule
        let active = schedule.normalizedRules
        let desiredDates = Set(applicable.map { max($0.effectiveFrom, followingFrom) })
        let removals = active.filter { rule in
            guard rule.effectiveFrom >= followingFrom,
                  rule.effectiveFrom <= last.effectiveThrough else { return false }
            return rule.irsSource == nil || !desiredDates.contains(rule.effectiveFrom)
        }
        for rule in removals {
            result.rules.removeAll { $0.id == rule.id }
            result.deletedRuleIDs[rule.id] = max(result.deletedRuleIDs[rule.id] ?? .distantPast, now)
        }

        for period in applicable {
            let start = max(period.effectiveFrom, followingFrom)
            if let index = result.rules.firstIndex(where: {
                $0.effectiveFrom == start && $0.irsSource != nil
                    && $0.updatedAt > (result.deletedRuleIDs[$0.id] ?? .distantPast)
            }) {
                guard result.rules[index].rate != period.rate
                        || result.rules[index].irsSource != period else { continue }
                result.rules[index].rate = period.rate
                result.rules[index].irsSource = period
                result.rules[index].updatedAt = now
            } else {
                result.rules.append(MileageRateRule(
                    effectiveFrom: start,
                    rate: period.rate,
                    updatedAt: now,
                    irsSource: period
                ))
            }
        }
        result.rules.sort { $0.effectiveFrom < $1.effectiveFrom }
        if result.irsFollowingFrom != followingFrom || result.sourceSelectionUpdatedAt == nil {
            result.irsFollowingFrom = followingFrom
            if !result.isAutomaticIRSDefault { result.sourceSelectionUpdatedAt = now }
        }
        return result
    }

    /// Explicit initial adoption replaces the entire custom schedule with
    /// verified IRS history from the first recorded trip. Routine checks use
    /// `apply` so later imported custom rules still require review.
    public static func adoptHistory(
        periods: [IRSBusinessRatePeriod],
        to schedule: MileageRateSchedule,
        followingFrom: MileageRateEffectiveDate,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> MileageRateSchedule {
        let applicable = try coveredPeriods(periods, followingFrom: followingFrom, now: now, calendar: calendar)
        let previousIRS = schedule.normalizedRules.filter { $0.irsSource != nil }
        var retainedIDs = Set<UUID>()
        var rules: [MileageRateRule] = []
        for period in applicable {
            let start = max(period.effectiveFrom, followingFrom)
            // Prefer an existing rule on the desired date. An older adoption
            // may have clipped this period to a later first-trip date, so also
            // retain its identity when expanding the verified history.
            let candidates = previousIRS.filter { rule in
                !retainedIDs.contains(rule.id) && (rule.effectiveFrom == start
                    || (rule.irsSource?.effectiveFrom == period.effectiveFrom
                        && rule.irsSource?.effectiveThrough == period.effectiveThrough))
            }.sorted { first, second in
                let firstExact = first.effectiveFrom == start
                let secondExact = second.effectiveFrom == start
                if firstExact != secondExact { return firstExact }
                if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
                return first.id.uuidString < second.id.uuidString
            }
            var rule = candidates.first ?? MileageRateRule(
                effectiveFrom: start, rate: period.rate, updatedAt: now, irsSource: period
            )
            if rule.effectiveFrom != start || rule.rate != period.rate || rule.irsSource != period {
                rule.effectiveFrom = start
                rule.rate = period.rate
                rule.irsSource = period
                rule.updatedAt = now
            }
            retainedIDs.insert(rule.id)
            rules.append(rule)
        }

        var result = schedule
        let wasAutomaticDefault = result.isAutomaticIRSDefault
        result.isAutomaticIRSDefault = false
        result.requiresCustomRate = false
        result.baseRate = applicable[0].rate
        result.rules = rules
        for rule in schedule.rules where !retainedIDs.contains(rule.id) {
            // Equality is deleted in normalizedRules. Cover a clock-ahead rule
            // too, so merging the replaced record cannot resurrect it.
            result.deletedRuleIDs[rule.id] = max(
                result.deletedRuleIDs[rule.id] ?? .distantPast, max(now, rule.updatedAt)
            )
        }
        if wasAutomaticDefault || result.irsFollowingFrom != followingFrom || result.sourceSelectionUpdatedAt == nil {
            result.irsFollowingFrom = followingFrom
            result.sourceSelectionUpdatedAt = now
        }
        return result
    }

    public static func stopFollowing(
        _ schedule: MileageRateSchedule,
        now: Date = Date()
    ) -> MileageRateSchedule {
        guard schedule.irsFollowingFrom != nil else { return schedule }
        var result = schedule
        result.irsFollowingFrom = nil
        result.isAutomaticIRSDefault = false
        result.sourceSelectionUpdatedAt = now
        return result
    }

    /// A saved custom amount replaces inherited IRS changes from this date,
    /// while preserving past rates and explicitly scheduled custom changes.
    public static func applyCustomRate(
        _ rate: MileageRate,
        to schedule: MileageRateSchedule,
        effectiveFrom: MileageRateEffectiveDate,
        now: Date = Date()
    ) throws -> MileageRateSchedule {
        guard rate.amountPerUnit.isFinite, rate.amountPerUnit >= 0 else {
            throw IRSBusinessRateScheduleError.invalidAmount
        }
        guard effectiveFrom.date(calendar: Calendar(identifier: .gregorian)) != nil else {
            throw IRSBusinessRateScheduleError.invalidEffectiveDate
        }
        var result = schedule
        let existing = schedule.normalizedRules.first { $0.effectiveFrom == effectiveFrom }
        let removed = schedule.rules.filter {
            $0.id != existing?.id && $0.irsSource != nil && $0.effectiveFrom >= effectiveFrom
        }
        let removedIDs = Set(removed.map(\.id))
        result.rules.removeAll { removedIDs.contains($0.id) }
        for rule in removed {
            result.deletedRuleIDs[rule.id] = max(
                result.deletedRuleIDs[rule.id] ?? .distantPast, max(now, rule.updatedAt)
            )
        }
        if var rule = existing, let index = result.rules.firstIndex(where: { $0.id == rule.id }) {
            rule.rate = rate
            rule.irsSource = nil
            // Preserve identity while making this save newer than a synced,
            // clock-ahead copy of the former rule.
            rule.updatedAt = max(now, rule.updatedAt.addingTimeInterval(0.001))
            result.rules[index] = rule
        } else {
            result.rules.append(MileageRateRule(effectiveFrom: effectiveFrom, rate: rate, updatedAt: now))
        }
        result.rules.sort { $0.effectiveFrom < $1.effectiveFrom }
        result.irsFollowingFrom = nil
        result.isAutomaticIRSDefault = false
        result.requiresCustomRate = false
        result.sourceSelectionUpdatedAt = max(now, (schedule.sourceSelectionUpdatedAt ?? .distantPast).addingTimeInterval(0.001))
        return result
    }

    private static func coveredPeriods(
        _ periods: [IRSBusinessRatePeriod],
        followingFrom: MileageRateEffectiveDate,
        now: Date,
        calendar: Calendar
    ) throws -> [IRSBusinessRatePeriod] {
        var logicalCalendar = Calendar(identifier: .gregorian)
        logicalCalendar.timeZone = calendar.timeZone
        guard followingFrom.date(calendar: logicalCalendar) != nil else {
            throw IRSBusinessRateScheduleError.invalidEffectiveDate
        }
        let applicable = try validatedPeriods(periods).filter { $0.effectiveThrough >= followingFrom }
        let today = MileageRateEffectiveDate(now, calendar: logicalCalendar)
        guard let first = applicable.first, first.effectiveFrom <= followingFrom,
              let last = applicable.last, last.effectiveThrough >= max(today, followingFrom) else {
            throw IRSBusinessRateScheduleError.missingCoverage
        }
        for index in applicable.indices.dropFirst() {
            guard nextDay(after: applicable[index - 1].effectiveThrough) == applicable[index].effectiveFrom else {
                throw IRSBusinessRateScheduleError.missingCoverage
            }
        }
        return applicable
    }

    private static func nextDay(after date: MileageRateEffectiveDate) -> MileageRateEffectiveDate? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let value = date.date(calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: value) else { return nil }
        return MileageRateEffectiveDate(next, calendar: calendar)
    }
}
