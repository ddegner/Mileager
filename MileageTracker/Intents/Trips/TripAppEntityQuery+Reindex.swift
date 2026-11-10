import AppCore
import AppIntents
import CoreSpotlight
import Foundation

/// iOS 27 system-driven reindexing: Spotlight asks the app to refresh its
/// donated entities (e.g. after an index rebuild). Requests are not
/// user-interactive, so an unavailable store or a disabled Siri & Search
/// toggle means "do nothing", never an error. The methods are nonisolated
/// because `CSSearchableIndexDescription` is non-Sendable and cannot cross
/// into the main actor; it is intentionally unused — the app donates to the
/// single default index — so only Sendable values hop to the indexer.
@available(iOS 27, *)
extension TripAppEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [UUID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await Self.performReindex(ids: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await Self.performReindex(ids: nil)
    }

    /// nil ids = reindex everything.
    @MainActor
    private static func performReindex(ids: [UUID]?) async {
        guard let model = TripIntentDataProvider.availableModel(),
              let indexer = model.spotlightIndexer else { return }
        if let ids {
            indexer.reindex(ids: ids) { [weak model] id in
                try model?.tripStore.fetchTripIfExists(id: id)
            }
        } else {
            indexer.reindexAll { [weak model] in
                guard let model else { return [] }
                return try model.tripStore.fetchTrips(from: nil, to: nil)
            }
        }
        await indexer.drain()
    }
}
