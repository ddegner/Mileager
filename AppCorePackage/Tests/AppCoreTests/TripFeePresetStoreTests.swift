import XCTest
@testable import AppCore

final class TripFeePresetStoreTests: XCTestCase {
    func testSaveNormalizesEmptyInvalidAndDuplicatePresets() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripFeePresetStore(context: persistence.container.viewContext)

        let firstTollID = UUID()
        let saved = try store.savePresets([
            TripFeePreset(id: UUID(), category: .parking, label: " Garage ", amount: 12, sortOrder: 2),
            TripFeePreset(id: UUID(), category: .toll, label: "", amount: 4, sortOrder: 0),
            TripFeePreset(id: firstTollID, category: .toll, label: " Bridge ", amount: 3.5, sortOrder: 1),
            TripFeePreset(id: UUID(), category: .toll, label: "bridge", amount: 7, sortOrder: 3),
            TripFeePreset(id: UUID(), category: .parking, label: "Meter", amount: .nan, sortOrder: 4)
        ])

        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.map(\.id), [firstTollID, saved[1].id])
        XCTAssertEqual(saved.map(\.category), [.toll, .parking])
        XCTAssertEqual(saved.map(\.label), ["Bridge", "Garage"])
        XCTAssertEqual(saved.map(\.amount), [3.5, 12])
        XCTAssertEqual(saved.map(\.sortOrder), [0, 1])
        XCTAssertEqual(try store.fetchPresets(), saved)
    }

    func testDuplicateLabelsAreAllowedAcrossCategories() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripFeePresetStore(context: persistence.container.viewContext)

        let saved = try store.savePresets([
            TripFeePreset(category: .toll, label: "Bridge", amount: 4, sortOrder: 0),
            TripFeePreset(category: .parking, label: "Bridge", amount: 9, sortOrder: 1)
        ])

        XCTAssertEqual(saved.map(\.category), [.toll, .parking])
        XCTAssertEqual(saved.map(\.label), ["Bridge", "Bridge"])
        XCTAssertEqual(saved.map(\.amount), [4, 9])
    }
}
