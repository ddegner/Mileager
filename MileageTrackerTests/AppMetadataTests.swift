import XCTest

final class AppMetadataTests: XCTestCase {
    func testBundleIncludesSiriSpokenName() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleSpokenName") as? String,
            "my lee jur"
        )
    }

    func testBundleIncludesLocalizedSiriAlternativeName() throws {
        let alternatives = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "INAlternativeAppNames")
                as? [[String: String]]
        )
        XCTAssertEqual(alternatives.count, 1)
        XCTAssertEqual(
            alternatives.first?["INAlternativeAppName"],
            "MILEAGER_ALTERNATIVE_APP_NAME_1"
        )
        XCTAssertEqual(
            Bundle.main.localizedString(
                forKey: "MILEAGER_ALTERNATIVE_APP_NAME_1",
                value: nil,
                table: "InfoPlist"
            ),
            "Mileage Tracker"
        )
    }

    func testBundleDeclaresCurrentDriveUserActivity() throws {
        let activityTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        )
        XCTAssertTrue(activityTypes.contains("com.daviddegner.MileageTracker.viewingCurrentDrive"))
    }
}
