import XCTest
@testable import AppCore

final class AddressNormalizerTests: XCTestCase {
    func testSuffixVariantsNormalizeToSameForm() {
        // Example endpoints for the isolated demo store.
        XCTAssertEqual(
            AddressNormalizer.normalizedStreetText("350 5th Avenue"),
            AddressNormalizer.normalizedStreetText("350 5th Ave.")
        )
        XCTAssertEqual(
            AddressNormalizer.normalizedStreetText("111 Example Street"),
            AddressNormalizer.normalizedStreetText("111 Example St")
        )
        XCTAssertEqual(
            AddressNormalizer.normalizedStreetText("233 S Wacker Drive"),
            AddressNormalizer.normalizedStreetText("233 South Wacker Dr")
        )
        XCTAssertEqual(
            AddressNormalizer.normalizedStreetText("1600 Grand Boulevard"),
            AddressNormalizer.normalizedStreetText("1600 Grand Blvd")
        )
        XCTAssertEqual(
            AddressNormalizer.normalizedStreetText("42 Ocean Parkway"),
            AddressNormalizer.normalizedStreetText("42 Ocean Pkwy")
        )
    }

    func testPunctuationWhitespaceAndCase() {
        XCTAssertEqual(AddressNormalizer.normalizedStreetText("  89 E. 42nd  St. "), "89 e 42nd st")
        XCTAssertEqual(
            AddressNormalizer.normalizedStreetText("350 5th Ave, Floor 21"),
            "350 5th ave floor 21"
        )
    }

    func testIdempotent() {
        let once = AddressNormalizer.normalizedStreetText("233 South Wacker Drive")
        XCTAssertEqual(AddressNormalizer.normalizedStreetText(once), once)
    }

    func testTokenBoundarySafety() {
        // Whole-token mapping only: "Streeter" is a name, not a suffix.
        XCTAssertEqual(AddressNormalizer.normalizedStreetText("4 Streeter Ln"), "4 streeter ln")
    }

    func testNilAndEmpty() {
        XCTAssertNil(AddressNormalizer.normalizedStreetText(nil))
        XCTAssertNil(AddressNormalizer.normalizedStreetText("   "))
    }

    /// Documented miss: "saint" is deliberately unmapped (mapping it would
    /// collide with Street abbreviations more often than the miss costs).
    func testSaintVariantsDeliberatelyDoNotMatch() {
        XCTAssertNotEqual(
            AddressNormalizer.normalizedStreetText("192 Saint Marks Ave"),
            AddressNormalizer.normalizedStreetText("192 St Marks Ave")
        )
    }
}
