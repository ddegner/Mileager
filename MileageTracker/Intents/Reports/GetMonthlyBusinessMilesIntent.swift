import AppCore
import AppIntents
import Foundation
import SwiftUI

/// The computation and phrasing behind `GetMonthlyBusinessMilesIntent`,
/// factored out of `perform()` so tests can drive it with fixed clocks and
/// synthetic trips. Mirrors the Trips month export: same month grouping, same
/// `isExportableBusiness` gate, same unit/rate/currency formatting.
struct MonthlyBusinessMilesAnswer {
    let interval: DateInterval
    let summary: DriveMonthSummary
    let distanceUnit: DistanceUnit
    let rate: MileageRate
    let rateSchedule: MileageRateSchedule?
    let businessTrips: [TripSummary]
    let currencyCode: String

    init(
        summary: DriveMonthSummary,
        interval: DateInterval,
        distanceUnit: DistanceUnit,
        rate: MileageRate,
        rateSchedule: MileageRateSchedule? = nil,
        businessTrips: [TripSummary] = [],
        currencyCode: String
    ) {
        self.interval = interval
        self.summary = summary
        self.distanceUnit = distanceUnit
        self.rate = rate
        self.rateSchedule = rateSchedule
        self.businessTrips = businessTrips
        self.currencyCode = currencyCode
    }

    init(
        trips: [TripSummary],
        month: ReportMonthAppEnum,
        now: Date = Date(),
        calendar: Calendar = .current,
        distanceUnit: DistanceUnit,
        rate: MileageRate,
        rateSchedule: MileageRateSchedule? = nil,
        currencyCode: String
    ) {
        let interval = month.monthInterval(containing: now, calendar: calendar)
        // Half-open on the end, matching DriveMonthSummary.groups' bucketing.
        let monthTrips = trips.filter { $0.startDate >= interval.start && $0.startDate < interval.end }
        self.interval = interval
        summary = DriveMonthSummary.summary(
            for: monthTrips,
            monthStart: interval.start,
            monthEnd: interval.end
        )
        self.distanceUnit = distanceUnit
        self.rate = rate
        self.rateSchedule = rateSchedule
        businessTrips = monthTrips.filter(\.isExportableBusiness)
        self.currencyCode = currencyCode
    }

    var periodTitle: String {
        interval.start.formatted(.dateTime.month(.wide).year())
    }

    private var businessMeters: Double {
        DistanceConversion.meters(fromMiles: summary.businessMiles)
    }

    /// Business distance in the user's display unit, for Shortcuts to use as a
    /// number (the dialog carries the unit label).
    var businessDistanceValue: Double {
        DistanceConversion.value(meters: businessMeters, in: distanceUnit)
    }

    var distanceText: String {
        DistanceFormatting.label(meters: businessMeters, unit: distanceUnit, fractionDigits: 0...1)
    }

    var reimbursementText: String {
        let value: Double
        if let rateSchedule, !businessTrips.isEmpty {
            value = businessTrips.reduce(0) {
                let tripRate = rateSchedule.rate(on: $1.startDate)
                let amount = $1.reportableDistanceMeters * tripRate.amountPerMeter
                return $0 + (amount * 100).rounded() / 100
            }
        } else {
            value = businessMeters * rate.amountPerMeter
        }
        return CurrencyFormatting.label(value, code: currencyCode)
    }

    var tripCountText: String {
        String(localized: "\(summary.businessDriveCount) business trips")
    }

    var unclassifiedWarningText: String? {
        guard summary.unclassifiedCount > 0 else { return nil }
        return String(localized: "\(summary.unclassifiedCount) unclassified trips aren't in your business totals. Classify them to include their miles.")
    }

    var dialogText: String {
        guard summary.businessDriveCount > 0 else {
            var text = String(localized: "No business trips recorded for \(periodTitle) yet.")
            if let unclassifiedWarningText {
                text += " " + unclassifiedWarningText
            }
            return text
        }
        var text = String(localized: "You drove \(distanceText) for business in \(periodTitle) across \(tripCountText). Mileage reimbursement: \(reimbursementText).")
        if let unclassifiedWarningText {
            text += " " + unclassifiedWarningText
        }
        return text
    }
}

/// Answers "what were my business miles in June" from Siri or Shortcuts
/// without opening the app. Returns the distance as a number so Shortcuts can
/// chain it, plus a spoken dialog and a card.
struct GetMonthlyBusinessMilesIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Get Monthly Business Miles"
    // Keywords and a named result value give Siri/Shortcuts routing something
    // richer than phrases — the iOS 27 App Toolbox picks intents by metadata.
    static let description = IntentDescription(
        "Tells you a month's business mileage total and reimbursement.",
        categoryName: "Reports",
        searchKeywords: ["mileage", "business miles", "report", "reimbursement"],
        resultValueName: "Business Distance"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Month")
    var month: ReportMonthAppEnum

    init() {
        month = .thisMonth
    }

    init(month: ReportMonthAppEnum) {
        self.month = month
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Get business miles for \(\.$month)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog & ShowsSnippetView {
        let model = try await TripIntentDataProvider.readyModel()
        model.refresh()
        let answer = MonthlyBusinessMilesAnswer(
            trips: model.trips,
            month: month,
            distanceUnit: model.distanceUnit,
            rate: model.mileageRate,
            rateSchedule: model.mileageRateSchedule,
            currencyCode: model.currencyCode
        )
        return .result(
            value: answer.businessDistanceValue,
            dialog: IntentDialog(stringLiteral: answer.dialogText),
            view: MonthlyBusinessMilesSnippetView(answer: answer)
        )
    }
}

private struct MonthlyBusinessMilesSnippetView: View {
    var answer: MonthlyBusinessMilesAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(answer.periodTitle)
                .font(.headline)
            Text(answer.distanceText)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("\(answer.tripCountText) · \(answer.reimbursementText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let warning = answer.unclassifiedWarningText {
                Label {
                    Text(warning)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
