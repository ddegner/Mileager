import AppIntents
import Foundation

/// Month selector for the report intents. Named months resolve to their most
/// recent occurrence — this year's if the month has already started, otherwise
/// last year's — which matches how people ask "what were my June miles" after
/// June ends and "what are my July miles" mid-July.
enum ReportMonthAppEnum: String, AppEnum {
    case thisMonth
    case lastMonth
    case january
    case february
    case march
    case april
    case may
    case june
    case july
    case august
    case september
    case october
    case november
    case december

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Month")
    static let caseDisplayRepresentations: [ReportMonthAppEnum: DisplayRepresentation] = [
        .thisMonth: "This Month",
        .lastMonth: "Last Month",
        .january: "January",
        .february: "February",
        .march: "March",
        .april: "April",
        .may: "May",
        .june: "June",
        .july: "July",
        .august: "August",
        .september: "September",
        .october: "October",
        .november: "November",
        .december: "December"
    ]

    private var monthNumber: Int? {
        switch self {
        case .thisMonth, .lastMonth: nil
        case .january: 1
        case .february: 2
        case .march: 3
        case .april: 4
        case .may: 5
        case .june: 6
        case .july: 7
        case .august: 8
        case .september: 9
        case .october: 10
        case .november: 11
        case .december: 12
        }
    }

    func monthInterval(containing now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .thisMonth:
            return DriveMonthSummary.monthInterval(containing: now, calendar: calendar)
        case .lastMonth:
            let thisMonthStart = DriveMonthSummary.monthInterval(containing: now, calendar: calendar).start
            let previousMonth = calendar.date(byAdding: .month, value: -1, to: thisMonthStart) ?? thisMonthStart
            return DriveMonthSummary.monthInterval(containing: previousMonth, calendar: calendar)
        default:
            guard let monthNumber else {
                return DriveMonthSummary.monthInterval(containing: now, calendar: calendar)
            }
            var components = calendar.dateComponents([.year, .month], from: now)
            if let currentMonth = components.month, monthNumber > currentMonth {
                components.year = (components.year ?? 0) - 1
            }
            components.month = monthNumber
            let anchor = calendar.date(from: components) ?? now
            return DriveMonthSummary.monthInterval(containing: anchor, calendar: calendar)
        }
    }
}
