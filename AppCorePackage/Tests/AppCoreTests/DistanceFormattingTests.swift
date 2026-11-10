import Foundation
import XCTest
@testable import AppCore

final class DistanceFormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private let deDE = Locale(identifier: "de_DE")

    func testLabelFormatsMilesAndKilometers() {
        let tenKm = 10_000.0
        XCTAssertEqual(DistanceFormatting.label(meters: tenKm, unit: .miles, locale: enUS), "6.2 mi")
        XCTAssertEqual(DistanceFormatting.label(meters: tenKm, unit: .kilometers, locale: enUS), "10.0 km")
    }

    func testLabelUsesLocaleDigitsButExplicitUnit() {
        // German locale formatting with comma decimal; the unit stays what the
        // user chose (override beats locale).
        let label = DistanceFormatting.label(meters: 10_300, unit: .kilometers, locale: deDE)
        XCTAssertTrue(label.contains("10,3"), "expected comma decimal, got \(label)")
        XCTAssertTrue(label.contains("km"), "expected km symbol, got \(label)")

        let milesLabel = DistanceFormatting.label(meters: 10_300, unit: .miles, locale: deDE)
        XCTAssertTrue(milesLabel.contains("mi"), "override must keep miles even in de_DE, got \(milesLabel)")
    }

    func testValueTextNeverUsesGroupingSeparators() {
        // 2,000 miles of meters — a grouped "2,000.00" would not round-trip
        // through the decimal-pad parser.
        let meters = DistanceConversion.meters(fromMiles: 2_000)
        XCTAssertEqual(DistanceFormatting.valueText(meters: meters, unit: .miles, locale: enUS), "2000.00")
    }

    func testNumberOmitsUnitsButKeepsLocaleGroupingAndUnitConversion() {
        let meters = DistanceConversion.meters(fromMiles: 1_976.6)
        XCTAssertEqual(DistanceFormatting.number(meters: meters, unit: .miles, locale: enUS), "1,976.6")
        XCTAssertEqual(DistanceFormatting.number(meters: meters, unit: .miles, locale: deDE), "1.976,6")
        XCTAssertEqual(DistanceFormatting.number(meters: 10_000, unit: .kilometers, locale: enUS), "10.0")
        XCTAssertEqual(DistanceFormatting.number(meters: 10_000, unit: .miles, locale: enUS), "6.2")
        XCTAssertEqual(DistanceFormatting.number(meters: 0, unit: .miles, locale: enUS), "0.0")
    }

    func testWideLabelPreservesSpokenUnitsAndChosenMeasurementSystem() {
        XCTAssertEqual(DistanceFormatting.label(meters: 10_000, unit: .kilometers, width: .wide, locale: enUS), "10.0 kilometers")
        XCTAssertEqual(DistanceFormatting.label(meters: 10_000, unit: .miles, width: .wide, locale: enUS), "6.2 miles")
        XCTAssertEqual(DistanceFormatting.label(meters: 10_300, unit: .kilometers, width: .wide, locale: deDE), "10,3 Kilometer")
    }

    func testCsvValueStaysPOSIX() {
        XCTAssertEqual(DistanceFormatting.csvValue(meters: 8_046.72, unit: .miles), "5.00")
        XCTAssertEqual(DistanceFormatting.csvValue(meters: 8_046.72, unit: .kilometers), "8.05")
    }

    func testSystemDefaultFollowsMeasurementSystem() {
        XCTAssertEqual(DistanceUnit.systemDefault(for: Locale(identifier: "en_US")), .miles)
        XCTAssertEqual(DistanceUnit.systemDefault(for: Locale(identifier: "en_GB")), .miles) // UK roads are miles
        XCTAssertEqual(DistanceUnit.systemDefault(for: Locale(identifier: "de_DE")), .kilometers)
        XCTAssertEqual(DistanceUnit.systemDefault(for: Locale(identifier: "fr_FR")), .kilometers)
        XCTAssertEqual(DistanceUnit.systemDefault(for: Locale(identifier: "es_MX")), .kilometers)
    }

    func testPreferenceResolution() {
        XCTAssertEqual(DistanceUnitPreference.system.resolved(for: Locale(identifier: "de_DE")), .kilometers)
        XCTAssertEqual(DistanceUnitPreference.miles.resolved(for: Locale(identifier: "de_DE")), .miles)
        XCTAssertEqual(DistanceUnitPreference.kilometers.resolved(for: Locale(identifier: "en_US")), .kilometers)
    }
}
