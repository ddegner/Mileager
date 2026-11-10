import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class UnitsCurrencyStoreTests: XCTestCase {
    func testDefaultsWhenNothingStored() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = UnitsCurrencyStore(context: persistence.container.viewContext)

        XCTAssertEqual(try store.fetchDistanceUnitPreference(), .system)
        // Default currency comes from the machine locale; just assert shape.
        let code = try store.fetchCurrencyCode()
        XCTAssertEqual(code.count, 3)
    }

    func testPersistsDistanceUnitPreference() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = UnitsCurrencyStore(context: context)

        try store.saveDistanceUnitPreference(.kilometers)
        XCTAssertEqual(try store.fetchDistanceUnitPreference(), .kilometers)

        // A fresh store instance over the same context reads the same value.
        XCTAssertEqual(try UnitsCurrencyStore(context: context).fetchDistanceUnitPreference(), .kilometers)
    }

    func testDistanceUnitAndConvertedRateSaveAtomically() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let units = UnitsCurrencyStore(context: context)
        let rates = MileageRateStore(context: context)
        let originalRate = try rates.saveRate(MileageRate(amountPerUnit: 0.80, unit: .miles))

        let converted = try units.saveDistanceUnitPreference(
            .kilometers,
            preservingValueOf: originalRate
        )

        XCTAssertEqual(try units.fetchDistanceUnitPreference(), .kilometers)
        XCTAssertEqual(try rates.fetchRate(), converted)
        XCTAssertEqual(converted.unit, .kilometers)
        XCTAssertEqual(converted.amountPerMeter, originalRate.amountPerMeter, accuracy: 0.000_000_001)
    }

    func testDistanceUnitAndRateRollbackTogetherWhenSavePreparationFails() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let units = UnitsCurrencyStore(context: context)
        let rates = MileageRateStore(context: context)
        try units.saveDistanceUnitPreference(.miles)
        let originalRate = try rates.saveRate(MileageRate(amountPerUnit: 0.80, unit: .miles))

        XCTAssertThrowsError(try units.saveDistanceUnitPreference(
            .kilometers,
            preservingValueOf: originalRate,
            beforeSave: { throw AtomicSettingsTestError.expected }
        )) { error in
            XCTAssertEqual(error as? AtomicSettingsTestError, .expected)
        }

        XCTAssertEqual(try units.fetchDistanceUnitPreference(), .miles)
        XCTAssertEqual(try rates.fetchRate(), originalRate)
    }

    func testPersistsCurrencyCode() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = UnitsCurrencyStore(context: context)

        try store.saveCurrencyCode("EUR")
        XCTAssertEqual(try store.fetchCurrencyCode(), "EUR")
        XCTAssertEqual(try UnitsCurrencyStore(context: context).fetchCurrencyCode(), "EUR")
    }

    func testDefaultCurrencyCodeForLocales() {
        XCTAssertEqual(UnitsCurrencyStore.defaultCurrencyCode(for: Locale(identifier: "en_US")), "USD")
        XCTAssertEqual(UnitsCurrencyStore.defaultCurrencyCode(for: Locale(identifier: "de_DE")), "EUR")
        XCTAssertEqual(UnitsCurrencyStore.defaultCurrencyCode(for: Locale(identifier: "en_GB")), "GBP")
    }
}

private enum AtomicSettingsTestError: Error {
    case expected
}
