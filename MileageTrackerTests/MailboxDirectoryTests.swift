import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class MailboxDirectoryTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    func testPendingReviewShowsRowWithoutCaughtUpStatus() {
        let presentation = MailboxReviewPresentation(
            needsReviewCount: 3, hasLoadedInitialTrips: true, isReviewSelected: false
        )
        XCTAssertTrue(presentation.showsNeedsReviewRow)
        XCTAssertFalse(presentation.showsCaughtUpStatus)
    }

    func testLoadedEmptyReviewQueueHidesRowAndShowsCaughtUpStatus() {
        let presentation = MailboxReviewPresentation(
            needsReviewCount: 0, hasLoadedInitialTrips: true, isReviewSelected: false
        )
        XCTAssertFalse(presentation.showsNeedsReviewRow)
        XCTAssertTrue(presentation.showsCaughtUpStatus)
    }

    func testLoadingDoesNotPrematurelyShowCaughtUpStatus() {
        let presentation = MailboxReviewPresentation(
            needsReviewCount: 0, hasLoadedInitialTrips: false, isReviewSelected: false
        )
        XCTAssertFalse(presentation.showsNeedsReviewRow)
        XCTAssertFalse(presentation.showsCaughtUpStatus)
    }

    func testFinishingReviewKeepsSelectedRowUntilLeavingInbox() {
        var presentation = MailboxReviewPresentation(
            needsReviewCount: 1, hasLoadedInitialTrips: true, isReviewSelected: true
        )
        presentation.needsReviewCount = 0
        XCTAssertTrue(presentation.showsNeedsReviewRow)
        XCTAssertTrue(presentation.showsCaughtUpStatus)

        presentation.isReviewSelected = false
        XCTAssertFalse(presentation.showsNeedsReviewRow)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9)))
    }

    func testGroupsMonthsUnderYearsNewestFirst() throws {
        let trips = [
            makeTrip(startDate: try date(2026, 5, 10), miles: 5, classification: .personal, reviewStatus: .readyToExport),
            makeTrip(startDate: try date(2026, 7, 2), miles: 8, classification: .personal, reviewStatus: .readyToExport),
            makeTrip(startDate: try date(2025, 11, 4), miles: 3, classification: .personal, reviewStatus: .readyToExport)
        ]

        let directory = MailboxDirectory(trips: trips, now: try date(2026, 7, 25), calendar: calendar)

        XCTAssertEqual(directory.years.count, 2)
        XCTAssertEqual(calendar.component(.year, from: directory.years[0].yearStart), 2026)
        XCTAssertEqual(calendar.component(.year, from: directory.years[1].yearStart), 2025)
        XCTAssertEqual(directory.years[0].months.count, 2)
        XCTAssertEqual(calendar.component(.month, from: directory.years[0].months[0].monthStart), 7)
        XCTAssertEqual(calendar.component(.month, from: directory.years[0].months[1].monthStart), 5)
    }

    func testYearBusinessMilesSumOnlyExportableBusinessTrips() throws {
        let trips = [
            makeTrip(
                startDate: try date(2026, 7, 1),
                miles: 12,
                classification: .business,
                reviewStatus: .readyToExport,
                purpose: "Client"
            ),
            makeTrip(
                startDate: try date(2026, 6, 1),
                miles: 8,
                classification: .business,
                reviewStatus: .needsReview,
                purpose: nil
            ),
            makeTrip(
                startDate: try date(2026, 5, 1),
                miles: 20,
                classification: .personal,
                reviewStatus: .readyToExport
            )
        ]

        let directory = MailboxDirectory(
            trips: trips,
            now: try date(2026, 7, 25),
            calendar: calendar
        )

        XCTAssertEqual(try XCTUnwrap(directory.years.first).businessMiles, 12, accuracy: 0.001)
    }

    /// The badge counts unresolved work: unclassified drives, plus a Business
    /// drive with no purpose (which is excluded from the month's money until
    /// the purpose is written).
    ///
    /// An engine attention flag is deliberately *not* counted. It is the engine
    /// annotating its own recording, not work only the user can do, and a
    /// classified drive carrying one is already reviewed.
    func testNeedsReviewCountCountsUnresolvedWorkAndIgnoresEngineFlags() throws {
        let trips = [
            makeTrip(startDate: try date(2026, 7, 1), miles: 4, classification: nil, reviewStatus: .needsReview),
            makeTrip(startDate: try date(2026, 7, 2), miles: 4, classification: .business, reviewStatus: .needsReview, purpose: nil),
            makeTrip(startDate: try date(2026, 7, 3), miles: 4, classification: .personal, reviewStatus: .readyToExport, needsAttention: true),
            makeTrip(startDate: try date(2026, 7, 4), miles: 4, classification: .business, reviewStatus: .readyToExport, purpose: "Client")
        ]

        let directory = MailboxDirectory(trips: trips, now: try date(2026, 7, 25), calendar: calendar)

        XCTAssertEqual(directory.needsReviewCount, 2)
    }

    /// The vehicle scope narrows what a list shows and what a month's money
    /// totals, but never the count of outstanding work — a badge that
    /// disagreed with the review notification would be the exact defect the
    /// single-predicate rule exists to prevent.
    func testVehicleScopeNarrowsMonthsButNotTheBadge() throws {
        let honda = UUID()
        let volvo = UUID()
        let trips = [
            makeTrip(startDate: try date(2026, 7, 1), miles: 4, classification: nil, reviewStatus: .needsReview, vehicleID: honda),
            makeTrip(startDate: try date(2026, 6, 1), miles: 4, classification: nil, reviewStatus: .needsReview, vehicleID: volvo)
        ]

        let scoped = MailboxDirectory(
            trips: trips,
            vehicleFilter: .vehicle(honda),
            primaryVehicleID: honda,
            now: try date(2026, 7, 25),
            calendar: calendar
        )

        XCTAssertEqual(scoped.needsReviewCount, 2, "The badge is never vehicle-scoped")
        XCTAssertEqual(scoped.years.first?.months.count, 1, "The month list is vehicle-scoped")
    }

    func testDefaultExportMonthPrefersCurrentMonthThenNewest() throws {
        let july = makeTrip(startDate: try date(2026, 7, 3), miles: 4, classification: .personal, reviewStatus: .readyToExport)
        let may = makeTrip(startDate: try date(2026, 5, 3), miles: 4, classification: .personal, reviewStatus: .readyToExport)

        let withCurrent = MailboxDirectory(trips: [july, may], now: try date(2026, 7, 25), calendar: calendar)
        XCTAssertEqual(
            calendar.component(.month, from: try XCTUnwrap(withCurrent.defaultExportMonthStart)),
            7
        )

        let withoutCurrent = MailboxDirectory(trips: [may], now: try date(2026, 7, 25), calendar: calendar)
        XCTAssertEqual(
            calendar.component(.month, from: try XCTUnwrap(withoutCurrent.defaultExportMonthStart)),
            5
        )
    }

    func testEmptyDirectoryReportsEmpty() throws {
        let directory = MailboxDirectory(trips: [], now: try date(2026, 7, 25), calendar: calendar)
        XCTAssertTrue(directory.isEmpty)
        XCTAssertTrue(directory.years.isEmpty)
        XCTAssertNil(directory.defaultExportMonthStart)
        XCTAssertEqual(directory.needsReviewCount, 0)
    }

    func testGroupLookupByMonthStart() throws {
        let trips = [makeTrip(startDate: try date(2026, 5, 10), miles: 5, classification: .personal, reviewStatus: .readyToExport)]
        let directory = MailboxDirectory(trips: trips, now: try date(2026, 7, 25), calendar: calendar)
        let monthStart = try XCTUnwrap(directory.years.first?.months.first?.monthStart)

        XCTAssertNotNil(directory.group(forMonthStart: monthStart))
        XCTAssertNil(directory.group(forMonthStart: try date(2026, 1, 1)))
    }
}
