import AppCore
import AppIntents
import Foundation

/// Resolves `TripAppEntity` values for Siri, Shortcuts, and Spotlight. Every
/// path fails soft to an empty result when the store is unavailable (no model
/// yet, or before first unlock) — throwing would surface raw errors in system
/// UI for a condition the user resolves by unlocking the phone.
struct TripAppEntityQuery: EntityQuery {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    private static let stringSearchWindow = 500
    private static let stringSearchResultCap = 25
    private static let suggestedPerGroupCap = 5

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TripAppEntity] {
        guard let model = (try? await TripIntentDataProvider.readyModel()) else { return [] }
        let mostRecentID = Self.mostRecentTrip(in: model)?.id
        // No cap: the system bounds request sizes, per-ID lookup is cheap, and
        // silently dropping the tail would break large Shortcuts collections.
        return identifiers.compactMap { id -> TripAppEntity? in
            guard let trip = try? model.tripStore.fetchTripIfExists(id: id) else { return nil }
            return Self.entity(
                for: trip,
                in: model,
                isMostRecentReference: trip.id == mostRecentID
            )
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [TripAppEntity] {
        guard let model = (try? await TripIntentDataProvider.readyModel()) else { return [] }
        let trips = Self.recentTrips(in: model)
        let mostRecentID = Self.mostRecentTrip(in: model)?.id
        let unclassified = trips.filter { $0.classification == nil }
            .prefix(Self.suggestedPerGroupCap)
        // Not-a-Drive trips stay out of suggestions for the same reason the
        // Spotlight indexer excludes them; they still resolve by ID or search
        // so existing Shortcuts keep working.
        let classified = trips.filter { $0.classification != nil && $0.classification != .notADrive }
            .prefix(Self.suggestedPerGroupCap)
        return (Array(unclassified) + Array(classified)).map {
            Self.entity(
                for: $0,
                in: model,
                isMostRecentReference: $0.id == mostRecentID
            )
        }
    }

    @MainActor
    static func recentTrips(in model: MileageAppModel, window: Int = stringSearchWindow) -> [TripSummary] {
        let trips = (try? model.tripStore.fetchTrips()) ?? []
        return trips
            .sorted { $0.startDate > $1.startDate }
            .prefix(window)
            .map { $0 }
    }

    @MainActor
    static func mostRecentTrip(in model: MileageAppModel) -> TripSummary? {
        try? TripIntentDataProvider.mostRecentTrip(in: model)
    }

    @MainActor
    private static func entity(
        for trip: TripSummary,
        in model: MileageAppModel,
        isMostRecentReference: Bool
    ) -> TripAppEntity {
        TripAppEntity(
            trip,
            vehicleName: model.vehicleName(for: trip.vehicleID),
            isMostRecentReference: isMostRecentReference
        )
    }
}

extension TripAppEntityQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [TripAppEntity] {
        guard let model = (try? await TripIntentDataProvider.readyModel()) else { return [] }
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        if Self.isMostRecentReference(needle),
           let trip = Self.mostRecentTrip(in: model) {
            return [Self.entity(for: trip, in: model, isMostRecentReference: true)]
        }

        return Self.recentTrips(in: model)
            .map { model.entity(for: $0) }
            .filter { $0.matches(needle) }
            .prefix(Self.stringSearchResultCap)
            .map { $0 }
    }

    private static func isMostRecentReference(_ value: String) -> Bool {
        let reference = normalizedReference(value)
        let aliases = [
            String(localized: "Last Drive"),
            String(localized: "My Last Drive"),
            String(localized: "Previous Drive"),
            String(localized: "My Previous Drive"),
            String(localized: "Latest Drive"),
            String(localized: "My Latest Drive"),
            String(localized: "Most Recent Drive"),
            String(localized: "My Most Recent Drive"),
            String(localized: "Last Completed Drive"),
            String(localized: "Most Recent Completed Drive"),
            String(localized: "Drive I Just Finished"),
            String(localized: "The Drive I Just Finished"),
            String(localized: "Last Trip"),
            String(localized: "My Last Trip"),
            String(localized: "Previous Trip"),
            String(localized: "My Previous Trip"),
            String(localized: "Latest Trip"),
            String(localized: "My Latest Trip"),
            String(localized: "Most Recent Trip"),
            String(localized: "My Most Recent Trip"),
            String(localized: "Last Completed Trip"),
            String(localized: "Most Recent Completed Trip"),
            String(localized: "Trip I Just Finished"),
            String(localized: "The Trip I Just Finished")
        ]
        return aliases.contains { normalizedReference($0) == reference }
    }

    private static func normalizedReference(_ value: String) -> String {
        value
            .replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased(with: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private extension TripAppEntity {
    func matches(_ needle: String) -> Bool {
        let haystacks = [
            originLabel,
            destinationLabel,
            summary.startAddress,
            summary.endAddress,
            summary.businessPurpose,
            summary.notes,
            vehicle
        ]
        return haystacks.contains { haystack in
            guard let haystack else { return false }
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
