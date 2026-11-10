import AppCore
import AppIntents
import Foundation

/// Opens the app on the Reports screen for a resolved month entity;
/// `OpenIntent` gives month reports "Open" semantics in Spotlight results and
/// Siri conversations ("open that report"). The phrase-driven
/// `OpenMileageReportIntent` stays for month-name Siri phrases.
struct OpenMonthlyMileageReportIntent: OpenIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Open Monthly Mileage Report"
    static let description = IntentDescription(
        "Shows the monthly mileage report in Mileager.",
        categoryName: "Reports"
    )

    @Parameter(title: "Report")
    var target: MonthlyMileageReportEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await TripIntentDataProvider.readyModel()
        model.requestOpenReports(monthStart: target.monthStart)
        return .result()
    }
}
