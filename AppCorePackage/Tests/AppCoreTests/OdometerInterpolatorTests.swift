import XCTest
@testable import AppCore

final class OdometerInterpolatorTests: XCTestCase {
    private static let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func checkpoint(_ year: Int, _ month: Int, _ day: Int, miles: Double) -> OdometerCheckpoint {
        OdometerCheckpoint(date: date(year, month, day), odometerMiles: miles)
    }

    func testEmptyCheckpointsProduceNoEstimate() {
        let estimate = OdometerInterpolator.estimate(
            checkpoints: [],
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )

        XCTAssertEqual(estimate, .none)
        XCTAssertNil(estimate.totalMiles)
        XCTAssertNil(estimate.businessUsePercent(businessMiles: 100))
    }

    func testSingleCheckpointProducesSingleReading() {
        let reading = checkpoint(2026, 6, 15, miles: 87_412)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [reading],
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )

        XCTAssertEqual(estimate, .singleReading(reading))
        XCTAssertNil(estimate.totalMiles)
    }

    func testCheckpointsEntirelyBeforePeriodFallBackToLatestReading() {
        let older = checkpoint(2025, 1, 1, miles: 70_000)
        let newer = checkpoint(2025, 7, 1, miles: 76_000)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [older, newer],
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )

        XCTAssertEqual(estimate, .singleReading(newer))
    }

    func testCheckpointsEntirelyAfterPeriodFallBackToEarliestReading() {
        let earlier = checkpoint(2026, 7, 1, miles: 90_000)
        let later = checkpoint(2027, 1, 1, miles: 95_000)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [later, earlier],
            start: date(2026, 1, 1),
            end: date(2026, 2, 1)
        )

        XCTAssertEqual(estimate, .singleReading(earlier))
    }

    func testCheckpointsExactlyAtBoundariesAreExact() {
        let start = checkpoint(2026, 6, 1, miles: 10_000)
        let end = checkpoint(2026, 7, 1, miles: 11_200)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [start, end],
            start: start.date,
            end: end.date
        )

        guard case let .range(startBoundary, endBoundary, firstDate, lastDate) = estimate else {
            return XCTFail("Expected range, got \(estimate)")
        }
        XCTAssertEqual(startBoundary, .init(miles: 10_000, kind: .exact))
        XCTAssertEqual(endBoundary, .init(miles: 11_200, kind: .exact))
        XCTAssertEqual(firstDate, start.date)
        XCTAssertEqual(lastDate, end.date)
        XCTAssertFalse(estimate.isEstimated)
        XCTAssertEqual(estimate.totalMiles, 1_200)
    }

    func testTwiceYearlyReadingsInterpolateMidYearMonth() {
        let january = checkpoint(2026, 1, 1, miles: 10_000)
        let july = checkpoint(2026, 7, 1, miles: 16_000)
        let periodStart = date(2026, 6, 1)
        let periodEnd = date(2026, 6, 30)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [january, july],
            start: periodStart,
            end: periodEnd
        )

        guard case let .range(startBoundary, endBoundary, _, _) = estimate else {
            return XCTFail("Expected range, got \(estimate)")
        }
        XCTAssertEqual(startBoundary.kind, .interpolated)
        XCTAssertEqual(endBoundary.kind, .interpolated)
        // Linear in elapsed time across the checkpoint span.
        let span = july.date.timeIntervalSince(january.date)
        let expectedStart = 10_000 + 6_000 * periodStart.timeIntervalSince(january.date) / span
        let expectedEnd = 10_000 + 6_000 * periodEnd.timeIntervalSince(january.date) / span
        XCTAssertEqual(startBoundary.miles, expectedStart, accuracy: 0.001)
        XCTAssertEqual(endBoundary.miles, expectedEnd, accuracy: 0.001)
        XCTAssertTrue(estimate.isEstimated)
        XCTAssertEqual(estimate.totalMiles!, expectedEnd - expectedStart, accuracy: 0.001)
    }

    func testPeriodExtendingBeyondSpanClampsToNearestReading() {
        let first = checkpoint(2026, 6, 10, miles: 12_000)
        let second = checkpoint(2026, 6, 20, miles: 12_400)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [first, second],
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )

        guard case let .range(startBoundary, endBoundary, _, _) = estimate else {
            return XCTFail("Expected range, got \(estimate)")
        }
        XCTAssertEqual(startBoundary, .init(miles: 12_000, kind: .clamped))
        XCTAssertEqual(endBoundary, .init(miles: 12_400, kind: .clamped))
        XCTAssertEqual(estimate.totalMiles, 400)
    }

    func testNonMonotonicCheckpointsYieldNoUsableTotal() {
        let first = checkpoint(2026, 6, 1, miles: 90_000)
        let typo = checkpoint(2026, 7, 1, miles: 9_000)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [first, typo],
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )

        XCTAssertEqual(estimate.totalMiles, -81_000)
        XCTAssertNil(estimate.businessUsePercent(businessMiles: 100))
    }

    func testBusinessUsePercent() {
        let estimate = OdometerInterpolator.estimate(
            checkpoints: [
                checkpoint(2026, 6, 1, miles: 10_000),
                checkpoint(2026, 7, 1, miles: 11_000)
            ],
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )

        XCTAssertEqual(estimate.businessUsePercent(businessMiles: 380)!, 38, accuracy: 0.001)
        XCTAssertNil(estimate.businessUsePercent(businessMiles: 1_500), "Ratios over 100% are suppressed")
        XCTAssertNil(estimate.businessUsePercent(businessMiles: -5), "Negative ratios are suppressed")
    }

    func testDuplicateCheckpointDatesUseLaterValueWithoutDividingByZero() {
        let first = checkpoint(2026, 6, 1, miles: 10_000)
        let duplicateA = checkpoint(2026, 6, 15, miles: 10_500)
        let duplicateB = checkpoint(2026, 6, 15, miles: 10_600)
        let last = checkpoint(2026, 7, 1, miles: 11_000)

        let estimate = OdometerInterpolator.estimate(
            checkpoints: [first, duplicateA, duplicateB, last],
            start: date(2026, 6, 15),
            end: date(2026, 7, 1)
        )

        guard case let .range(startBoundary, endBoundary, _, _) = estimate else {
            return XCTFail("Expected range, got \(estimate)")
        }
        XCTAssertEqual(startBoundary.kind, .exact)
        XCTAssertEqual(startBoundary.miles, 10_600)
        XCTAssertEqual(endBoundary, .init(miles: 11_000, kind: .exact))
    }
}
