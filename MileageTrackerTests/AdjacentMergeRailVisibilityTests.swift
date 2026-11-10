import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class AdjacentMergeOverlayVisibilityTests: XCTestCase {
    func testDifferentDatesAndClassificationsDoNotHideTheBoundary() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeTrip(startDate: start, miles: 2, classification: .business)
        let second = makeTrip(startDate: start.addingTimeInterval(86_400), miles: 3, classification: .notADrive)
        XCTAssertTrue(AdjacentMergeOverlayVisibility.canShow(
            isEditing: false, canMerge: TripMergePolicy.canMergeAdjacentTrips(first, second)
        ))
        XCTAssertFalse(AdjacentMergeOverlayVisibility.canShow(
            isEditing: true, canMerge: TripMergePolicy.canMergeAdjacentTrips(first, second)
        ))
        XCTAssertFalse(AdjacentMergeOverlayVisibility.canShow(
            isEditing: false, canMerge: TripMergePolicy.canMergeAdjacentTrips(first, first)
        ))
    }
}
