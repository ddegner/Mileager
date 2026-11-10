import AppCore
import AppIntents
import Foundation

/// Resolves `MonthlyMileageReportEntity` values for Siri, Shortcuts, and
/// Spotlight. Like the trip query, every path fails soft to empty when the
/// store is unavailable (no model yet, or before first unlock).
struct MonthlyMileageReportEntityQuery: EntityQuery {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    private static let suggestedCap = 6

    @MainActor
    static func allEntities() async -> [MonthlyMileageReportEntity] {
        guard let model = (try? await TripIntentDataProvider.readyModel()) else { return [] }
        let trips = (try? model.tripStore.fetchTrips()) ?? []
        return MonthlyMileageReportEntity.entities(
            for: trips,
            distanceUnit: model.distanceUnit,
            rate: model.mileageRate,
            rateSchedule: model.mileageRateSchedule,
            currencyCode: model.currencyCode
        )
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MonthlyMileageReportEntity] {
        let all = await Self.allEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [MonthlyMileageReportEntity] {
        Array(await Self.allEntities().prefix(Self.suggestedCap))
    }
}

extension MonthlyMileageReportEntityQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [MonthlyMileageReportEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return await Self.allEntities().filter { entity in
            entity.periodTitle.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || entity.id.contains(needle)
        }
    }
}
