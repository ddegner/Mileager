import XCTest
@testable import MileageTracker

final class LocalizationBundleTests: XCTestCase {
    /// The shipped bundle must contain all four localizations, otherwise the
    /// per-app language setting won't appear and translations silently no-op.
    func testBundleContainsAllShippedLocalizations() {
        let localizations = Set(Bundle.main.localizations)
        for expected in ["en", "es", "fr", "de"] {
            XCTAssertTrue(
                localizations.contains(expected),
                "Missing \(expected) in Bundle.main.localizations: \(localizations)"
            )
        }
    }

    func testMailRedesignStringsAreTranslatedInEveryShippedLanguage() throws {
        let keys = [
            "Drive",
            "Mark ${drive} as ${classification}",
            "Suggested: %@",
            "Suggested: %@, %@",
            "Trips and files you already exported are not affected. Reports can be generated again from Months.",
            "Delete selected trip?",
            "Delete selected trips?",
            "Delete %lld Trips",
            "This permanently deletes the selected trip. This can't be undone.",
            "This permanently deletes %lld selected trips. This can't be undone.",
            "This permanently deletes your %@ trip. This can't be undone.",
            "Classify Most Recent Trip",
            "Set ${drive} purpose to ${purpose}",
            "Finding route...",
            "Map added from your origin and destination. Add the distance manually.",
            "Couldn't find a route. Check the addresses and your connection.",
            "Marked automatically - this route was mostly over water.",
            "Marked automatically - this looked like a subway or train ride.",
            "Marked automatically - this trip was shorter than 0.2 mi.",
            "End time must be after start time.",
            "Enter a valid distance.",
            "Not Classified",
            "Automatic tracking uses Motion & Fitness to recognize driving and Location to record distance. Bluetooth can improve trip starts, and Notifications can remind you to review trips. Manual entry and exports work without granting these permissions.",
            "Not Determined",
            "Requesting",
            "Authorized",
            "Partial",
            "Denied",
            "Restricted",
            "Unavailable",
            "Unlock with Face ID",
            "Unlock with Touch ID",
            "Unlock",
            "New purpose",
            "There are no trips to export.",
            "The report could not be generated.",
            "Legal documents are currently provided in English.",
            "Save Fee",
            "Set",
            "Today",
            "Vacation",
            "Sample data can only be loaded when there are no trips.",
            "Drive self-test running",
            "Drive self-test complete: %.1f mi",
            "Drive self-test failed: %@",
            "From",
            "To"
        ]

        for language in ["de", "es", "fr"] {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "Missing \(language).lproj"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let translated = bundle.localizedString(
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

    func testLocalizedInfoPlistReleaseStringsAreTranslated() throws {
        let keys = [
            "CFBundleSpokenName",
            "NSCalendarsFullAccessUsageDescription",
            "NSContactsUsageDescription"
        ]

        for language in ["de", "es", "fr"] {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "Missing \(language).lproj"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let translated = bundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: "InfoPlist"
                )
                XCTAssertNotEqual(
                    translated,
                    key,
                    "\(language) falls back to the InfoPlist key for \(key)"
                )
            }
        }
    }
}
