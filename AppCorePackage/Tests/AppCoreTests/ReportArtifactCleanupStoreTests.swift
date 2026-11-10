import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class ReportArtifactCleanupStoreTests: XCTestCase {
    func testConfirmedCleanupDeletesReportsAndMetadataButNotTrips() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let report = ReportSnapshotEntity.insert(into: context)
        report.id = UUID()
        report.csvText = "csv"
        let metadata = PreferenceEntity.insert(into: context)
        metadata.id = UUID()
        metadata.key = "\(ReportArtifactCleanupStore.legacyMetadataKeyPrefix).month.2026-01"
        metadata.valueData = Data()
        let unrelated = PreferenceEntity.insert(into: context)
        unrelated.id = UUID()
        unrelated.key = MileageRateScheduleStore.preferenceKey
        unrelated.valueData = Data()
        try context.save()

        let store = ReportArtifactCleanupStore(context: context)
        XCTAssertEqual(try store.legacyArtifactCount(), 2)
        XCTAssertEqual(try store.confirmAndDelete(), 2)
        XCTAssertEqual(try store.legacyArtifactCount(), 0)
        XCTAssertEqual(try store.fetchDecision()?.deletesArtifacts, true)

        let preferences = try context.fetch(PreferenceEntity.fetchRequest())
        XCTAssertTrue(preferences.contains { $0.key == MileageRateScheduleStore.preferenceKey })
    }

    func testKeepForNowDoesNotDeleteAndConfirmedCleanupIsIdempotent() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let report = ReportSnapshotEntity.insert(into: context)
        report.id = UUID()
        report.csvText = "csv"
        try context.save()
        let store = ReportArtifactCleanupStore(context: context)

        try store.keepForNow()
        XCTAssertEqual(try store.legacyArtifactCount(), 1)
        XCTAssertEqual(try store.deleteAgainIfConfirmed(), 0)

        XCTAssertEqual(try store.confirmAndDelete(), 1)
        XCTAssertEqual(try store.deleteAgainIfConfirmed(), 0)
    }
}
