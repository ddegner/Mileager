import Foundation
import XCTest
@testable import AppCore

final class CurrencyFormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    func testLabelFormatsUSD() {
        XCTAssertEqual(CurrencyFormatting.label(12.34, code: "USD", locale: enUS), "$12.34")
    }

    func testLabelFormatsEURInUSLocale() {
        XCTAssertEqual(CurrencyFormatting.label(12.34, code: "EUR", locale: enUS), "€12.34")
    }

    func testSymbolForCommonCodes() {
        XCTAssertEqual(CurrencyFormatting.symbol(code: "USD", locale: enUS), "$")
        XCTAssertEqual(CurrencyFormatting.symbol(code: "EUR", locale: enUS), "€")
        XCTAssertEqual(CurrencyFormatting.symbol(code: "GBP", locale: enUS), "£")
    }

    func testRatePerUnitSuffix() {
        XCTAssertEqual(CurrencyFormatting.ratePerUnitSuffix(code: "USD", unit: .miles, locale: enUS), "$/mi")
        XCTAssertEqual(CurrencyFormatting.ratePerUnitSuffix(code: "EUR", unit: .kilometers, locale: enUS), "€/km")
    }
}
