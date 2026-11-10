import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class ReportIntentTests: XCTestCase {
    private var model: MileageAppModel!
    private var calendar: Calendar!
    /// Fixed clock for month resolution: 2026-07-08 12:00 local time.
    private var now: Date!

    override func setUp() async throws {
        try await super.setUp()
        TripIntentDataProvider.isReady = { _ in true }
        let defaults = try makeTestDefaults()
        model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )
        TripIntentDataProvider.modelProvider = { [weak model] in model }
        calendar = Calendar.current
        now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 8,
            hour: 12
        )))
    }

    override func tearDown() async throws {
        TripIntentDataProvider.resetForTesting()
        model = nil
        try await super.tearDown()
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 10) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    @discardableResult
    private func seedTrip(
        classification: TripClassification? = nil,
        startDate: Date,
        miles: Double = 18
    ) throws -> TripSummary {
        let trip = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_800),
            startAddress: "145 Court St, Brooklyn, NY",
            endAddress: "9 Pine St, Darien, CT",
            distanceMeters: DistanceConversion.meters(fromMiles: miles),
            classification: classification,
            businessPurpose: classification == .business ? "Client visit" : nil
        ))
        model.refresh()
        return trip
    }

    private func answer(month: ReportMonthAppEnum) -> MonthlyBusinessMilesAnswer {
        MonthlyBusinessMilesAnswer(
            trips: model.trips,
            month: month,
            now: now,
            calendar: calendar,
            distanceUnit: .miles,
            rate: model.mileageRate,
            currencyCode: model.currencyCode
        )
    }

    // MARK: - Month resolution

    func testThisMonthAndLastMonthResolveAroundNow() throws {
        XCTAssertEqual(
            ReportMonthAppEnum.thisMonth.monthInterval(containing: now, calendar: calendar).start,
            try date(year: 2026, month: 7, day: 1, hour: 0)
        )
        XCTAssertEqual(
            ReportMonthAppEnum.lastMonth.monthInterval(containing: now, calendar: calendar).start,
            try date(year: 2026, month: 6, day: 1, hour: 0)
        )
    }

    func testNamedMonthResolvesToMostRecentOccurrence() throws {
        // June has already happened this year.
        XCTAssertEqual(
            ReportMonthAppEnum.june.monthInterval(containing: now, calendar: calendar).start,
            try date(year: 2026, month: 6, day: 1, hour: 0)
        )
        // July is the current month.
        XCTAssertEqual(
            ReportMonthAppEnum.july.monthInterval(containing: now, calendar: calendar).start,
            try date(year: 2026, month: 7, day: 1, hour: 0)
        )
        // December hasn't happened yet this year, so it means last December.
        XCTAssertEqual(
            ReportMonthAppEnum.december.monthInterval(containing: now, calendar: calendar).start,
            try date(year: 2025, month: 12, day: 1, hour: 0)
        )
    }

    // MARK: - Totals

    func testAnswerCountsOnlyExportableBusinessTripsInMonth() throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3), miles: 10)
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 20), miles: 15)
        try seedTrip(classification: .personal, startDate: date(year: 2026, month: 6, day: 10), miles: 40)
        try seedTrip(classification: .notADrive, startDate: date(year: 2026, month: 6, day: 11), miles: 5)
        // Unclassified in June, and a business trip outside June.
        try seedTrip(classification: nil, startDate: date(year: 2026, month: 6, day: 12), miles: 7)
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 5, day: 30), miles: 99)

        let june = answer(month: .june)

        XCTAssertEqual(june.summary.businessDriveCount, 2)
        XCTAssertEqual(june.summary.businessMiles, 25, accuracy: 0.01)
        XCTAssertEqual(june.businessDistanceValue, 25, accuracy: 0.01)
        XCTAssertEqual(june.summary.unclassifiedCount, 1)
        XCTAssertTrue(june.dialogText.contains(june.distanceText))
        XCTAssertTrue(june.dialogText.contains(june.tripCountText))
        XCTAssertNotNil(june.unclassifiedWarningText)
    }

    func testAnswerZeroCaseMentionsPeriodAndSkipsReimbursement() throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3))

        let may = answer(month: .may)

        XCTAssertEqual(may.summary.businessDriveCount, 0)
        XCTAssertEqual(may.businessDistanceValue, 0)
        XCTAssertTrue(may.dialogText.contains(may.periodTitle))
        XCTAssertFalse(may.dialogText.contains(may.reimbursementText))
    }

    // MARK: - Get intent

    func testGetIntentThrowsWhenStoreUnavailable() async throws {
        TripIntentDataProvider.modelProvider = { nil }
        let intent = GetMonthlyBusinessMilesIntent(month: .lastMonth)

        do {
            _ = try await intent.perform()
            XCTFail("Expected startupUnavailable")
        } catch let error as TripIntentError {
            guard case .startupUnavailable = error else {
                return XCTFail("Expected startupUnavailable, got \(error)")
            }
        }
    }

    // MARK: - Open intent

    func testOpenIntentRequestsReportsForResolvedMonth() async throws {
        let intent = OpenMileageReportIntent(month: .lastMonth)

        _ = try await intent.perform()

        let expected = ReportMonthAppEnum.lastMonth.monthInterval().start
        XCTAssertEqual(model.requestedReportsMonthStart, expected)
    }

    func testOpenIntentThrowsWhenStoreUnavailable() async throws {
        TripIntentDataProvider.modelProvider = { nil }
        let intent = OpenMileageReportIntent(month: .thisMonth)

        do {
            _ = try await intent.perform()
            XCTFail("Expected startupUnavailable")
        } catch let error as TripIntentError {
            guard case .startupUnavailable = error else {
                return XCTFail("Expected startupUnavailable, got \(error)")
            }
        }
        XCTAssertNil(model.requestedReportsMonthStart)
    }

    // MARK: - Month report entity

    func testMonthEntityQuerySuggestsNewestFirstAndResolvesByID() async throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3), miles: 10)
        try seedTrip(classification: .personal, startDate: date(year: 2026, month: 5, day: 10), miles: 4)

        let suggested = try await MonthlyMileageReportEntityQuery().suggestedEntities()

        XCTAssertEqual(suggested.map(\.id), ["2026-06", "2026-05"])
        XCTAssertEqual(suggested.first?.businessTripCount, 1)
        XCTAssertEqual(suggested.first?.businessDistance ?? 0, 10, accuracy: 0.01)

        let resolved = try await MonthlyMileageReportEntityQuery().entities(for: ["2026-05", "1999-01"])
        XCTAssertEqual(resolved.map(\.id), ["2026-05"], "unknown IDs are omitted, not thrown")
    }

    func testMonthEntityStringQueryMatchesPeriodTitle() async throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3))
        let suggested = try await MonthlyMileageReportEntityQuery().suggestedEntities()
        let june = try XCTUnwrap(suggested.first)

        let matched = try await MonthlyMileageReportEntityQuery().entities(matching: june.periodTitle)

        XCTAssertEqual(matched.map(\.id), [june.id])
    }

    func testMonthEntityQueryEmptyWhenStoreUnavailable() async throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3))
        TripIntentDataProvider.modelProvider = { nil }

        let suggested = try await MonthlyMileageReportEntityQuery().suggestedEntities()
        let resolved = try await MonthlyMileageReportEntityQuery().entities(for: ["2026-06"])

        XCTAssertTrue(suggested.isEmpty)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testMonthEntitySummarySentenceMatchesSpokenAnswer() async throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3), miles: 10)
        let suggested = try await MonthlyMileageReportEntityQuery().suggestedEntities()
        let june = try XCTUnwrap(suggested.first)

        XCTAssertEqual(june.summarySentence, answer(month: .june).dialogText)
        XCTAssertTrue(june.summarySentence.contains(june.distanceText))
    }

    func testMonthEntityDigestChangesWithRateAndIsOtherwiseStable() throws {
        let trips = [try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3))]
        func entity(rate: MileageRate) -> MonthlyMileageReportEntity? {
            MonthlyMileageReportEntity.entities(
                for: trips, distanceUnit: .miles, rate: rate, currencyCode: "USD"
            ).first
        }

        let base = try XCTUnwrap(entity(rate: .default))
        let same = try XCTUnwrap(entity(rate: .default))
        let repriced = try XCTUnwrap(entity(rate: MileageRate(amountPerUnit: 1.5, unit: .miles)))

        XCTAssertEqual(base.indexDigest, same.indexDigest, "digest is stable across builds of identical content")
        XCTAssertNotEqual(base.indexDigest, repriced.indexDigest, "rate change must re-donate the month")
    }

    func testOpenMonthlyReportIntentRequestsEntityMonth() async throws {
        try seedTrip(classification: .business, startDate: date(year: 2026, month: 6, day: 3))
        let suggested = try await MonthlyMileageReportEntityQuery().suggestedEntities()
        let june = try XCTUnwrap(suggested.first)
        let intent = OpenMonthlyMileageReportIntent()
        intent.target = june

        _ = try await intent.perform()

        XCTAssertEqual(model.requestedReportsMonthStart, june.monthStart)
    }
}
