import AppCore
import Foundation

/// Decodes the bundled App Store screenshot seed catalog
/// (`Resources/ScreenshotSeeds/AppStoreScreenshotSeeds.json`), generated and
/// committed by `scripts/generate_screenshot_routes.py`. One entry per App
/// Store locale so screenshot runs can seed locale-accurate geography,
/// currency amounts, purpose vocabulary, and mileage rate
/// (`--seed-app-store-screenshot-data --screenshot-locale=<id>`).
enum AppStoreScreenshotSeedCatalog {
    struct LocaleSeed: Decodable {
        var mileageRate: RateSeed
        /// ISO currency code the reports/fees should display in (e.g. "EUR").
        var currencyCode: String?
        var businessPurposePresets: [String]
        var trips: [TripSeed]
    }

    struct RateSeed: Decodable {
        var amountPerUnit: Double
        var unit: DistanceUnit
    }

    /// Deterministic stand-in for what the Foundation Models provider would
    /// suggest for this trip; replayed verbatim by the UI-test provider.
    struct SuggestionSeed: Decodable {
        var classification: TripClassification
        var businessPurpose: String?
        var calendarEventTitle: String
    }

    struct TripSeed: Decodable {
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var durationMinutes: Double
        var distanceMeters: Double
        var origin: String
        var destination: String
        var classification: TripClassification?
        var businessPurpose: String?
        var notes: String
        var tolls: Double
        var parking: Double
        /// Precision-5 encoded polyline of the road-following route; the
        /// trip's start/end coordinates are derived by decoding it.
        var encodedRoute: String
        var suggestion: SuggestionSeed?
    }

    enum SeedError: LocalizedError {
        case missingResource
        case unknownLocale(String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                "AppStoreScreenshotSeeds.json is missing from the app bundle"
            case let .unknownLocale(identifier):
                "AppStoreScreenshotSeeds.json has no entry for locale \(identifier)"
            }
        }
    }

    static func seed(
        for localeIdentifier: String,
        bundle: Bundle = .main
    ) throws -> LocaleSeed {
        guard let url = bundle.url(
            forResource: "AppStoreScreenshotSeeds",
            withExtension: "json"
        ) else {
            throw SeedError.missingResource
        }
        let catalog = try JSONDecoder().decode(
            [String: LocaleSeed].self,
            from: Data(contentsOf: url)
        )
        guard let seed = catalog[localeIdentifier] else {
            throw SeedError.unknownLocale(localeIdentifier)
        }
        return seed
    }
}
