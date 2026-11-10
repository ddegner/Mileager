import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class IRSRateDefaultScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testFreshUSDUsesBundledIRSWithoutPretendingToBeAnExplicitChoice() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = MileageRateScheduleStore(context: context)
        let value = try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)

        XCTAssertEqual(value.baseRate, IRSBusinessRatePeriod.bundledCurrent.rate)
        XCTAssertEqual(value.rules.first?.irsSource, .bundledCurrent)
        XCTAssertEqual(value.irsFollowingFrom, .init(year: 2026, month: 7, day: 1))
        XCTAssertTrue(value.isAutomaticIRSDefault)
        XCTAssertNil(value.sourceSelectionUpdatedAt)
        XCTAssertEqual(try store.fetchSchedule(), value)
        XCTAssertNil(try MileageRateStore(context: context).fetchPersistedRate())
        XCTAssertEqual(try rows(in: context, key: MileageRateStore.preferenceKey).count, 0)
        XCTAssertEqual(try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now.addingTimeInterval(1)), value)
    }

    func testFreshNonUSDUsesCustomAndLaterUSDDoesNotChangeSavedChoice() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = MileageRateScheduleStore(context: persistence.container.viewContext)
        let custom = try store.initializeDefaultScheduleIfNeeded(currencyCode: "EUR", now: now)
        XCTAssertEqual(custom.baseRate.amountPerUnit, 0)
        XCTAssertTrue(custom.requiresCustomRate)
        XCTAssertNil(try MileageRateStore(context: persistence.container.viewContext).fetchPersistedRate())
        XCTAssertNil(custom.irsFollowingFrom)
        XCTAssertFalse(custom.isAutomaticIRSDefault)
        XCTAssertEqual(try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD"), custom)
        XCTAssertNil(MileageRateSchedule.default.irsFollowingFrom)
    }

    func testSavedCustomScheduleAndLegacyRatesBlockAutomaticDefault() throws {
        for key in [MileageRateScheduleStore.preferenceKey, MileageRateStore.preferenceKey, MileageRateStore.legacyPreferenceKey] {
            let persistence = try PersistenceController(inMemory: true)
            let context = persistence.container.viewContext
            let rate = MileageRate(amountPerUnit: 0.67, unit: .miles)
            let preference = PreferenceStore(context: context, key: key)
            switch key {
            case MileageRateScheduleStore.preferenceKey:
                try preference.write(MileageRateSchedule(baseRate: rate))
            case MileageRateStore.preferenceKey:
                try preference.write(rate)
            default:
                try preference.write(LegacyRate(businessCentsPerMile: 67))
            }
            let value = try MileageRateScheduleStore(context: context).initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)
            XCTAssertEqual(value.baseRate, rate)
            XCTAssertTrue(value.rules.isEmpty)
            XCTAssertNil(value.irsFollowingFrom)
            XCTAssertFalse(value.isAutomaticIRSDefault)
        }
    }

    func testPopulatedLegacyStoreWithoutSavedRateKeepsPreviousImplicitAmount() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        try PreferenceStore(context: context, key: "existing-preference").write("saved before this feature")
        let value = try MileageRateScheduleStore(context: context).initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)
        XCTAssertEqual(value.baseRate.amountPerUnit, 0.725)
        XCTAssertNil(value.irsFollowingFrom)
        XCTAssertFalse(value.isAutomaticIRSDefault)
    }

    func testUnreadableRateBytesNeverCountAsFreshOrGetOverwritten() throws {
        for key in [MileageRateScheduleStore.preferenceKey, MileageRateStore.preferenceKey, MileageRateStore.legacyPreferenceKey] {
            let persistence = try PersistenceController(inMemory: true)
            let context = persistence.container.viewContext
            let row = insertRaw(Data("unreadable saved preference".utf8), key: key, updatedAt: now, in: context)
            try context.save()
            let value = try MileageRateScheduleStore(context: context).initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)
            XCTAssertNil(value.irsFollowingFrom)
            XCTAssertEqual(value.baseRate.amountPerUnit, 0.725)
            XCTAssertEqual(row.value(forKey: "valueData") as? Data, Data("unreadable saved preference".utf8))
        }
    }

    func testAutomaticRefreshRemainsLowPriorityButExplicitCustomPersists() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = MileageRateScheduleStore(context: context)
        let seed = try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)
        let refreshed = try IRSBusinessRateScheduleUpdater.apply(periods: [.bundledCurrent], to: seed,
            followingFrom: try XCTUnwrap(seed.irsFollowingFrom), now: now.addingTimeInterval(30))
        XCTAssertTrue(refreshed.isAutomaticIRSDefault)
        XCTAssertNil(refreshed.sourceSelectionUpdatedAt)
        _ = try store.saveSchedule(refreshed, now: now.addingTimeInterval(30))
        XCTAssertNil(try MileageRateStore(context: context).fetchPersistedRate())
        let custom = try store.saveSchedule(IRSBusinessRateScheduleUpdater.stopFollowing(refreshed, now: now.addingTimeInterval(60)))
        XCTAssertFalse(custom.isAutomaticIRSDefault)
        XCTAssertNotNil(custom.sourceSelectionUpdatedAt)
        XCTAssertNil(custom.irsFollowingFrom)
        XCTAssertEqual(try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD"), custom)
        XCTAssertEqual(try store.saveSchedule(seed), custom, "A stale automatic save cannot replace an explicit choice")
    }

    func testExplicitIRSAdoptionPromotesAutomaticDefaultWithoutChangingStableRuleID() throws {
        let seed = IRSBusinessRateScheduleUpdater.initialSchedule(currencyCode: "USD", now: now)
        let adopted = try IRSBusinessRateScheduleUpdater.adoptHistory(periods: [.bundledCurrent], to: seed,
            followingFrom: IRSBusinessRatePeriod.bundledCurrent.effectiveFrom, now: now.addingTimeInterval(30))
        XCTAssertFalse(adopted.isAutomaticIRSDefault)
        XCTAssertEqual(adopted.sourceSelectionUpdatedAt, now.addingTimeInterval(30))
        XCTAssertEqual(adopted.rules.first?.id, seed.rules.first?.id)
    }

    func testLegacyImportOverridesEntireBootstrapWithoutInventingAnEdit() throws {
        for key in [MileageRateStore.preferenceKey, MileageRateStore.legacyPreferenceKey] {
            let persistence = try PersistenceController(inMemory: true)
            let context = persistence.container.viewContext
            let store = MileageRateScheduleStore(context: context)
            _ = try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)
            let seedRow = try XCTUnwrap(rows(in: context, key: MileageRateScheduleStore.preferenceKey).first)
            let seedBytes = seedRow.value(forKey: "valueData") as? Data
            let preference = PreferenceStore(context: context, key: key)
            if key == MileageRateStore.preferenceKey { try preference.write(MileageRate(amountPerUnit: 0.81, unit: .miles)) }
            else { try preference.write(LegacyRate(businessCentsPerMile: 81)) }

            let value = try store.fetchSchedule()
            XCTAssertEqual(value.baseRate.amountPerUnit, 0.81)
            XCTAssertTrue(value.rules.isEmpty)
            XCTAssertTrue(value.deletedRuleIDs.isEmpty)
            XCTAssertNil(value.irsFollowingFrom)
            XCTAssertEqual(seedRow.value(forKey: "valueData") as? Data, seedBytes)
            XCTAssertEqual(seedRow.value(forKey: "updatedAt") as? Date, now)
        }
    }

    func testLaterSavedIRSHistorySurvivesInterveningLegacyRead() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = MileageRateScheduleStore(context: context)
        let seed = try store.initializeDefaultScheduleIfNeeded(currencyCode: "USD", now: now)
        try PreferenceStore(context: context, key: MileageRateStore.preferenceKey).write(MileageRate(amountPerUnit: 0.81, unit: .miles))
        XCTAssertTrue(try store.fetchSchedule().rules.isEmpty)
        var actual = try IRSBusinessRateScheduleUpdater.adoptHistory(periods: [.bundledCurrent], to: seed,
            followingFrom: IRSBusinessRatePeriod.bundledCurrent.effectiveFrom, now: now.addingTimeInterval(-60))
        actual.baseRate = MileageRate(amountPerUnit: 0.70, unit: .miles)
        let actualRow = insertRaw(try JSONEncoder().encode(actual), key: MileageRateScheduleStore.preferenceKey,
            updatedAt: now.addingTimeInterval(-60), in: context)
        let actualID = actualRow.value(forKey: "id") as? UUID
        try context.save()

        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(try store.fetchSchedule(), actual)
        let saved = try XCTUnwrap(rows(in: context, key: MileageRateScheduleStore.preferenceKey).first)
        XCTAssertEqual(saved.value(forKey: "id") as? UUID, actualID)
        XCTAssertEqual(actual.rules.first?.id, seed.rules.first?.id)
        XCTAssertTrue(actual.deletedRuleIDs.isEmpty)
    }

    func testLegacyScheduleDecodesAsExplicitCustomWhenMarkerIsAbsent() throws {
        let encoded = try JSONEncoder().encode(MileageRateSchedule(baseRate: .init(amountPerUnit: 0.81, unit: .miles)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isAutomaticIRSDefault")
        object.removeValue(forKey: "requiresCustomRate")
        let decoded = try JSONDecoder().decode(MileageRateSchedule.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isAutomaticIRSDefault)
        XCTAssertFalse(decoded.requiresCustomRate)
        XCTAssertNil(decoded.irsFollowingFrom)
        XCTAssertEqual(decoded.baseRate.amountPerUnit, 0.81)
    }

    private struct LegacyRate: Codable { var businessCentsPerMile: Double }

    private func rows(in context: NSManagedObjectContext, key: String) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PreferenceEntity")
        request.predicate = NSPredicate(format: "key == %@", key)
        return try context.fetch(request)
    }

    @discardableResult
    private func insertRaw(_ data: Data, key: String, updatedAt: Date, in context: NSManagedObjectContext) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: "PreferenceEntity", into: context)
        row.setValue(UUID(), forKey: "id")
        row.setValue(key, forKey: "key")
        row.setValue(data, forKey: "valueData")
        row.setValue(updatedAt, forKey: "updatedAt")
        return row
    }
}
