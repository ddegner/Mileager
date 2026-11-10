import AppCore
import Foundation

/// The Trips navigation stack's path element. One `navigationDestination(for:)`
/// on the root resolves every push, so a deep link is an array assignment
/// rather than a chain of bindings.
enum TripsRoute: Hashable {
    case scope(DriveListScope)
    case trip(UUID)

    static let needsReview = TripsRoute.scope(.needsReview)
    static let allTrips = TripsRoute.scope(.allTrips)

    static func month(_ monthStart: Date) -> TripsRoute { .scope(.month(monthStart)) }
    static func year(_ yearStart: Date) -> TripsRoute { .scope(.year(yearStart)) }
}

/// Which drives a `DriveListView` shows. The scope supplies the predicate, the
/// title, and the empty-state copy — a period is not a different screen from
/// the inbox, it is the same list with a date interval.
enum DriveListScope: Hashable {
    /// Everything still awaiting a human decision, across every month.
    case needsReview
    /// The full ledger, resolved and unresolved alike.
    case allTrips
    /// One month, identified by its interval start (`DriveMonthGroup.id`).
    case month(Date)
    /// One calendar year, identified by its interval start (`DriveYearGroup.id`).
    case year(Date)

    var title: String {
        switch self {
        case .needsReview: String(localized: "Need Review")
        case .allTrips: String(localized: "All Trips")
        case let .month(monthStart): monthStart.formatted(.dateTime.month(.wide).year())
        case let .year(yearStart): yearStart.formatted(.dateTime.year())
        }
    }

    /// A month or calendar year is a reportable filing period. The other two
    /// scopes cross period boundaries, so their totals are not exportable.
    var showsPeriodRollup: Bool {
        switch self {
        case .month, .year: true
        case .needsReview, .allTrips: false
        }
    }

    /// Whether the rows are grouped under month headers.
    ///
    /// Independent of the roll-up, though it briefly was not: deriving this
    /// from `showsPeriodRollup` meant giving the year a roll-up silently took
    /// its headers away, so drilling from All Trips into one of its years
    /// *removed* the month structure from a strictly smaller list. Only a
    /// month scope has no use for them — the screen is already one month.
    var showsMonthHeaders: Bool {
        switch self {
        case .month: false
        case .needsReview, .allTrips, .year: true
        }
    }

    /// The filing period this scope covers, or `nil` for the two scopes that
    /// cross period boundaries.
    ///
    /// Every period-shaped question resolves through this one interval — the
    /// row predicate, the manual-trip date, the roll-up's rate anchor — so a
    /// fifth scope adds a case here rather than to each of them in turn.
    func periodInterval(calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case let .month(monthStart):
            DriveMonthSummary.monthInterval(containing: monthStart, calendar: calendar)
        case let .year(yearStart):
            AnnualReportBreakdown.yearInterval(containing: yearStart, calendar: calendar)
        case .needsReview, .allTrips:
            nil
        }
    }

    /// What a manually added trip should be dated when it is created from this
    /// scope. `nil` means "now" — only a reportable period has an opinion.
    var defaultNewTripDate: Date? {
        guard let interval = periodInterval() else { return nil }
        // The current period keeps "now"; a past period lands at its midpoint
        // so the date picker opens in the right range without claiming a
        // precise time.
        return interval.contains(Date())
            ? nil
            : interval.start.addingTimeInterval(interval.duration / 2)
    }

    /// This scope's row predicate, with the period interval resolved once.
    ///
    /// `Calendar.dateInterval(of:for:)` does real work and its answer does not
    /// depend on the trip, so a per-trip `contains` rebuilt the same interval
    /// once per row per pass. Anything filtering a whole store takes this.
    func matches(calendar: Calendar = .current) -> (TripSummary) -> Bool {
        switch self {
        case .needsReview:
            return { $0.isUnresolved }
        case .allTrips:
            return { _ in true }
        case .month, .year:
            guard let interval = periodInterval(calendar: calendar) else { return { _ in false } }
            // Half-open on purpose. `DateInterval.contains` includes its end,
            // and a period's end IS the next period's start, so a drive
            // beginning exactly at midnight on the 1st — of the month or of
            // January — would otherwise appear in both periods.
            return { $0.startDate >= interval.start && $0.startDate < interval.end }
        }
    }

    func contains(_ trip: TripSummary, calendar: Calendar = .current) -> Bool {
        matches(calendar: calendar)(trip)
    }
}
