import AppCoreModels
import AppCorePersistence
import Foundation

/// One month's line in an annual report: the business trips that fall in the
/// month plus totals computed with the report footing rules (currency precision
/// per row and two-place distance rounding), so a month's line here
/// matches that month's standalone report exactly.
public struct ReportMonthSection: Equatable, Sendable {
    public var monthStart: Date
    public var monthEnd: Date
    public var trips: [TripSummary]
    /// Sum of each trip's distance rounded to the 2 dp printed per row, in the
    /// report's display unit, so the month line foots to its trip rows.
    public var displayedBusinessDistance: Double
    /// Sum of mileage amounts rounded per row to the currency precision.
    public var mileageReimbursement: Double
    public var tolls: Double
    public var parking: Double

    public var tripCount: Int { Set(trips.map(\.id)).count }

    public var parkingAndTolls: Double { tolls + parking }

    public var totalReimbursement: Double { mileageReimbursement + parkingAndTolls }
}

/// Groups a report's business trips into calendar-month sections for annual
/// (or any multi-month) reports.
public enum AnnualReportBreakdown {
    /// Month sections for the given business trips, oldest month first. Months
    /// with no trips between the first and last active month are included as
    /// zero lines — a quiet month is information an accountant wants explicit,
    /// not missing. Leading/trailing empty months are omitted.
    public static func monthSections(
        businessTrips: [TripSummary],
        unit: DistanceUnit,
        rate: MileageRate,
        calendar: Calendar = .current,
        currencyCode: String = "USD"
    ) -> [ReportMonthSection] {
        monthSections(
            businessTrips: businessTrips,
            unit: unit,
            rateSchedule: MileageRateSchedule(baseRate: rate),
            calendar: calendar,
            currencyCode: currencyCode
        )
    }

    public static func monthSections(
        businessTrips: [TripSummary],
        unit: DistanceUnit,
        rateSchedule: MileageRateSchedule,
        calendar: Calendar = .current,
        currencyCode: String = "USD"
    ) -> [ReportMonthSection] {
        let currency = ReportCurrency(code: currencyCode)
        let slices = businessTrips.flatMap { ReportTripAllocation.slices(of: $0, schedule: rateSchedule, calendar: calendar, currency: currency) }
        guard !slices.isEmpty else { return [] }

        let grouped = Dictionary(grouping: slices) { trip in
            monthInterval(containing: trip.startDate, calendar: calendar).start
        }
        guard let firstMonth = grouped.keys.min(), let lastMonth = grouped.keys.max() else { return [] }

        var sections: [ReportMonthSection] = []
        var monthStart = firstMonth
        while monthStart <= lastMonth {
            let interval = monthInterval(containing: monthStart, calendar: calendar)
            let trips = (grouped[interval.start] ?? []).sorted { $0.startDate < $1.startDate }
            sections.append(ReportMonthSection(
                monthStart: interval.start,
                monthEnd: interval.end,
                trips: trips,
                displayedBusinessDistance: trips.reduce(0) {
                    $0 + ReportMilesRounding.twoPlaces(DistanceConversion.value(meters: $1.reportableDistanceMeters, in: unit))
                },
                mileageReimbursement: trips.reduce(0) {
                    let rate = rateSchedule.rate(on: $1.startDate, calendar: calendar)
                    return $0 + currency.rounded(
                        $1.reportableDistanceMeters * rate.amountPerMeter
                    )
                },
                tolls: trips.reduce(0) { $0 + currency.rounded($1.tollsAmount) },
                parking: trips.reduce(0) { $0 + currency.rounded($1.parkingAmount) }
            ))
            guard interval.end > monthStart else { break }
            monthStart = interval.end
        }
        return sections
    }

    public static func yearInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .year, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// Inclusive report end for a calendar year, mirroring
    /// `DriveMonthSummary.reportEndDate` (the generator's trip filter treats
    /// `endDate` as inclusive).
    public static func reportEndDate(forYearContaining date: Date, calendar: Calendar = .current) -> Date {
        yearInterval(containing: date, calendar: calendar).end.addingTimeInterval(-0.001)
    }

    private static func monthInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }
}
