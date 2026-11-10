import AppCore
import AppIntents
import Foundation

#if compiler(>=6.4)

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenCurrentDriveIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Current Drive"
    static let supportedModes: IntentModes = .foreground
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Drive")
    var target: CurrentDriveAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await TripIntentDataProvider.readyModel()
        let current = try CurrentDriveIntentResolver.resolve(target, in: model)
        model.requestOpenCurrentDrive(id: current.pendingTripID)
        return .result()
    }
}

/// Search text is only a query. It never executes edits, even if it contains
/// words that also describe a classification action.
@available(iOS 27.0, *)
@AppIntent(schema: .system.search)
struct SearchTripsIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Trips"
    static let searchScopes: [StringSearchScope] = [.general]
    static let supportedModes: IntentModes = .foreground
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Search")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await TripIntentDataProvider.readyModel()
        model.requestTripSearch(criteria.term)
        return .result()
    }
}

/// Keeps the pre-iOS 27 OpenTripIntent identifier and parameters intact in
/// existing Shortcuts while exposing the new system schema to Siri.
@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenTripWithSiriIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Trip"
    static let isAssistantOnly = true
    static let supportedModes: IntentModes = .foreground
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Trip")
    var target: TripAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let intent = OpenTripIntent()
        intent.target = target
        _ = try await intent.perform()
        return .result()
    }
}
#endif
