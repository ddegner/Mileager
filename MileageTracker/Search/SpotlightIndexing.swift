import AppIntents
import CoreSpotlight
import Foundation

/// Seam over `CSSearchableIndex` so the indexer is testable with a spy and the
/// system index is touched in exactly one place.
protocol SpotlightIndexing: Sendable {
    func index(_ entities: [TripAppEntity]) async throws
    func delete(ids: [UUID]) async throws
    func index(reports: [MonthlyMileageReportEntity]) async throws
    func delete(reportIDs: [String]) async throws
    func deleteAll() async throws
}

struct SystemSpotlightIndex: SpotlightIndexing {
    func index(_ entities: [TripAppEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func delete(ids: [UUID]) async throws {
        // Entities are donated with their `id.uuidString` as the searchable
        // item identifier, so plain item deletion removes them.
        try await CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: ids.map(\.uuidString))
    }

    func index(reports: [MonthlyMileageReportEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(reports)
    }

    func delete(reportIDs: [String]) async throws {
        // Month entities use their raw string ID ("2026-06") as the item
        // identifier; no collision with trips' UUID strings.
        try await CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: reportIDs)
    }

    func deleteAll() async throws {
        try await CSSearchableIndex.default().deleteAllSearchableItems()
    }
}
