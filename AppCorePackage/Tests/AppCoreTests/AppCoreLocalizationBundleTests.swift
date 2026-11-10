import Foundation
import XCTest
@testable import AppCore

final class AppCoreLocalizationBundleTests: XCTestCase {
    func testPackageCatalogTranslationsShipInEverySupportedLanguage() throws {
        let resourceBundle = Bundle.appCoreStrings
        let keys = [
            "A business purpose can only be assigned to a Business trip.",
            "A vehicle name can't be empty.",
            "Amounts must be finite numbers greater than or equal to zero.",
            "Bluetooth device not found.",
            "Car connection not found.",
            "Choose a valid effective date.",
            "CloudKit reset is unavailable for the current persistent store.",
            "Coordinates must be finite latitude and longitude values.",
            "Could not find that route. Enter mileage manually.",
            "Diagnostic location sample is malformed.",
            "Diagnostic sample date range is invalid.",
            "Diagnostics reports can include only 1, 3, 7, or 30 days. %lld days is not supported.",
            "Enrichment retry metadata requires the local capture store.",
            "Enter both origin and destination.",
            "Fee not found.",
            "Mileage data changed while the recovery copy was being created. Try again.",
            "Mileage must be a finite number greater than or equal to zero.",
            "Multiple rates",
            "Odometer reading not found.",
            "Odometer readings must be finite numbers greater than or equal to zero.",
            "Only one mileage rate can begin on the same date.",
            "Only merged trips can be un-merged.",
            "Persistent stores failed to load: %@",
            "Raw location samples require the local capture store.",
            "The active drive checkpoint could not be decoded.",
            "The diagnostics support stores could not be created.",
            "The fee draft is stale or contains a fee that belongs to another trip.",
            "The local mileage data is not available for a recovery copy.",
            "The mileage rate no longer exists.",
            "The original trips for this merged trip are unavailable.",
            "The PDF renderer could not create a document.",
            "The PDF renderer produced an empty document.",
            "The PDF renderer produced an invalid document.",
            "The recovery copy could not be created.",
            "The route data is malformed.",
            "The suggested car connection no longer matches this device.",
            "The trip end time must be after the start time.",
            "The bulk trip request contains duplicate trip identifiers.",
            "Trip not found.",
            "Vehicle not found."
        ]

        // `swift test` copies the source catalog into Bundle.module, while an
        // Xcode app build compiles it into per-language .lproj directories.
        // Validate whichever representation the active build system ships.
        if let catalogURL = resourceBundle.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
            let catalog = try XCTUnwrap(object as? [String: Any])
            let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

            for language in ["de", "es", "fr"] {
                for key in keys {
                    let entry = try XCTUnwrap(strings[key] as? [String: Any])
                    let localizations = try XCTUnwrap(
                        entry["localizations"] as? [String: Any]
                    )
                    let localization = try XCTUnwrap(
                        localizations[language] as? [String: Any]
                    )
                    let unit = try XCTUnwrap(
                        localization["stringUnit"] as? [String: Any]
                    )
                    XCTAssertEqual(unit["state"] as? String, "translated")
                    XCTAssertNotEqual(
                        unit["value"] as? String,
                        key,
                        "\(language) falls back to English for \(key)"
                    )
                }
            }
            return
        }

        for language in ["de", "es", "fr"] {
            let path = try XCTUnwrap(
                resourceBundle.path(forResource: language, ofType: "lproj"),
                "Missing \(language).lproj in the AppCore resource bundle"
            )
            let localizedBundle = try XCTUnwrap(Bundle(path: path))

            for key in keys {
                let translated = localizedBundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: "Localizable"
                )
                XCTAssertNotEqual(
                    translated,
                    key,
                    "\(language) falls back to English for \(key)"
                )
            }
        }
    }

    func testMileageRateScheduleErrorsResolveFromAppCoreResources() {
        XCTAssertEqual(
            MileageRateScheduleError.duplicateEffectiveDate.errorDescription,
            "Only one mileage rate can begin on the same date."
        )
        XCTAssertEqual(
            MileageRateScheduleError.invalidEffectiveDate.errorDescription,
            "Choose a valid effective date."
        )
        XCTAssertEqual(
            MileageRateScheduleError.ruleNotFound.errorDescription,
            "The mileage rate no longer exists."
        )
    }

    func testCommonStoreAndReportErrorsResolveFromAppCoreResources() {
        XCTAssertEqual(TripStoreError.tripNotFound.errorDescription, "Trip not found.")
        XCTAssertEqual(
            TripStoreError.invalidDateRange.errorDescription,
            "The trip end time must be after the start time."
        )
        XCTAssertEqual(VehicleStoreError.vehicleNotFound.errorDescription, "Vehicle not found.")
        XCTAssertEqual(
            VehicleStoreError.invalidName.errorDescription,
            "A vehicle name can't be empty."
        )
        XCTAssertEqual(
            ReportRenderingError.unableToCreatePDFContext.errorDescription,
            "The PDF renderer could not create a document."
        )
        XCTAssertEqual(
            ReportRenderingError.emptyPDF.errorDescription,
            "The PDF renderer produced an empty document."
        )
        XCTAssertEqual(
            ReportRenderingError.invalidPDF.errorDescription,
            "The PDF renderer produced an invalid document."
        )
    }
}
