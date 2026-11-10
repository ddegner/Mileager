import AppCore
import AppIntents
import Foundation

/// Opens the app on Need Review — the drives that still need a decision.
///
/// The redesign made this a first-class destination rather than a section of a
/// longer list, and it is the screen the app exists to empty, so it earns a
/// spoken shortcut of its own.
struct OpenNeedsReviewIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Open Need Review"
    static let description = IntentDescription(
        "Shows the drives that still need to be reviewed in Mileager.",
        categoryName: "Trips"
    )
    static let supportedModes: IntentModes = .foreground

    static var parameterSummary: some ParameterSummary {
        Summary("Open the drives that need review")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        model.requestOpenNeedsReview()

        // The same predicate the badge, the month rows, and the review
        // notification use, so Siri never quotes a number the screen contradicts.
        let count = model.trips.filter(\.isUnresolved).count
        let dialog: IntentDialog = count == 0
            ? IntentDialog("You're all caught up.")
            : IntentDialog("\(count) drives need review.")
        return .result(dialog: dialog)
    }
}
