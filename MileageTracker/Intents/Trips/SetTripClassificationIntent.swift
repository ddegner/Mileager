import AppCore
import AppIntents
import Foundation

/// Siri/Shortcuts entry point for the app's core review action. Runs in the
/// app process against the main store; before first unlock it fails with a
/// clear message instead of spooling — unlike a drive-start signal, a
/// classification is an interactive read-modify-write the user can retry.
struct SetTripClassificationIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Classify Trip"
    static let description = IntentDescription(
        "Marks a Mileager trip as Business, Personal, or Not a Drive.",
        categoryName: "Trips"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Trip")
    var trip: TripAppEntity

    @Parameter(title: "Category")
    var classification: TripClassificationAppEnum

    @Parameter(title: "Business Purpose")
    var businessPurpose: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$trip) as \(\.$classification)") {
            \.$businessPurpose
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        guard let current = try? model.tripStore.fetchTripIfExists(id: trip.id) else {
            throw TripIntentError.tripNotFound
        }
        let entity = try CompletedTripClassificationPerformer.classify(
            current,
            as: classification,
            businessPurpose: businessPurpose,
            in: model
        )
        return .result(
            value: entity,
            dialog: "Marked \(entity.routeLabel) as \(classification.domainValue.displayName)."
        )
    }
}

/// One-shot Siri action for temporal references such as "last drive" and
/// "previous trip." Keeping the trip implicit leaves the spoken phrase with a
/// single dynamic parameter (the classification), which is an App Shortcuts
/// validation requirement. The generic `SetTripClassificationIntent` remains
/// available when the user wants Siri to ask which trip to edit.
struct ClassifyMostRecentTripIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Classify Most Recent Trip"
    static let description = IntentDescription(
        "Marks the most recently completed Mileager trip as Business, Personal, or Not a Drive.",
        categoryName: "Trips",
        searchKeywords: ["last drive", "previous drive", "recent trip", "classify"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Category")
    var classification: TripClassificationAppEnum

    @Parameter(title: "Business Purpose")
    var businessPurpose: String?

    // Keep Category required so an omitted category triggers clarification.
    init() {}

    init(classification: TripClassificationAppEnum) {
        self.classification = classification
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Mark the most recent trip as \(\.$classification)") {
            \.$businessPurpose
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        let trip = try TripIntentDataProvider.mostRecentTrip(in: model)
        let entity = try CompletedTripClassificationPerformer.classify(
            trip,
            as: classification,
            businessPurpose: businessPurpose,
            in: model
        )
        return .result(
            value: entity,
            dialog: "Marked \(entity.routeLabel) as \(classification.domainValue.displayName)."
        )
    }
}

/// Dedicated read-only action for Siri's "how long was my last drive" question.
/// Keeping this parameter-free gives Siri a single deterministic route and a
/// dialog-only result that works in voice-only contexts.
struct LastDriveDurationIntent: AppIntent {
    static let title: LocalizedStringResource = "Last Drive Duration"
    static let description = IntentDescription(
        "Reports the duration of the most recently completed Mileager drive.",
        categoryName: "Trips",
        searchKeywords: ["last drive", "last trip", "duration", "how long"]
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

#if compiler(>=6.4)
    /// Xcode 27 can pin this read to the main app, which owns the trip store.
    /// Xcode 26 doesn't contain `IntentExecutionTargets`, so it uses the
    /// App Intents framework's default process selection instead.
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Get the duration of the most recent drive")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        let trip = try TripIntentDataProvider.mostRecentTrip(
            in: model,
            excludingNotADrive: true
        )
        let duration = TripAppEntity.durationText(seconds: trip.durationSeconds)
        return .result(
            dialog: IntentDialog(
                full: "Your last drive lasted \(duration).",
                supporting: "\(duration)"
            )
        )
    }
}

@MainActor
private enum CompletedTripClassificationPerformer {
    static func classify(
        _ trip: TripSummary,
        as classification: TripClassificationAppEnum,
        businessPurpose: String?,
        in model: MileageAppModel
    ) throws -> TripAppEntity {
        let trimmedPurpose = businessPurpose?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try model.applyClassification(
            to: trip,
            classification: classification.domainValue,
            purpose: (trimmedPurpose?.isEmpty ?? true) ? nil : trimmedPurpose
        )
        return model.entity(for: updated)
    }
}
