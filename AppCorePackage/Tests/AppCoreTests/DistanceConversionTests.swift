import AppCore
import XCTest

final class DistanceConversionTests: XCTestCase {
    func testMilesMetersRoundTripUsesSingleConversionConstant() {
        let meters = DistanceConversion.meters(fromMiles: 12.3)

        XCTAssertEqual(meters, 19_794.9312, accuracy: 0.0001)
        XCTAssertEqual(DistanceConversion.miles(fromMeters: meters), 12.3, accuracy: 0.0001)
    }
}
