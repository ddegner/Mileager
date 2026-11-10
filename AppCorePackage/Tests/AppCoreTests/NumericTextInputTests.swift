import XCTest
@testable import AppCore

final class NumericTextInputTests: XCTestCase {
    func testRejectsAmbiguousGroupingAndAcceptsLocaleDecimals() {
        XCTAssertNil(NumericTextInput.nonnegativeDouble(
            "12,000",
            locale: Locale(identifier: "en_US")
        ))
        XCTAssertEqual(NumericTextInput.nonnegativeDouble(
            "3,5",
            locale: Locale(identifier: "de_DE")
        ), 3.5)
        XCTAssertNil(NumericTextInput.nonnegativeDouble(
            "1.234,5",
            locale: Locale(identifier: "de_DE")
        ))
    }

    func testFoldsNonASCIIDigitsAndRejectsInvalidValues() {
        XCTAssertEqual(NumericTextInput.nonnegativeDouble(
            "۰٫۷۲۵",
            locale: Locale(identifier: "fa_IR")
        ), 0.725)
        XCTAssertNil(NumericTextInput.nonnegativeDouble("-1"))
        XCTAssertNil(NumericTextInput.nonnegativeDouble("nan"))
        XCTAssertEqual(NumericTextInput.nonnegativeDoubleOrZeroIfBlank("  "), 0)
    }
}
