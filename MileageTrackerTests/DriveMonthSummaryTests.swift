import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class DriveMonthSummaryTests: XCTestCase {
    func testGroupsSummarizeBusinessPersonalAndUnresolvedTrips() throws {
        let calendar = Calendar(identifier: .gregorian)
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 15)))
        let trips = [
            makeTrip(startDate: january, miles: 10, classification: .business, reviewStatus: .readyToExport, purpose: "Client", tolls: 2, parking: 3),
            makeTrip(startDate: january.addingTimeInterval(3_600), miles: 4, classification: .personal, reviewStatus: .readyToExport),
            makeTrip(startDate: january.addingTimeInterval(7_200), miles: 6, classification: nil, reviewStatus: .needsReview, needsAttention: true),
            makeTrip(startDate: february, miles: 8, classification: .business, reviewStatus: .readyToExport, purpose: "Vendor")
        ]

        let groups = DriveMonthSummary.groups(for: trips, sort: .newestFirst, calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].summary.businessMiles, 8, accuracy: 0.001)
        XCTAssertEqual(groups[1].summary.driveCount, 3)
        XCTAssertEqual(groups[1].summary.totalMiles, 20, accuracy: 0.001)
        XCTAssertEqual(groups[1].summary.businessDriveCount, 1)
        XCTAssertEqual(groups[1].summary.businessMiles, 10, accuracy: 0.001)
        XCTAssertEqual(groups[1].summary.personalMiles, 4, accuracy: 0.001)
        XCTAssertEqual(groups[1].summary.businessParkingAndTolls, 5, accuracy: 0.001)
        XCTAssertEqual(groups[1].summary.unresolvedCount, 1)
        XCTAssertEqual(groups[1].summary.unclassifiedCount, 1)
    }

    func testNotADriveTripsStayInGroupButAreExcludedFromTotals() throws {
        let calendar = Calendar(identifier: .gregorian)
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let trips = [
            makeTrip(startDate: january, miles: 10, classification: .business, reviewStatus: .readyToExport, purpose: "Client"),
            makeTrip(startDate: january.addingTimeInterval(3_600), miles: 4, classification: .personal, reviewStatus: .readyToExport),
            makeTrip(startDate: january.addingTimeInterval(7_200), miles: 6, classification: .notADrive, reviewStatus: .readyToExport)
        ]

        let groups = DriveMonthSummary.groups(for: trips, sort: .newestFirst, calendar: calendar)

        XCTAssertEqual(groups.count, 1)
        let summary = groups[0].summary
        // The not-a-drive capture stays visible in the group's rows...
        XCTAssertEqual(groups[0].trips.count, 3)
        // ...but contributes nothing to drive counts or mileage totals.
        XCTAssertEqual(summary.driveCount, 2)
        XCTAssertEqual(summary.totalMiles, 14, accuracy: 0.001)
        XCTAssertEqual(summary.businessMiles, 10, accuracy: 0.001)
        XCTAssertEqual(summary.personalMiles, 4, accuracy: 0.001)
        XCTAssertEqual(summary.unresolvedCount, 0)
        XCTAssertEqual(summary.unclassifiedCount, 0)
    }

}
