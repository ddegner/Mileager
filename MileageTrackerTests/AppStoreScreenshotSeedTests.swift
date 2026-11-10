import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// Guards the committed screenshot seed catalog: a bad regeneration by
/// scripts/generate_screenshot_routes.py should fail here in validate.sh, not
/// at capture time.
final class AppStoreScreenshotSeedTests: XCTestCase {
    /// Locales with populated seed sets. Grows as localized screenshot sets
    /// are produced (target: en-US, es-ES, es-MX, fr-FR, fr-CA, de-DE).
    private static let populatedLocales = ["en-US", "es-ES", "es-MX", "fr-FR", "fr-CA", "de-DE"]

    func testEveryPopulatedLocaleDecodesWithValidTrips() throws {
        for locale in Self.populatedLocales {
            let seed = try AppStoreScreenshotSeedCatalog.seed(for: locale)

            XCTAssertEqual(seed.trips.count, 25, "\(locale): expected the standard 25-trip skeleton")
            XCTAssertFalse(seed.businessPurposePresets.isEmpty, locale)
            XCTAssertGreaterThan(seed.mileageRate.amountPerUnit, 0, locale)
            // Dropped once by a generator that stopped emitting it, which
            // silently prices every non-US capture in dollars.
            XCTAssertNotNil(seed.currencyCode, "\(locale): capture needs a pinned currency")

            let unclassified = seed.trips.filter { $0.classification == nil }
            XCTAssertEqual(unclassified.count, 7, "\(locale): the Need Review queue on card 1")
            XCTAssertEqual(
                unclassified.compactMap(\.suggestion).count, 7,
                "\(locale): every queued drive carries an AI-suggestion fixture"
            )
            XCTAssertTrue(
                unclassified.contains { $0.suggestion?.classification == .personal },
                "\(locale): one personal suggestion, so card 1 shows a red preview line"
            )

            // The capture photographs the newest month's queue on card 1 and
            // the month *below* it on card 2, so that second month has to be
            // fully classified — otherwise the headline total silently omits
            // whatever is still unreviewed.
            let months = Set(seed.trips.map(\.month)).sorted(by: >)
            XCTAssertGreaterThan(months.count, 1, "\(locale): card 2 needs a closed month")
            XCTAssertTrue(
                unclassified.allSatisfy { $0.month == months[0] },
                "\(locale): the review queue belongs to the newest month only"
            )
            let closedMonth = seed.trips.filter { $0.month == months[1] }
            XCTAssertTrue(
                closedMonth.allSatisfy { $0.classification != nil },
                "\(locale): card 2's month must be fully classified"
            )
            XCTAssertGreaterThanOrEqual(
                closedMonth.filter { $0.classification == .business }.count, 5,
                "\(locale): card 2 needs enough business drives to read as a working month"
            )

            for trip in seed.trips {
                let coordinates = EncodedPolyline.decode(trip.encodedRoute) ?? []
                XCTAssertGreaterThanOrEqual(
                    coordinates.count, 2,
                    "\(locale): route must decode to a drawable polyline (\(trip.origin) → \(trip.destination))"
                )
                XCTAssertGreaterThan(trip.distanceMeters, 0, locale)
                XCTAssertGreaterThan(trip.durationMinutes, 0, locale)
                XCTAssertFalse(trip.origin.isEmpty, locale)
                XCTAssertFalse(trip.destination.isEmpty, locale)
            }
        }
    }

    func testUnknownLocaleThrows() {
        XCTAssertThrowsError(try AppStoreScreenshotSeedCatalog.seed(for: "xx-XX"))
    }
}
