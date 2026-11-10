import AppCore
import XCTest
@testable import MileageTracker

/// Pins the shared report-row roll-up extracted from YearSummaryRow /
/// MonthlyReportRow: the on-screen reimbursement preview stays the unrounded
/// meters × rate product (exports round per trip to cents — long-standing
/// display difference), and the formatting helpers stay wired to the AppCore
/// formatters.
final class ReportRollupDisplayTests: XCTestCase {
    private func makeRollup(miles: Double = 100.0, parkingAndTolls: Double = 12.34) -> ReportRollupDisplay {
        ReportRollupDisplay(
            businessDriveCount: 7,
            businessMiles: miles,
            businessParkingAndTolls: parkingAndTolls,
            unclassifiedCount: 3,
            rate: MileageRate(amountPerUnit: 0.5, unit: .miles),
            currencyCode: "USD",
            distanceUnit: .miles
        )
    }

    func testReimbursementIsUnroundedMetersTimesRate() {
        let rollup = makeRollup()
        XCTAssertEqual(rollup.mileageReimbursement, 50.0, accuracy: 0.0001)
        XCTAssertEqual(rollup.totalReimbursement, 62.34, accuracy: 0.0001)
    }

    func testCountTextsCarryTheCounts() {
        let rollup = makeRollup()
        XCTAssertTrue(rollup.businessDriveCountText.contains("7"), rollup.businessDriveCountText)
        XCTAssertTrue(rollup.unclassifiedWarningText.contains("3"), rollup.unclassifiedWarningText)
    }

    func testFormattersMatchAppCoreFormatting() {
        let rollup = makeRollup()
        XCTAssertEqual(
            rollup.miles(25.5),
            DistanceFormatting.label(meters: DistanceConversion.meters(fromMiles: 25.5), unit: .miles)
        )
        XCTAssertEqual(rollup.currency(62.34), CurrencyFormatting.label(62.34, code: "USD"))
    }

    func testBusinessMilesLabelFollowsUnit() {
        var rollup = makeRollup()
        XCTAssertEqual(rollup.businessMilesLabel, String(localized: "Business miles"))
        rollup.distanceUnit = .kilometers
        XCTAssertEqual(rollup.businessMilesLabel, String(localized: "Business kilometers"))
    }
}
