import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class CustomMileageRateSettingsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        return value
    }

    func testCustomSavePreservesPastAndFutureCustomButRemovesFutureIRS() throws {
        let original = scheduleWithFutureRates()
        let futureIRS = try XCTUnwrap(original.rules.first { $0.effectiveFrom == logical(2027, 1, 1) })
        let rate = MileageRate(amountPerUnit: 0.83, unit: .miles)
        let result = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            rate, to: original, effectiveFrom: logical(2026, 10, 4), now: date(2026, 10, 4)
        )

        XCTAssertNil(result.irsFollowingFrom)
        XCTAssertFalse(result.isAutomaticIRSDefault)
        XCTAssertFalse(result.requiresCustomRate)
        XCTAssertEqual(result.baseRate, original.baseRate)
        XCTAssertEqual(result.rules.first, original.rules.first)
        XCTAssertEqual(result.rate(on: date(2026, 10, 3), calendar: calendar), original.rate(on: date(2026, 10, 3), calendar: calendar))
        XCTAssertEqual(result.rate(on: date(2026, 10, 4), calendar: calendar), rate)
        XCTAssertEqual(result.rate(on: date(2027, 1, 1), calendar: calendar), rate)
        XCTAssertEqual(result.rate(on: date(2027, 4, 1), calendar: calendar).amountPerUnit, 0.91)
        XCTAssertFalse(result.rules.contains { $0.id == futureIRS.id })
        XCTAssertEqual(result.deletedRuleIDs[futureIRS.id], futureIRS.updatedAt, "A clock-ahead IRS rule must stay deleted after sync")
        XCTAssertEqual(try MileageRateScheduleStore.validated(result), result)
    }

    func testCustomSaveReusesSameDateIdentityAndBeatsClockAheadCopy() throws {
        let original = scheduleWithFutureRates()
        let futureIRS = try XCTUnwrap(original.rules.first { $0.effectiveFrom == logical(2027, 1, 1) })
        let result = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0.86, unit: .miles), to: original,
            effectiveFrom: logical(2027, 1, 1), now: date(2026, 10, 4)
        )
        let custom = try XCTUnwrap(result.rules.first { $0.effectiveFrom == logical(2027, 1, 1) })
        XCTAssertEqual(custom.id, futureIRS.id)
        XCTAssertNil(custom.irsSource)
        XCTAssertGreaterThan(custom.updatedAt, futureIRS.updatedAt)
        XCTAssertEqual(result.rules.count, original.rules.count)
        XCTAssertEqual(result.rate(on: date(2026, 12, 31), calendar: calendar), original.rate(on: date(2026, 12, 31), calendar: calendar))
        XCTAssertEqual(try MileageRateScheduleStore.validated(result), result)
    }

    func testCustomSaveAlsoCleansIRSAfterPreviouslyStoppingUpdates() throws {
        let stopped = IRSBusinessRateScheduleUpdater.stopFollowing(scheduleWithFutureRates())
        let result = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0.81, unit: .miles), to: stopped,
            effectiveFrom: logical(2026, 10, 4), now: date(2026, 10, 4)
        )
        XCTAssertEqual(result.rate(on: date(2027, 1, 1), calendar: calendar).amountPerUnit, 0.81)
    }

    func testCustomAndIRSChoicesClearUnsetWhileExplicitZeroRemainsValid() throws {
        let unset = IRSBusinessRateScheduleUpdater.initialSchedule(currencyCode: "EUR", now: date(2026, 10, 4))
        XCTAssertTrue(unset.requiresCustomRate)
        XCTAssertEqual(try JSONDecoder().decode(MileageRateSchedule.self, from: JSONEncoder().encode(unset)), unset)
        let zero = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0, unit: .kilometers), to: unset,
            effectiveFrom: logical(2026, 10, 4), now: date(2026, 10, 4)
        )
        XCTAssertFalse(zero.requiresCustomRate)
        XCTAssertEqual(zero.rate(on: date(2026, 10, 4), calendar: calendar).amountPerUnit, 0)
        let adopted = try IRSBusinessRateScheduleUpdater.adoptHistory(
            periods: [.bundledCurrent], to: unset, followingFrom: IRSBusinessRatePeriod.bundledCurrent.effectiveFrom,
            now: date(2026, 10, 4), calendar: calendar
        )
        XCTAssertFalse(adopted.requiresCustomRate)
        XCTAssertNotNil(adopted.irsFollowingFrom)
    }

    func testAtomicSavePersistsScheduleCurrencyUnitAndLegacyAmount() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = MileageRateScheduleStore(context: context)
        let units = UnitsCurrencyStore(context: context)
        let custom = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0.45, unit: .kilometers), to: .default,
            effectiveFrom: logical(2026, 10, 4), now: date(2026, 10, 4)
        )
        let saved = try store.saveSchedule(custom, currencyCode: "EUR", distanceUnitPreference: .kilometers,
                                           now: date(2026, 10, 4), calendar: calendar)
        XCTAssertEqual(try MileageRateScheduleStore(context: context).fetchSchedule(), saved)
        XCTAssertEqual(try units.fetchCurrencyCode(), "EUR")
        XCTAssertEqual(try units.fetchDistanceUnitPreference(), .kilometers)
        XCTAssertEqual(try MileageRateStore(context: context).fetchRate(), .init(amountPerUnit: 0.45, unit: .kilometers))
    }

    func testAtomicSaveRollsBackEverySettingAfterWritesFail() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = MileageRateScheduleStore(context: context)
        let units = UnitsCurrencyStore(context: context)
        let original = try store.saveSchedule(.init(baseRate: .init(amountPerUnit: 0.7, unit: .miles)),
            currencyCode: "USD", distanceUnitPreference: .miles, now: date(2026, 10, 4), calendar: calendar)
        let custom = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0.45, unit: .kilometers), to: original,
            effectiveFrom: logical(2026, 10, 4), now: date(2026, 10, 4)
        )
        XCTAssertThrowsError(try store.saveSchedule(custom, currencyCode: "EUR", distanceUnitPreference: .kilometers,
            now: date(2026, 10, 4), calendar: calendar, beforeSave: { throw SaveFailure.expected }))
        XCTAssertEqual(try store.fetchSchedule(), original)
        XCTAssertEqual(try units.fetchCurrencyCode(), "USD")
        XCTAssertEqual(try units.fetchDistanceUnitPreference(), .miles)
        XCTAssertEqual(try MileageRateStore(context: context).fetchRate(), original.baseRate)
        XCTAssertFalse(context.hasChanges)
    }

    func testInvalidAmountDateCurrencyAndNonUSDIRSCombinationAreRejected() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = MileageRateScheduleStore(context: persistence.container.viewContext)
        for amount in [-1.0, .infinity, .nan] {
            XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.applyCustomRate(
                .init(amountPerUnit: amount, unit: .miles), to: .default,
                effectiveFrom: logical(2026, 10, 4)
            ))
        }
        XCTAssertThrowsError(try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .default, to: .default, effectiveFrom: logical(2026, 2, 30)
        ))
        for code in ["ZZZ", "eur", ""] {
            XCTAssertThrowsError(try store.saveSchedule(.default, currencyCode: code, distanceUnitPreference: .miles))
        }
        XCTAssertThrowsError(try store.saveSchedule(scheduleWithFutureRates(), currencyCode: "EUR", distanceUnitPreference: .kilometers))
    }

    func testUnsetBootstrapYieldsToSavedCustomIncludingExplicitZero() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = date(2026, 10, 4)
        let unset = IRSBusinessRateScheduleUpdater.initialSchedule(currencyCode: "EUR", now: now)
        let saved = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0, unit: .kilometers), to: unset,
            effectiveFrom: logical(2026, 10, 1), now: now.addingTimeInterval(-60)
        )
        try insert(unset, at: now, into: context)
        let savedID = try insert(saved, at: now.addingTimeInterval(-60), into: context)
        try context.save()
        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        let result = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertEqual(result, saved)
        XCTAssertFalse(result.requiresCustomRate)
        let request = NSFetchRequest<NSManagedObject>(entityName: "PreferenceEntity")
        XCTAssertEqual(try context.fetch(request).first?.value(forKey: "id") as? UUID, savedID)
    }

    func testDeletedFutureIRSDoesNotReturnWhenOlderScheduleSyncs() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let original = scheduleWithFutureRates()
        let now = date(2026, 10, 4)
        let custom = try IRSBusinessRateScheduleUpdater.applyCustomRate(
            .init(amountPerUnit: 0.83, unit: .miles), to: original,
            effectiveFrom: logical(2026, 10, 4), now: now
        )
        try insert(original, at: now.addingTimeInterval(-60), into: context)
        try insert(custom, at: now, into: context)
        try context.save()
        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        let merged = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertNil(merged.irsFollowingFrom)
        XCTAssertEqual(merged.rate(on: date(2027, 1, 1), calendar: calendar).amountPerUnit, 0.83)
        XCTAssertEqual(merged.rate(on: date(2027, 4, 1), calendar: calendar).amountPerUnit, 0.91)
    }

    private func scheduleWithFutureRates() -> MileageRateSchedule {
        let current = IRSBusinessRatePeriod.bundledCurrent
        let future = IRSBusinessRatePeriod(effectiveFrom: logical(2027, 1, 1), effectiveThrough: logical(2027, 12, 31),
            amountPerMile: 0.82, sourceURL: current.sourceURL, rateEvidence: "82", periodEvidence: "2027")
        return MileageRateSchedule(baseRate: .init(amountPerUnit: 0.6, unit: .miles), rules: [
            MileageRateRule(effectiveFrom: current.effectiveFrom, rate: current.rate, updatedAt: date(2026, 7, 1), irsSource: current),
            MileageRateRule(effectiveFrom: future.effectiveFrom, rate: future.rate, updatedAt: date(2026, 12, 1), irsSource: future),
            MileageRateRule(effectiveFrom: logical(2027, 4, 1), rate: .init(amountPerUnit: 0.91, unit: .miles), updatedAt: date(2026, 9, 1))
        ], irsFollowingFrom: current.effectiveFrom, sourceSelectionUpdatedAt: date(2026, 7, 1))
    }

    @discardableResult
    private func insert(_ schedule: MileageRateSchedule, at date: Date, into context: NSManagedObjectContext) throws -> UUID {
        let row = NSEntityDescription.insertNewObject(forEntityName: "PreferenceEntity", into: context)
        let id = UUID()
        row.setValue(id, forKey: "id")
        row.setValue(MileageRateScheduleStore.preferenceKey, forKey: "key")
        row.setValue(try JSONEncoder().encode(schedule), forKey: "valueData")
        row.setValue(date, forKey: "updatedAt")
        return id
    }

    private func logical(_ year: Int, _ month: Int, _ day: Int) -> MileageRateEffectiveDate {
        .init(year: year, month: month, day: day)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private enum SaveFailure: Error { case expected }
}
