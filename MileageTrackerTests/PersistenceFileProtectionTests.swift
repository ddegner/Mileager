import AppCore
import CoreData
import Foundation
import XCTest

final class PersistenceFileProtectionTests: XCTestCase {
    func testStoreDescriptionsPinCompleteUntilFirstUserAuthentication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceProtectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = try PersistenceController(mode: .localOnly, storeDirectory: directory)

        let descriptions = persistence.container.persistentStoreDescriptions
        XCTAssertEqual(descriptions.count, 2)
        for description in descriptions {
            let option = description.options[NSPersistentStoreFileProtectionKey] as? FileProtectionType
            XCTAssertEqual(
                option,
                .completeUntilFirstUserAuthentication,
                "Store \(description.configuration ?? "?") must pin Class C protection"
            )
        }
    }

    func testInMemoryStoresDoNotSetFileProtection() throws {
        let persistence = try PersistenceController(mode: .localOnly, inMemory: true)

        for description in persistence.container.persistentStoreDescriptions {
            XCTAssertNil(description.options[NSPersistentStoreFileProtectionKey])
        }
    }
}
