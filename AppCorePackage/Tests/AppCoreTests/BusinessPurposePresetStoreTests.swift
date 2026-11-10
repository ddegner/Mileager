import CoreData
import XCTest
@testable import AppCore

final class BusinessPurposePresetStoreTests: XCTestCase {
    func testFetchReturnsDefaultsWhenPreferenceIsMissing() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BusinessPurposePresetStore(context: persistence.container.viewContext)

        XCTAssertEqual(BusinessPurposePresetStore.defaultPurposes, ["Client meeting", "Site visit", "Supplies"])
        XCTAssertEqual(try store.fetchPurposes(), BusinessPurposePresetStore.defaultPurposes)
    }

    func testSavePersistsPurposesInOrder() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BusinessPurposePresetStore(context: persistence.container.viewContext)

        let saved = try store.savePurposes(["Court", "Client lunch", "Materials"])

        XCTAssertEqual(saved, ["Court", "Client lunch", "Materials"])
        XCTAssertEqual(try store.fetchPurposes(), ["Court", "Client lunch", "Materials"])
    }

    func testSaveNormalizesEmptyAndDuplicatePurposes() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BusinessPurposePresetStore(context: persistence.container.viewContext)

        let saved = try store.savePurposes([
            " Client meeting ",
            "",
            "client meeting",
            "Site visit",
            "  SITE VISIT  ",
            "\nBank\t"
        ])

        XCTAssertEqual(saved, ["Client meeting", "Site visit", "Bank"])
        XCTAssertEqual(try store.fetchPurposes(), ["Client meeting", "Site visit", "Bank"])
    }

    func testSavingDefaultPurposesRestoresDefaults() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = BusinessPurposePresetStore(context: persistence.container.viewContext)

        try store.savePurposes(["Custom"])
        let saved = try store.savePurposes(BusinessPurposePresetStore.defaultPurposes)

        XCTAssertEqual(saved, BusinessPurposePresetStore.defaultPurposes)
        XCTAssertEqual(try store.fetchPurposes(), BusinessPurposePresetStore.defaultPurposes)
    }

    func testCompletionSuggestionsPreferPrefixesAndIgnoreExactMatch() {
        let purposes = ["Client meeting", "Site visit", "Meeting follow-up", "Supplies"]

        XCTAssertEqual(
            BusinessPurposePresetStore.completionSuggestions(for: "meet", in: purposes),
            ["Meeting follow-up", "Client meeting"]
        )
        XCTAssertEqual(
            BusinessPurposePresetStore.completionSuggestions(for: "SITE VISIT", in: purposes),
            []
        )
        XCTAssertEqual(
            BusinessPurposePresetStore.completionSuggestions(for: "", in: purposes, limit: 2),
            ["Client meeting", "Site visit"]
        )
    }
}
