import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class MileageRateStoreTests: XCTestCase {
    func testFetchReturnsDefaultRateWhenPreferenceIsMissing() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = MileageRateStore(context: persistence.container.viewContext)

        let rate = try store.fetchRate()
        XCTAssertEqual(rate.amountPerUnit, 0.76, accuracy: 0.001)
        XCTAssertEqual(rate.unit, .miles)
    }

    func testSavePersistsCustomRate() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = MileageRateStore(context: persistence.container.viewContext)

        let saved = try store.saveRate(MileageRate(amountPerUnit: 0.80, unit: .miles))

        XCTAssertEqual(saved.amountPerUnit, 0.80, accuracy: 0.001)
        XCTAssertEqual(try store.fetchRate().amountPerUnit, 0.80, accuracy: 0.001)
    }

    func testInvalidRatesAreRejected() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = MileageRateStore(context: persistence.container.viewContext)

        XCTAssertThrowsError(try store.saveRate(MileageRate(amountPerUnit: .nan, unit: .miles)))
        XCTAssertThrowsError(try store.saveRate(MileageRate(amountPerUnit: -1, unit: .miles)))
        XCTAssertEqual(try store.fetchRate(), .default)
    }

    func testLegacyV1RateMigratesToV2PerMile() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        // Seed a v1 blob exactly as the old app wrote it.
        let legacy = PreferenceStore(context: context, key: MileageRateStore.legacyPreferenceKey)
        try legacy.write(LegacySeed(businessCentsPerMile: 67.0))

        let store = MileageRateStore(context: context)
        let migrated = try store.fetchRate()

        XCTAssertEqual(migrated.amountPerUnit, 0.67, accuracy: 0.0001)
        XCTAssertEqual(migrated.unit, .miles)

        // Migration is persisted under the v2 key.
        let v2 = PreferenceStore(context: context, key: MileageRateStore.preferenceKey)
        let stored: MileageRate? = try v2.read()
        XCTAssertEqual(stored?.amountPerUnit ?? 0, 0.67, accuracy: 0.0001)
    }

    func testUnitConversionKeepsPayoutInvariant() {
        let perMile = MileageRate(amountPerUnit: 0.725, unit: .miles)
        let perKm = perMile.converted(to: .kilometers)

        XCTAssertEqual(perKm.unit, .kilometers)
        // Same trip distance must reimburse the same amount in either quoting unit.
        let meters = 12_345.0
        XCTAssertEqual(meters * perMile.amountPerMeter, meters * perKm.amountPerMeter, accuracy: 0.0000001)
        // 0.725/mi ≈ 0.4505/km
        XCTAssertEqual(perKm.amountPerUnit, 0.725 / 1.609344, accuracy: 0.0001)
        // Round-trip returns the original value.
        XCTAssertEqual(perKm.converted(to: .miles).amountPerUnit, 0.725, accuracy: 0.0000001)
    }

    private struct LegacySeed: Codable {
        var businessCentsPerMile: Double
    }
}
