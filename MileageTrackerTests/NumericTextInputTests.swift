import AppCore
import XCTest
@testable import MileageTracker

final class NumericTextInputTests: XCTestCase {
    func testNonnegativeDoubleRejectsBlankNegativeAndNonFiniteInput() {
        XCTAssertEqual(NumericTextInput.nonnegativeDouble(" 12.5 "), 12.5)
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("0"), 0)
        XCTAssertNil(NumericTextInput.nonnegativeDouble(""))
        XCTAssertNil(NumericTextInput.nonnegativeDouble("-1"))
        XCTAssertNil(NumericTextInput.nonnegativeDouble("nan"))
    }

    func testFeePoliciesDifferentiateBlankZeroAndPositiveRequired() {
        XCTAssertEqual(NumericTextInput.nonnegativeDoubleOrZeroIfBlank(""), 0)
        XCTAssertEqual(NumericTextInput.nonnegativeDoubleOrZeroIfBlank(" 3.25 "), 3.25)
        XCTAssertNil(NumericTextInput.nonnegativeDoubleOrZeroIfBlank("-0.25"))

        XCTAssertEqual(NumericTextInput.positiveDouble("3.25"), 3.25)
        XCTAssertNil(NumericTextInput.positiveDouble("0"))
    }

    func testValueTextFormatsMetersInUnit() {
        XCTAssertEqual(
            DistanceFormatting.valueText(meters: 8_046.72, unit: .miles, locale: Locale(identifier: "en_US")),
            "5.00"
        )
        XCTAssertEqual(
            DistanceFormatting.valueText(meters: 8_046.72, unit: .kilometers, locale: Locale(identifier: "en_US")),
            "8.05"
        )
    }

    func testCommaDecimalInputParses() {
        let fr = Locale(identifier: "fr_FR")
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("3,5", locale: fr), 3.5)
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("0,725", locale: fr), 0.725)
        // Mixed separators are ambiguous and rejected.
        XCTAssertNil(NumericTextInput.nonnegativeDouble("1.234,5", locale: fr))
        XCTAssertNil(NumericTextInput.nonnegativeDouble("1,234.5", locale: fr))
    }

    func testCommaIsGroupingNotDecimalInDotLocales() {
        // Pasted US-grouped numbers must not silently shrink 1000×:
        // "12,000" as an odometer reading is twelve thousand, not 12.0.
        let us = Locale(identifier: "en_US")
        XCTAssertNil(NumericTextInput.nonnegativeDouble("12,000", locale: us))
        XCTAssertNil(NumericTextInput.nonnegativeDouble("1,250", locale: us))
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("12.5", locale: us), 12.5)
    }

    func testNonASCIIDecimalLocalesParse() {
        // Persian/Arabic devices format numbers with locale digits and the
        // Arabic decimal separator "٫"; the pre-filled rate field must parse
        // them back rather than reject the value as invalid.
        let fa = Locale(identifier: "fa_IR")
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("۰٫۷۲۵", locale: fa), 0.725)
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("۱۲٫۵", locale: fa), 12.5)

        let ar = Locale(identifier: "ar_SA")
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("٠٫٧٢٥", locale: ar), 0.725)

        // Devanagari digits with an ASCII dot separator also parse.
        let hi = Locale(identifier: "hi_IN")
        XCTAssertEqual(NumericTextInput.nonnegativeDouble("०.७२५", locale: hi), 0.725)
    }

    func testLocaleFormattedRateRoundTrips() {
        // Reproduces the settings-screen path: format the stored rate with a
        // locale-aware NumberFormatter, then parse the field back. Every
        // supported (and several unsupported) regions must survive the trip.
        for identifier in ["en_US", "fr_FR", "de_DE", "es_ES", "fa_IR", "ar_SA", "ne_NP"] {
            let locale = Locale(identifier: identifier)
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = locale
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = 3
            formatter.maximumFractionDigits = 3
            let text = formatter.string(from: NSNumber(value: 0.725)) ?? "0.725"
            XCTAssertEqual(
                NumericTextInput.nonnegativeDouble(text, locale: locale),
                0.725,
                "locale \(identifier) formatted \(text) but it did not parse back"
            )
        }
    }
}
