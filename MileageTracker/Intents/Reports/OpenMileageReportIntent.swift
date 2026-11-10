import AppCore
import AppIntents
import Foundation

/// Opens the app on the Reports screen, scrolled to the requested month.
struct OpenMileageReportIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Open Mileage Report"
    static let description = IntentDescription(
        "Shows the monthly mileage report in Mileager.",
        categoryName: "Reports"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Month")
    var month: ReportMonthAppEnum

    init() {
        month = .thisMonth
    }

    init(month: ReportMonthAppEnum) {
        self.month = month
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open the mileage report for \(\.$month)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await TripIntentDataProvider.readyModel()
        model.requestOpenReports(monthStart: month.monthInterval().start)
        return .result()
    }
}
