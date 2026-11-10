import AppCore
import Foundation

/// Review is outstanding work, not a permanent archive destination. Keep an
/// empty selected inbox in the split sidebar until the user leaves it, so
/// removing its row cannot clear the selection and close the review pane.
struct MailboxReviewPresentation: Equatable {
    var needsReviewCount: Int
    var hasLoadedInitialTrips: Bool
    var isReviewSelected: Bool

    var showsNeedsReviewRow: Bool { needsReviewCount > 0 || isReviewSelected }
    var showsCaughtUpStatus: Bool { hasLoadedInitialTrips && needsReviewCount == 0 }
}

/// A year's worth of month groups, plus the roll-up behind its Year Summary row.
struct DriveYearGroup: Identifiable, Equatable {
    var yearStart: Date
    var months: [DriveMonthGroup]

    var id: Date { yearStart }

    var businessMiles: Double { months.reduce(0) { $0 + $1.summary.businessMiles } }
}

/// The Mailboxes root's derived contents: the scope counts at the top and every
/// month that has trips, grouped under its year. A pure value type so the
/// grouping rules are unit-testable and the view body stays declarative — the
/// pattern `TripListDerivation` already established.
struct MailboxDirectory: Equatable {
    /// The count of drives still needing a decision.
    ///
    /// Deliberately NOT vehicle-scoped. `MileageAppModel.refresh()` computes the
    /// same figure unscoped for `ReminderScheduler`, and a badge that disagreed
    /// with the notification would reproduce exactly the defect this predicate
    /// exists to end. An explicit vehicle scope may narrow the directory's
    /// months and money for isolated derivation, but it never narrows a count
    /// of outstanding work. Production Mailboxes resets to `.all` because that
    /// root has no visible filter control and owns period-wide exports.
    var needsReviewCount: Int
    var years: [DriveYearGroup]
    /// The month the ⌘-menu's export commands target: the current month when it
    /// has trips, else the newest month that does.
    var defaultExportMonthStart: Date?
    var totalTripCount: Int

    var isEmpty: Bool { totalTripCount == 0 }

    init(
        trips: [TripSummary],
        vehicleFilter: TripVehicleFilter = .all,
        primaryVehicleID: UUID? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        needsReviewCount = trips.filter(\.isUnresolved).count
        totalTripCount = trips.count

        let scoped = trips.filter { vehicleFilter.matches($0, primaryVehicleID: primaryVehicleID) }
        let monthGroups = DriveMonthSummary.groups(for: scoped, sort: .newestFirst, calendar: calendar)

        let grouped = Dictionary(grouping: monthGroups) { group in
            calendar.dateInterval(of: .year, for: group.monthStart)?.start ?? group.monthStart
        }
        years = grouped.keys.sorted(by: >).map { yearStart in
            DriveYearGroup(yearStart: yearStart, months: grouped[yearStart] ?? [])
        }

        let currentMonthStart = DriveMonthSummary.monthInterval(containing: now, calendar: calendar).start
        let allMonths = monthGroups.map(\.monthStart)
        defaultExportMonthStart = allMonths.first { calendar.isDate($0, inSameDayAs: currentMonthStart) }
            ?? allMonths.first
    }

    func group(forMonthStart monthStart: Date) -> DriveMonthGroup? {
        years.lazy.flatMap(\.months).first { $0.monthStart == monthStart }
    }
}
