import CoreData
import XCTest
@testable import AppCore

final class MileageRateScheduleTests: XCTestCase {
    func testUsesBaseBeforeFirstRuleAndLatestRuleOnBoundaries() throws {
        let schedule = MileageRateSchedule(
            baseRate: MileageRate(amountPerUnit: 0.40, unit: .miles),
            rules: [
                rule(2026, 1, 1, amount: 0.50),
                rule(2026, 7, 1, amount: 0.60)
            ]
        )
        let calendar = utcCalendar()

        XCTAssertEqual(schedule.rate(on: date(2025, 12, 31), calendar: calendar).amountPerUnit, 0.40)
        XCTAssertEqual(schedule.rate(on: date(2026, 1, 1), calendar: calendar).amountPerUnit, 0.50)
        XCTAssertEqual(schedule.rate(on: date(2026, 6, 30), calendar: calendar).amountPerUnit, 0.50)
        XCTAssertEqual(schedule.rate(on: date(2026, 7, 1), calendar: calendar).amountPerUnit, 0.60)
    }

    func testDateOnlyRuleDoesNotShiftAcrossTimeZones() {
        let effective = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
        let schedule = MileageRateSchedule(
            baseRate: MileageRate(amountPerUnit: 1, unit: .miles),
            rules: [MileageRateRule(
                effectiveFrom: effective,
                rate: MileageRate(amountPerUnit: 2, unit: .miles)
            )]
        )
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let localNoon = losAngeles.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 12
        ))!

        XCTAssertEqual(schedule.rate(on: localNoon, calendar: losAngeles).amountPerUnit, 2)
    }

    func testStoreMigratesLegacyRateIntoBaseAndDualWritesCurrentRate() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let legacy = MileageRateStore(context: context)
        try legacy.saveRate(MileageRate(amountPerUnit: 0.75, unit: .miles))
        let store = MileageRateScheduleStore(context: context)

        var schedule = try store.fetchSchedule()
        XCTAssertEqual(schedule.baseRate.amountPerUnit, 0.75)
        schedule.rules = [rule(2026, 1, 1, amount: 0.80)]
        _ = try store.saveSchedule(schedule, now: date(2026, 2, 1), calendar: utcCalendar())

        XCTAssertEqual(try store.fetchSchedule(), schedule)
        XCTAssertEqual(try legacy.fetchRate().amountPerUnit, 0.80)
    }

    func testRejectsDuplicateDatesAndInvalidAmounts() throws {
        let sameDate = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
        XCTAssertThrowsError(try MileageRateScheduleStore.validated(MileageRateSchedule(
            baseRate: .default,
            rules: [
                MileageRateRule(effectiveFrom: sameDate, rate: .default),
                MileageRateRule(effectiveFrom: sameDate, rate: .default)
            ]
        ))) { error in
            XCTAssertEqual(error as? MileageRateScheduleError, .duplicateEffectiveDate)
        }
        XCTAssertThrowsError(try MileageRateScheduleStore.validated(MileageRateSchedule(
            baseRate: MileageRate(amountPerUnit: -.ulpOfOne, unit: .miles)
        )))
    }

    func testUnitConversionDoesNotChangeValue() {
        let miles = MileageRate(amountPerUnit: 0.725, unit: .miles)
        let kilometers = miles.converted(to: .kilometers)
        let schedule = MileageRateSchedule(baseRate: kilometers)

        XCTAssertEqual(
            schedule.mileageValue(meters: 10_000, on: Date()),
            10_000 * miles.amountPerMeter,
            accuracy: 0.000_000_001
        )
    }

    private func rule(_ year: Int, _ month: Int, _ day: Int, amount: Double) -> MileageRateRule {
        MileageRateRule(
            effectiveFrom: MileageRateEffectiveDate(year: year, month: month, day: day),
            rate: MileageRate(amountPerUnit: amount, unit: .miles)
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
