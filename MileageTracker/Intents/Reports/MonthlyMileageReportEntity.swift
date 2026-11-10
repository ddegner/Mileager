import AppCore
import AppIntents
import Foundation

/// App Intents projection of one calendar month's mileage totals. Donated to
/// the Spotlight semantic index so system search — and the LLM-backed Siri
/// that reads that index on iOS 27 — can answer "what were my business miles
/// in June" from on-device context, and so Shortcuts can resolve monthly
/// reports as first-class entities.
struct MonthlyMileageReportEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Monthly Mileage Report")
    static let defaultQuery = MonthlyMileageReportEntityQuery()

    /// Stable calendar identity, e.g. "2026-06": locale-independent and
    /// identical across devices (CloudKit-synced trips produce the same
    /// months), so a future `SyncableEntity` adoption can keep these IDs.
    let id: String
    let monthStart: Date
    let monthEnd: Date
    let unclassifiedCount: Int

    @Property(title: "Month")
    var month: Date

    @Property(title: "Business Distance")
    var businessDistance: Double

    @Property(title: "Business Trips")
    var businessTripCount: Int

    @Property(title: "Drives")
    var driveCount: Int

    // Display strings baked at projection time with the user's unit, rate,
    // currency, and locale; the index digest fingerprints them so donations
    // refresh exactly when this text changes.
    let periodTitle: String
    let distanceText: String
    let tripCountText: String
    let reimbursementText: String
    /// The same sentence `GetMonthlyBusinessMilesIntent` speaks. Donated as
    /// the Spotlight content description so semantic retrieval for "business
    /// miles in June" lands on text that already contains the answer.
    let summarySentence: String

    init(answer: MonthlyBusinessMilesAnswer, calendar: Calendar = .current) {
        // Plain stored properties first: the @Property wrappers initialize at
        // their declarations, so assigning them below is a setter call on self.
        id = Self.monthID(for: answer.interval.start, calendar: calendar)
        monthStart = answer.interval.start
        monthEnd = answer.interval.end
        unclassifiedCount = answer.summary.unclassifiedCount
        periodTitle = answer.periodTitle
        distanceText = answer.distanceText
        tripCountText = answer.tripCountText
        reimbursementText = answer.reimbursementText
        summarySentence = answer.dialogText
        month = answer.interval.start
        businessDistance = answer.businessDistanceValue
        businessTripCount = answer.summary.businessDriveCount
        driveCount = answer.summary.driveCount
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(titleText)",
            subtitle: "\(subtitleText)",
            image: .init(systemName: "doc.richtext.fill")
        )
    }

    var titleText: String {
        String(localized: "\(periodTitle) Mileage Report")
    }

    var subtitleText: String {
        "\(distanceText) · \(tripCountText) · \(reimbursementText)"
    }

    static func monthID(for monthStart: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: monthStart)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    /// Projects an entity for every month with at least one drive, newest
    /// first. Mirrors the Trips month rollup: Not-a-Drive captures never count
    /// toward totals.
    static func entities(
        for trips: [TripSummary],
        distanceUnit: DistanceUnit,
        rate: MileageRate,
        rateSchedule: MileageRateSchedule? = nil,
        currencyCode: String,
        calendar: Calendar = .current
    ) -> [MonthlyMileageReportEntity] {
        DriveMonthSummary.groups(for: trips, calendar: calendar)
            .filter { $0.summary.driveCount > 0 }
            .map { group in
                MonthlyMileageReportEntity(
                    answer: MonthlyBusinessMilesAnswer(
                        summary: group.summary,
                        interval: DateInterval(start: group.monthStart, end: group.monthEnd),
                        distanceUnit: distanceUnit,
                        rate: rate,
                        rateSchedule: rateSchedule,
                        businessTrips: group.trips.filter(\.isExportableBusiness),
                        currencyCode: currencyCode
                    ),
                    calendar: calendar
                )
            }
    }
}
