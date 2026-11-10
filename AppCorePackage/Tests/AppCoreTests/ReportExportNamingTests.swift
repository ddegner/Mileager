import XCTest
@testable import AppCore

final class ReportExportNamingTests: XCTestCase {
    func testLogicalPeriodControlsFilenameAcrossTimeZones() throws {
        let start = Date(timeIntervalSince1970: 1_798_761_000)
        XCTAssertEqual(
            ReportExportNaming.baseFilename(
                logicalPeriodID: "month.2027-01",
                reportStartDate: start,
                reportEndDate: start.addingTimeInterval(30 * 86_400)
            ),
            "Mileage-2027-01"
        )
        XCTAssertEqual(
            ReportExportNaming.baseFilename(
                logicalPeriodID: "year.2027",
                reportStartDate: start,
                reportEndDate: start.addingTimeInterval(365 * 86_400)
            ),
            "Mileage-2027"
        )
    }

    func testMalformedLogicalPeriodUsesStableUTCFallback() {
        let start = Date(timeIntervalSince1970: 1_798_761_000)
        XCTAssertEqual(
            ReportExportNaming.baseFilename(
                logicalPeriodID: "month.2027-13",
                reportStartDate: start,
                reportEndDate: start.addingTimeInterval(30 * 86_400)
            ),
            "Mileage-2026-12"
        )
    }
}
