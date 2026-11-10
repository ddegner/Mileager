import AppCore
import SwiftUI

/// What the reading pane shows when several trips are selected.
///
/// Mail's rule: with a multi-selection there is no one message to read, so the
/// pane stops pretending and says what has been picked instead. The verbs are
/// already in the toolbar and the menu bar, so this carries none — it answers
/// "what did I just select", and nothing else.
///
/// The money comes from `ReportRollupDisplay`, the same type the period roll-up
/// uses, so a selection's total and the month's total are computed once and can
/// never disagree.
struct MultiTripSelectionPane: View {
    var trips: [TripSummary]
    var rateSchedule: MileageRateSchedule
    var currencyCode: String

    @Environment(\.distanceUnit) private var distanceUnit

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // "%lld trips selected" carries a plural variation in the catalog.
            Text("\(trips.count) trips selected")
                .font(.title2.weight(.semibold))

            if let dateRangeText {
                Text(verbatim: dateRangeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let rollup {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    summaryRow("Distance", DistanceFormatting.label(
                        meters: totalMeters, unit: distanceUnit
                    ))
                    summaryRow("Business trips", rollup.businessDriveCount.formatted())
                    summaryRow(
                        "Total reimbursement",
                        rollup.currency(rollup.totalReimbursement)
                    )
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiTripSelectionPane")
    }

    private func summaryRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    private var totalMeters: Double {
        trips.reduce(0) { $0 + $1.reportableDistanceMeters }
    }

    /// Ordered by date rather than by pick order — a span reads forwards.
    private var dateRangeText: String? {
        let dates = trips.map(\.startDate).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let start = first.formatted(date: .abbreviated, time: .omitted)
        guard start != last.formatted(date: .abbreviated, time: .omitted) else { return start }
        return "\(start) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private var rollup: ReportRollupDisplay? {
        guard let anchor = trips.map(\.startDate).min() else { return nil }
        let businessTrips = trips.filter(\.isExportableBusiness)
        return ReportRollupDisplay(
            businessDriveCount: businessTrips.count,
            businessMiles: businessTrips.reduce(0) { $0 + $1.miles },
            businessParkingAndTolls: businessTrips.reduce(0) {
                $0 + $1.tollsAmount + $1.parkingAmount
            },
            unclassifiedCount: trips.filter { $0.classification == nil }.count,
            // Only the fallback for an empty business set; the schedule below
            // is what actually rates each trip, on its own date.
            rate: rateSchedule.rate(on: anchor),
            businessTrips: businessTrips,
            rateSchedule: rateSchedule,
            currencyCode: currencyCode,
            distanceUnit: distanceUnit
        )
    }
}
