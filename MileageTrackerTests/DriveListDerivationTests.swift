import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class DriveListDerivationTests: XCTestCase {
    func testHeaderScopesFlattenTheSameSectionLocalOrderTheyRender() throws {
        let calendar = Calendar(identifier: .gregorian)
        let june = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 15, hour: 9)
        ))
        let july = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 15, hour: 9)
        ))
        let julyLongest = makeTrip(startDate: july, miles: 100, classification: .personal)
        let julyShortest = makeTrip(
            startDate: july.addingTimeInterval(3_600),
            miles: 1,
            classification: .personal
        )
        let juneLongest = makeTrip(startDate: june, miles: 90, classification: .personal)
        let juneShortest = makeTrip(
            startDate: june.addingTimeInterval(3_600),
            miles: 2,
            classification: .personal
        )

        let derivation = DriveListDerivation(
            trips: [juneShortest, julyShortest, juneLongest, julyLongest],
            scope: .allTrips,
            sortOption: .longestDistance,
            tripFilter: .all,
            vehicleFilter: .all,
            primaryVehicleID: nil
        )

        XCTAssertEqual(derivation.monthGroups.count, 2)
        XCTAssertEqual(
            derivation.visibleOrder,
            [julyLongest.id, julyShortest.id, juneLongest.id, juneShortest.id]
        )
        XCTAssertEqual(
            derivation.visibleOrder,
            derivation.monthGroups.flatMap(\.trips).map(\.id)
        )
    }

    func testMonthRowsApplyClassificationAndVehicleFiltersBeforeSorting() throws {
        let calendar = Calendar(identifier: .gregorian)
        let january = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 15, hour: 9)
        ))
        let february = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 2, day: 15, hour: 9)
        ))
        let selectedVehicleID = UUID()
        let otherVehicleID = UUID()
        let shorterMatch = makeTrip(
            startDate: january,
            miles: 3,
            classification: .personal,
            vehicleID: selectedVehicleID
        )
        let longerMatch = makeTrip(
            startDate: january.addingTimeInterval(3_600),
            miles: 8,
            classification: .personal,
            vehicleID: selectedVehicleID
        )
        let wrongClassification = makeTrip(
            startDate: january.addingTimeInterval(7_200),
            miles: 20,
            classification: .business,
            purpose: "Client",
            vehicleID: selectedVehicleID
        )
        let wrongVehicle = makeTrip(
            startDate: january.addingTimeInterval(10_800),
            miles: 30,
            classification: .personal,
            vehicleID: otherVehicleID
        )
        let wrongMonth = makeTrip(
            startDate: february,
            miles: 40,
            classification: .personal,
            vehicleID: selectedVehicleID
        )

        let derivation = DriveListDerivation(
            trips: [
                shorterMatch,
                longerMatch,
                wrongClassification,
                wrongVehicle,
                wrongMonth
            ],
            scope: .month(january),
            sortOption: .longestDistance,
            tripFilter: .personal,
            vehicleFilter: .vehicle(selectedVehicleID),
            primaryVehicleID: selectedVehicleID
        )

        XCTAssertTrue(derivation.monthGroups.isEmpty)
        XCTAssertEqual(derivation.visibleOrder, [longerMatch.id, shorterMatch.id])
    }

    func testYearScopeGroupsItsMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date: (Int, Int, Int, Int) throws -> Date = { year, month, day, hour in
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }
        let january = try date(2026, 1, 1, 0)
        let december = try date(2026, 12, 31, 23)
        let priorYear = try date(2025, 12, 31, 23)
        let nextYear = try date(2027, 1, 1, 0)
        let scope = DriveListScope.year(try date(2026, 6, 15, 12))

        XCTAssertTrue(scope.contains(makeTrip(startDate: january, miles: 1), calendar: calendar))
        XCTAssertTrue(scope.contains(makeTrip(startDate: december, miles: 1), calendar: calendar))
        XCTAssertFalse(scope.contains(makeTrip(startDate: priorYear, miles: 1), calendar: calendar))
        XCTAssertFalse(scope.contains(makeTrip(startDate: nextYear, miles: 1), calendar: calendar))
        XCTAssertTrue(scope.showsPeriodRollup)
        XCTAssertTrue(scope.showsMonthHeaders)

        // Mid-month so the grouping below reads the same month in every
        // timezone: `DriveListDerivation` groups with `Calendar.current`,
        // while the boundary assertions above pin GMT explicitly.
        let midJanuary = makeTrip(startDate: try date(2026, 1, 15, 12), miles: 2, classification: .personal)
        let midDecember = makeTrip(
            startDate: try date(2026, 12, 15, 12),
            miles: 3,
            classification: .business,
            purpose: "Client"
        )
        let derivation = DriveListDerivation(
            trips: [midJanuary, midDecember],
            scope: scope,
            sortOption: .newestFirst,
            tripFilter: .all,
            vehicleFilter: .all,
            primaryVehicleID: nil
        )

        XCTAssertEqual(derivation.monthGroups.count, 2)
        XCTAssertEqual(derivation.visibleOrder, [midDecember.id, midJanuary.id])
        XCTAssertEqual(derivation.visibleOrder, derivation.monthGroups.flatMap(\.trips).map(\.id))
    }

    /// `periodInterval` is the single source the row predicate, the manual-trip
    /// date, and the roll-up's rate anchor all read. The rate anchor in
    /// particular has no other honest date available — pinning the interval is
    /// what keeps it off whichever trip the store happened to publish first.
    func testPeriodIntervalIsTheScopesFilingPeriodAndDrivesTheRowPredicate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date: (Int, Int, Int, Int) throws -> Date = { year, month, day, hour in
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }

        XCTAssertNil(DriveListScope.needsReview.periodInterval(calendar: calendar))
        XCTAssertNil(DriveListScope.allTrips.periodInterval(calendar: calendar))

        let month = DriveListScope.month(try date(2026, 5, 17, 13))
        let monthInterval = try XCTUnwrap(month.periodInterval(calendar: calendar))
        XCTAssertEqual(monthInterval.start, try date(2026, 5, 1, 0))
        XCTAssertEqual(monthInterval.end, try date(2026, 6, 1, 0))

        let year = DriveListScope.year(try date(2026, 5, 17, 13))
        let yearInterval = try XCTUnwrap(year.periodInterval(calendar: calendar))
        XCTAssertEqual(yearInterval.start, try date(2026, 1, 1, 0))
        XCTAssertEqual(yearInterval.end, try date(2027, 1, 1, 0))

        // The hoisted predicate must stay the same predicate: a trip landing
        // exactly on a period's end belongs to the next period, never both.
        for scope in [month, year, .needsReview, .allTrips] as [DriveListScope] {
            let matches = scope.matches(calendar: calendar)
            for trip in [
                makeTrip(startDate: try date(2026, 1, 1, 0), miles: 1),
                makeTrip(startDate: try date(2026, 5, 1, 0), miles: 1),
                makeTrip(startDate: try date(2026, 6, 1, 0), miles: 1),
                makeTrip(startDate: try date(2027, 1, 1, 0), miles: 1)
            ] {
                XCTAssertEqual(
                    matches(trip),
                    scope.contains(trip, calendar: calendar),
                    "\(scope) disagreed with itself on \(trip.startDate)"
                )
            }
        }

        XCTAssertTrue(month.matches(calendar: calendar)(makeTrip(startDate: try date(2026, 5, 1, 0), miles: 1)))
        XCTAssertFalse(month.matches(calendar: calendar)(makeTrip(startDate: try date(2026, 6, 1, 0), miles: 1)))
        XCTAssertTrue(year.matches(calendar: calendar)(makeTrip(startDate: try date(2026, 1, 1, 0), miles: 1)))
        XCTAssertFalse(year.matches(calendar: calendar)(makeTrip(startDate: try date(2027, 1, 1, 0), miles: 1)))
    }

    func testSuccessorsFollowEverySortAcrossMonthAndYearHeaders() throws {
        let calendar = Calendar(identifier: .gregorian)
        let december = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 15, hour: 9)))
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 9)))
        let decemberShort = makeTrip(startDate: december, miles: 1)
        let decemberLong = makeTrip(startDate: december.addingTimeInterval(3_600), miles: 9)
        let januaryShort = makeTrip(startDate: january, miles: 2)
        let januaryLong = makeTrip(startDate: january.addingTimeInterval(3_600), miles: 8)
        let source = [decemberLong, januaryShort, decemberShort, januaryLong]
        let cases: [(DriveSortOption, [TripSummary])] = [
            (.newestFirst, [januaryLong, januaryShort, decemberLong, decemberShort]),
            (.oldestFirst, [decemberShort, decemberLong, januaryShort, januaryLong]),
            (.longestDistance, [januaryLong, januaryShort, decemberLong, decemberShort]),
            (.shortestDistance, [januaryShort, januaryLong, decemberShort, decemberLong])
        ]
        for (sort, expected) in cases {
            let derivation = DriveListDerivation(
                trips: source, scope: .allTrips, sortOption: sort,
                tripFilter: .all, vehicleFilter: .all, primaryVehicleID: nil
            )
            XCTAssertEqual(derivation.visibleOrder, expected.map(\.id))
            XCTAssertEqual(derivation.nextTripByID.count, 3)
            for index in 0..<3 {
                XCTAssertEqual(derivation.nextTripByID[expected[index].id]?.id, expected[index + 1].id)
            }
            XCTAssertNil(derivation.nextTripByID[expected[3].id])
        }
    }

    func testSuccessorsUseSearchClassificationAndVehicleFilteredRows() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let vehicle = UUID()
        var source = (0..<5).map { index in
            var trip = makeTrip(
                startDate: start.addingTimeInterval(Double(index) * 3_600), miles: Double(index + 1),
                classification: .business, vehicleID: vehicle
            )
            trip.notes = "client needle"
            return trip
        }
        source[1].classification = .personal
        source[2].vehicleID = UUID()
        source[3].notes = "different job"
        let derivation = DriveListDerivation(
            trips: source, scope: .allTrips, sortOption: .newestFirst,
            tripFilter: .business, vehicleFilter: .vehicle(vehicle), primaryVehicleID: vehicle,
            searchText: "needle"
        )
        XCTAssertEqual(derivation.visibleOrder, [source[4].id, source[0].id])
        XCTAssertEqual(derivation.nextTripByID[source[4].id]?.id, source[0].id)
        XCTAssertEqual(derivation.nextTripByID.count, 1)
        XCTAssertNil(derivation.nextTripByID[source[0].id])
    }

    func testAllScopesHaveNoBoundaryForEmptyOrSingleTripLists() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = makeTrip(startDate: start, miles: 3)
        for scope in [DriveListScope.needsReview, .allTrips, .month(start), .year(start)] {
            for source in [[], [trip]] as [[TripSummary]] {
                let derivation = DriveListDerivation(
                    trips: source, scope: scope, sortOption: .newestFirst,
                    tripFilter: .all, vehicleFilter: .all, primaryVehicleID: nil
                )
                XCTAssertEqual(derivation.trips.count, source.count)
                XCTAssertTrue(derivation.nextTripByID.isEmpty)
            }
        }
    }

}
