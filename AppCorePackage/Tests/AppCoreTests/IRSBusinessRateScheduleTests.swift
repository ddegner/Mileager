import XCTest
@testable import AppCore

final class IRSBusinessRateScheduleTests: XCTestCase {
    func testAdoptionPreservesHistoryAppliesAllPeriodsAndIsIdempotent() throws {
        let historical = manualRule(2025, 1, 1, amount: 0.40)
        let original = MileageRateSchedule(baseRate: .init(amountPerUnit: 0.30, unit: .miles), rules: [historical])
        let now = instant(2026, 10, 1)
        let result = try IRSBusinessRateScheduleUpdater.apply(
            periods: periods,
            to: original,
            followingFrom: logical(2026, 1, 1),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.baseRate, original.baseRate)
        XCTAssertEqual(result.normalizedRules.first, historical)
        XCTAssertEqual(result.normalizedRules.count, 4)
        XCTAssertEqual(result.rate(on: instant(2026, 6, 30), calendar: calendar).amountPerUnit, 0.72)
        XCTAssertEqual(result.rate(on: instant(2026, 7, 1), calendar: calendar).amountPerUnit, 0.75)
        XCTAssertEqual(result.rate(on: instant(2027, 1, 1), calendar: calendar).amountPerUnit, 0.77)
        XCTAssertEqual(result.irsFollowingFrom, logical(2026, 1, 1))
        XCTAssertEqual(result.sourceSelectionUpdatedAt, now)
        XCTAssertEqual(try IRSBusinessRateScheduleUpdater.apply(
            periods: periods,
            to: result,
            followingFrom: logical(2026, 1, 1),
            now: now.addingTimeInterval(1_000),
            calendar: calendar
        ), result)
        XCTAssertEqual(try MileageRateScheduleStore.validated(result), result)
    }

    func testStartingMidPeriodDoesNotChangeEarlierTrips() throws {
        let schedule = MileageRateSchedule(baseRate: .init(amountPerUnit: 0.35, unit: .kilometers))
        let result = try IRSBusinessRateScheduleUpdater.apply(
            periods: periods,
            to: schedule,
            followingFrom: logical(2026, 5, 10),
            now: instant(2026, 5, 10),
            calendar: calendar
        )
        XCTAssertEqual(result.normalizedRules.first?.effectiveFrom, logical(2026, 5, 10))
        XCTAssertEqual(result.rate(on: instant(2026, 5, 9), calendar: calendar), schedule.baseRate)
        XCTAssertEqual(result.rate(on: instant(2026, 5, 10), calendar: calendar), periods[0].rate)
        XCTAssertEqual(result.normalizedRules.first?.irsSource, periods[0])
        XCTAssertEqual(try MileageRateScheduleStore.validated(result), result)
    }

