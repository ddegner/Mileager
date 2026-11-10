import AppCore
import AppIntents
import Foundation

/// Compatibility action for existing Shortcuts on iOS 26 and later. The
/// iOS 27 schema action owns OpenIntent conformance because Apple permits
/// only one OpenIntent per entity type, even for assistant-only actions.
struct OpenTripIntent: AppIntent {
    static let supportedModes: IntentModes = .foreground
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Open Trip"
    static let description = IntentDescription(
        "Shows a trip in Mileager.",
        categoryName: "Trips"
    )

    @Parameter(title: "Trip")
    var target: TripAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await TripIntentDataProvider.readyModel()
        guard (try? model.tripStore.fetchTripIfExists(id: target.id)) != nil else {
            throw TripIntentError.tripNotFound
        }
        model.requestOpenTrip(id: target.id)
        return .result()
    }
}
