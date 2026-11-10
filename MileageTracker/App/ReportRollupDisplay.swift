import AppCore
import Foundation

/// Shared roll-up math and formatting for the Year Summary and monthly report
/// rows. Reimbursement here is the unrounded meters × rate product — the
/// on-screen preview — while the exports round per trip to cents; that
/// difference is long-standing display behavior, preserved as-is. Internal
/// (not private) so unit tests can pin the formatting.
struct ReportRollupDisplay {
    var businessDriveCount: Int
    var businessMiles: Double
    var businessParkingAndTolls: Double
    var unclassifiedCount: Int
    var rate: MileageRate
    var businessTrips: [TripSummary] = []
    var rateSchedule: MileageRateSchedule?
    var currencyCode: String
    var distanceUnit: DistanceUnit

    var mileageReimbursement: Double {
        if let rateSchedule, !businessTrips.isEmpty {
            return businessTrips.filter(\.isExportableBusiness).reduce(0) {
                let rate = rateSchedule.rate(on: $1.startDate)
                let value = $1.reportableDistanceMeters * rate.amountPerMeter
                return $0 + (value * 100).rounded() / 100
            }
        }
        return DistanceConversion.meters(fromMiles: businessMiles) * rate.amountPerMeter
    }

    var totalReimbursement: Double {
        mileageReimbursement + businessParkingAndTolls
    }

    /// "%lld business trips" carries a plural variation in the string catalog.
    var businessDriveCountText: String {
        String(localized: "\(businessDriveCount) business trips")
    }

    var unclassifiedWarningText: String {
        // Plural variation lives in the string catalog.
        String(localized: "\(unclassifiedCount) unclassified trips aren't in your business totals. Classify them to include their miles.")
    }

    var businessMilesLabel: String {
        distanceUnit == .miles
            ? String(localized: "Business miles")
            : String(localized: "Business kilometers")
    }

    func miles(_ value: Double) -> String {
        DistanceFormatting.label(meters: DistanceConversion.meters(fromMiles: value), unit: distanceUnit)
    }

    func currency(_ value: Double) -> String {
        CurrencyFormatting.label(value, code: currencyCode)
    }
}