    func testManualConflictsRequireExplicitReplacementAndCreateTombstone() throws {
        let historical = manualRule(2025, 1, 1, amount: 0.40)
        let conflicting = manualRule(2026, 5, 1, amount: 0.60)
        let later = manualRule(2028, 1, 1, amount: 0.90)
        let original = MileageRateSchedule(baseRate: .default, rules: [historical, conflicting, later])
        XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.apply(
            periods: periods, to: original, followingFrom: logical(2026, 1, 1),
            now: instant(2026, 10, 1), calendar: calendar
        )) { error in
            XCTAssertEqual(error as? IRSBusinessRateScheduleError, .overlappingManualRules([conflicting]))
        }
        let now = instant(2026, 10, 1)
        let result = try IRSBusinessRateScheduleUpdater.apply(
            periods: periods, to: original, followingFrom: logical(2026, 1, 1),
            replaceManual: true, now: now, calendar: calendar
        )
        XCTAssertTrue(result.rules.contains(historical))
        XCTAssertTrue(result.rules.contains(later))
        XCTAssertFalse(result.rules.contains(where: { $0.id == conflicting.id }))
        XCTAssertEqual(result.deletedRuleIDs[conflicting.id], now)
    }

    func testCorrectedIRSRateRetainsIDAndStoppingRetainsAcceptedFutureRules() throws {
        let initial = try IRSBusinessRateScheduleUpdater.apply(
            periods: periods, to: .default, followingFrom: logical(2026, 1, 1),
            now: instant(2026, 10, 1), calendar: calendar
        )
        var corrected = periods
        corrected[1].amountPerMile = 0.76
        let now = instant(2026, 10, 2)
        let updated = try IRSBusinessRateScheduleUpdater.apply(
            periods: corrected, to: initial, followingFrom: logical(2026, 1, 1),
            now: now, calendar: calendar
        )
        XCTAssertEqual(updated.rules[1].id, initial.rules[1].id)
        XCTAssertEqual(updated.rules[1].updatedAt, now)
        XCTAssertEqual(updated.rules[1].rate.amountPerUnit, 0.76)
        let stopped = IRSBusinessRateScheduleUpdater.stopFollowing(updated, now: now.addingTimeInterval(1))
        XCTAssertNil(stopped.irsFollowingFrom)
        XCTAssertEqual(stopped.rules, updated.rules)
        XCTAssertEqual(stopped.sourceSelectionUpdatedAt, now.addingTimeInterval(1))
    }

    func testMissingAndGappedCoverageCannotBeApplied() {
        for candidates in [[], [periods[1]], [periods[0], periods[2]], [periods[0]]] {
            XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.apply(
                periods: candidates, to: .default, followingFrom: logical(2026, 1, 1),
                now: instant(2026, 10, 1), calendar: calendar
            )) { error in
                XCTAssertEqual(error as? IRSBusinessRateScheduleError, .missingCoverage)
            }
        }
    }

    func testInvalidExtractionIsRejected() {
        var invalidDate = periods[0]
        invalidDate.effectiveThrough = logical(2026, 2, 30)
        var inverted = periods[0]
        inverted.effectiveThrough = logical(2025, 12, 31)
        var zero = periods[0]
        zero.amountPerMile = 0
        var infinite = periods[0]
        infinite.amountPerMile = .infinity
        var notANumber = periods[0]
        notANumber.amountPerMile = .nan
        let cases: [([IRSBusinessRatePeriod], IRSBusinessRateScheduleError)] = [
            ([invalidDate], .invalidEffectiveDate), ([inverted], .invalidPeriod),
            ([zero], .invalidAmount), ([infinite], .invalidAmount), ([notANumber], .invalidAmount),
            ([periods[0], periods[0]], .overlappingPeriods)
        ]
        for (candidates, expected) in cases {
            XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.validatedPeriods(candidates)) { error in
                XCTAssertEqual(error as? IRSBusinessRateScheduleError, expected)
            }
        }
        XCTAssertNil(logical(2026, 2, 30).date(calendar: calendar))
        XCTAssertNil(logical(2026, 0, 1).date(calendar: calendar))
    }

    func testOldScheduleDecodesWithoutSourceSelectionAndNewFieldsRoundTrip() throws {
        let schedule = MileageRateSchedule(baseRate: .default, rules: [manualRule(2026, 1, 1, amount: 0.65)])
        let encoded = try JSONEncoder().encode(schedule)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "irsFollowingFrom")
        legacy.removeValue(forKey: "sourceSelectionUpdatedAt")
        var legacyRules = try XCTUnwrap(legacy["rules"] as? [[String: Any]])
        legacyRules[0].removeValue(forKey: "irsSource")
        legacy["rules"] = legacyRules
        let decoded = try JSONDecoder().decode(MileageRateSchedule.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.irsFollowingFrom)
        XCTAssertNil(decoded.sourceSelectionUpdatedAt)
        XCTAssertNil(decoded.rules[0].irsSource)
        let updated = try IRSBusinessRateScheduleUpdater.apply(
            periods: periods, to: .default, followingFrom: logical(2026, 1, 1),
            now: instant(2026, 10, 1), calendar: calendar
        )
        XCTAssertEqual(try JSONDecoder().decode(MileageRateSchedule.self, from: JSONEncoder().encode(updated)), updated)
    }

    func testPersistedIRSRuleMustMatchEvidenceAndHaveAValidFollowingDate() throws {
        let source = periods[0]
        let mismatched = MileageRateRule(effectiveFrom: source.effectiveFrom,
                                         rate: .init(amountPerUnit: 0.50, unit: .miles), irsSource: source)
        XCTAssertThrowsError(try MileageRateScheduleStore.validated(.init(baseRate: .default, rules: [mismatched])))
        XCTAssertThrowsError(try MileageRateScheduleStore.validated(.init(baseRate: .default,
                                                                         irsFollowingFrom: logical(2026, 2, 30))))
        let converted = MileageRateRule(effectiveFrom: source.effectiveFrom,
                                        rate: source.rate.converted(to: .kilometers), irsSource: source)
        _ = try MileageRateScheduleStore.validated(.init(baseRate: .default, rules: [converted]))
    }

    func testHistoryAdoptionReplacesAllCustomRulesAndUsesFirstAcceptedAmountAsFallback() throws {
        let now = instant(2026, 10, 1)
        var historical = manualRule(2025, 1, 1, amount: 0.40)
        historical.updatedAt = instant(2026, 9, 1)
        var current = manualRule(2026, 6, 1, amount: 0.90)
        current.updatedAt = historical.updatedAt
        var outsideCoverage = manualRule(2030, 1, 1, amount: 1.20)
        outsideCoverage.updatedAt = now.addingTimeInterval(60)
        let previousDeletion = UUID()
        let original = MileageRateSchedule(
            baseRate: .init(amountPerUnit: 0.45, unit: .kilometers),
            rules: [historical, current, outsideCoverage],
            deletedRuleIDs: [previousDeletion: historical.updatedAt]
        )
        let result = try IRSBusinessRateScheduleUpdater.adoptHistory(
            periods: periods, to: original, followingFrom: logical(2026, 5, 23),
            now: now, calendar: calendar
        )

        XCTAssertEqual(result.baseRate, periods[0].rate)
        XCTAssertEqual(result.normalizedRules.map(\.effectiveFrom),
                       [logical(2026, 5, 23), logical(2026, 7, 1), logical(2027, 1, 1)])
        XCTAssertEqual(result.normalizedRules.map(\.irsSource), periods.map(Optional.some))
        XCTAssertEqual(result.rate(on: instant(2026, 5, 22), calendar: calendar), periods[0].rate)
        XCTAssertEqual(result.rate(on: instant(2026, 6, 30), calendar: calendar), periods[0].rate)
        XCTAssertEqual(result.rate(on: instant(2026, 7, 1), calendar: calendar), periods[1].rate)
        XCTAssertEqual(result.rate(on: instant(2030, 1, 1), calendar: calendar), periods[2].rate)
        for rule in original.rules {
            XCTAssertFalse(result.rules.contains { $0.id == rule.id })
            XCTAssertEqual(result.deletedRuleIDs[rule.id], max(now, rule.updatedAt))
            var remoteReplay = result
            remoteReplay.rules.append(rule)
            XCTAssertFalse(remoteReplay.normalizedRules.contains { $0.id == rule.id })
        }
        XCTAssertEqual(result.deletedRuleIDs[previousDeletion], historical.updatedAt)
        XCTAssertEqual(result.irsFollowingFrom, logical(2026, 5, 23))
        XCTAssertEqual(result.sourceSelectionUpdatedAt, now)
        XCTAssertEqual(try MileageRateScheduleStore.validated(result), result)
    }

    func testHistoryAdoptionRetainsIRSIdentitiesWhenExpandingHistoryAndTombstonesDuplicates() throws {
        let firstAdoption = instant(2026, 10, 1)
        var original = try IRSBusinessRateScheduleUpdater.apply(
            periods: periods, to: .default, followingFrom: logical(2026, 10, 1),
            now: firstAdoption, calendar: calendar
        )
        let clippedCurrent = original.rules[0]
        let acceptedFuture = original.rules[1]
        let duplicate = MileageRateRule(effectiveFrom: logical(2026, 9, 1), rate: periods[1].rate,
            updatedAt: instant(2026, 9, 1), irsSource: periods[1])
        let oldSource = period(logical(2025, 1, 1), logical(2025, 12, 31), 0.60)
        let obsolete = MileageRateRule(effectiveFrom: oldSource.effectiveFrom, rate: oldSource.rate,
            updatedAt: instant(2025, 1, 1), irsSource: oldSource)
        original.rules += [duplicate, obsolete]
        var corrected = periods
        corrected[1].amountPerMile = 0.76
        let now = instant(2026, 10, 2)
        let result = try IRSBusinessRateScheduleUpdater.adoptHistory(
            periods: corrected, to: original, followingFrom: logical(2026, 1, 1),
            now: now, calendar: calendar
        )

        XCTAssertEqual(result.normalizedRules.count, 3)
        XCTAssertEqual(result.rules[1].id, clippedCurrent.id)
        XCTAssertEqual(result.rules[1].effectiveFrom, logical(2026, 7, 1))
        XCTAssertEqual(result.rules[1].rate, corrected[1].rate)
        XCTAssertEqual(result.rules[1].irsSource, corrected[1])
        XCTAssertEqual(result.rules[1].updatedAt, now)
        XCTAssertEqual(result.rules[2], acceptedFuture)
        XCTAssertEqual(result.deletedRuleIDs[duplicate.id], now)
        XCTAssertEqual(result.deletedRuleIDs[obsolete.id], now)
        XCTAssertEqual(result.sourceSelectionUpdatedAt, now)
        XCTAssertEqual(try MileageRateScheduleStore.validated(result), result)
    }

    func testHistoryAdoptionIsIdempotentAndRoutineChecksStillReviewImportedCustomRules() throws {
        let now = instant(2026, 10, 1)
        let result = try IRSBusinessRateScheduleUpdater.adoptHistory(
            periods: periods, to: .default, followingFrom: logical(2026, 1, 1),
            now: now, calendar: calendar
        )
        XCTAssertEqual(try IRSBusinessRateScheduleUpdater.adoptHistory(
            periods: periods, to: result, followingFrom: logical(2026, 1, 1),
            now: now.addingTimeInterval(1_000), calendar: calendar
        ), result)

        var laterImport = result
        let manual = manualRule(2026, 5, 1, amount: 0.99)
        laterImport.rules.append(manual)
        XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.apply(
            periods: periods, to: laterImport, followingFrom: logical(2026, 1, 1),
            now: now.addingTimeInterval(2_000), calendar: calendar
        )) { error in
            XCTAssertEqual(error as? IRSBusinessRateScheduleError, .overlappingManualRules([manual]))
        }
    }

    func testHistoryAdoptionRejectsMissingHistoryGapsAndInvalidPeriods() {
        let now = instant(2026, 10, 1)
        let original = MileageRateSchedule(baseRate: .init(amountPerUnit: 0.40, unit: .kilometers),
            rules: [manualRule(2025, 1, 1, amount: 0.55)])
        var invalidAmount = periods[0]
        invalidAmount.amountPerMile = .nan
        let cases: [([IRSBusinessRatePeriod], MileageRateEffectiveDate, IRSBusinessRateScheduleError)] = [
            ([], logical(2026, 1, 1), .missingCoverage),
            (periods, logical(2025, 12, 31), .missingCoverage),
            ([periods[1]], logical(2026, 1, 1), .missingCoverage),
            ([periods[0]], logical(2026, 1, 1), .missingCoverage),
            ([periods[0], periods[2]], logical(2026, 1, 1), .missingCoverage),
            (periods, logical(2026, 2, 30), .invalidEffectiveDate),
            ([invalidAmount], logical(2026, 1, 1), .invalidAmount),
            ([periods[0], periods[0]], logical(2026, 1, 1), .overlappingPeriods)
        ]
        for (candidates, from, expected) in cases {
            XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.adoptHistory(
                periods: candidates, to: original, followingFrom: from, now: now, calendar: calendar
            )) { error in
                XCTAssertEqual(error as? IRSBusinessRateScheduleError, expected)
            }
        }
    }

    private var periods: [IRSBusinessRatePeriod] {
        [period(logical(2026, 1, 1), logical(2026, 6, 30), 0.72),
         period(logical(2026, 7, 1), logical(2026, 12, 31), 0.75),
         period(logical(2027, 1, 1), logical(2027, 12, 31), 0.77)]
    }

    private func period(_ from: MileageRateEffectiveDate, _ through: MileageRateEffectiveDate, _ amount: Double) -> IRSBusinessRatePeriod {
        .init(effectiveFrom: from, effectiveThrough: through, amountPerMile: amount,
              sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
              rateEvidence: "Synthetic test business rate \(amount)", periodEvidence: "Synthetic test period")
    }

    private func manualRule(_ year: Int, _ month: Int, _ day: Int, amount: Double) -> MileageRateRule {
        .init(effectiveFrom: logical(year, month, day), rate: .init(amountPerUnit: amount, unit: .miles))
    }

    private func logical(_ year: Int, _ month: Int, _ day: Int) -> MileageRateEffectiveDate {
        .init(year: year, month: month, day: day)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        return value
    }

    private func instant(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
