import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class MileageAppModelMergeTests: XCTestCase {
    func testEveryDistinctPairIsEligibleRegardlessOfClassificationOrOverlap() throws {
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let categories: [TripClassification?] = [nil] + TripClassification.allCases.map { Optional($0) }
        for firstCategory in categories {
            for secondCategory in categories {
                let first = makeTrip(startDate: start, miles: 4, classification: firstCategory)
                for offset in [0, 600, 3_600, 3 * 86_400] as [TimeInterval] {
                    let second = makeTrip(
                        startDate: start.addingTimeInterval(offset), miles: 6, classification: secondCategory
                    )
                    XCTAssertTrue(model.canMergeAdjacentTrips(first, second))
                    XCTAssertTrue(model.canMergeAdjacentTrips(second, first))
                }
                XCTAssertFalse(model.canMergeAdjacentTrips(first, first))
            }
        }
    }

    func testAlreadyMergedTripCanMergeWithAnotherDisplayedTrip() throws {
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var sources: [TripSummary] = []
        for index in 0..<3 {
            sources.append(try model.tripStore.createManualTrip(ManualTripInput(
                startDate: start.addingTimeInterval(Double(index) * 600),
                endDate: start.addingTimeInterval(3_600),
                distanceMeters: 1_000,
                classification: index == 2 ? .notADrive : .business
            )))
        }
        let merged = try model.tripStore.mergeTrips(ids: sources.prefix(2).map(\.id))
        XCTAssertTrue(merged.isMerged)
        XCTAssertTrue(model.canMergeAdjacentTrips(merged, sources[2]))
        model.merge(tripIDs: [merged.id, sources[2].id])
        XCTAssertEqual(model.trips.count, 1)
        XCTAssertEqual(model.trips.first?.legs.count, 3)
    }
}
