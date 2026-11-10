#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import AppCore

/// Exports the three report artifacts that card 04 of the v2 App Store
/// screenshot set photographs: a per-drive receipt, a monthly report, and an
/// annual report.
///
/// The drives come from the committed App Store screenshot seed
/// (`MileageTracker/Resources/ScreenshotSeeds/AppStoreScreenshotSeeds.json`) —
/// the same real Columbus endpoints, distances, routes and fees the simulator
/// captures use — but replayed across a full year by `workingYear(from:)`.
///
/// The seed is sized to fill a phone screen, not a report: on its own it yields
/// a one-third-empty monthly page and an annual document with a single short
/// table. A year of a working photographer's driving fills both, and its total
/// is what makes card 03's "thousands in potential reimbursements each year"
/// a claim the artifact beside it actually supports.
///
/// Skipped unless explicitly requested, because it writes into the working
/// tree and renders SwiftUI:
///
///     MILEAGE_EXPORT_REPORT_ARTIFACTS=1 swift test \
///         --package-path AppCorePackage \
///         --filter AppStoreReportArtifactExporterTests
final class AppStoreReportArtifactExporterTests: XCTestCase {
    private static let seedYear = 2026

    @MainActor
    func testExportReportArtifacts() async throws {
        guard ProcessInfo.processInfo.environment["MILEAGE_EXPORT_REPORT_ARTIFACTS"] == "1" else {
            throw XCTSkip("Set MILEAGE_EXPORT_REPORT_ARTIFACTS=1 to regenerate App Store report artifacts.")
        }

        let repo = Self.repositoryRoot()
        let requested = ProcessInfo.processInfo.environment["MILEAGE_REPORT_LOCALES"]
        let locales = requested?.split(separator: ",").map(String.init)
            ?? ["en-US", "es-ES", "es-MX", "fr-FR", "fr-CA", "de-DE"]
        for locale in locales {
            try await exportArtifacts(locale: locale, repo: repo)
        }
    }

    /// Every locale gets its own reports: the seed carries that market's real
    /// city, mileage rate, currency and distance unit, so a German card must
    /// photograph a kilometre-and-euro report, not a translated-looking crop of
    /// an American one.
    @MainActor
    private func exportArtifacts(locale: String, repo: URL) async throws {
        let seed = try Self.loadSeed(repo: repo, locale: locale)
        let trips = Self.workingYear(from: seed.trips)
        XCTAssertFalse(trips.isEmpty, "\(locale): seed produced no trips")

        let outputDirectory = repo
            .appending(path: "app-store-assets/screenshots/cards-v2/assets/reports")
            .appending(path: locale)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let generator = ReportGenerator()
        let rate = seed.mileageRate.rate
        let formatting = ReportFormattingContext(
            distanceUnit: rate.unit,
            currencyCode: seed.currencyCode
        )

        // Per drive: the longest business drive in the set, so the receipt has
        // a real route and a number worth printing.
        let receiptTrip = try XCTUnwrap(
            trips.filter { $0.classification == .business }.max { $0.distanceMeters < $1.distanceMeters }
        )
        let receipt = try await generator.makeTripPDF(
            for: receiptTrip,
            rate: rate,
            generatedAt: Self.date(month: 7, day: 1, hour: 9, minute: 0),
            formatting: formatting
        )
        let receiptPages = try Self.write(pdf: receipt, named: "per-drive", to: outputDirectory, maxPages: 1)

        // Monthly: May, the month card 03 photographs.
        let monthly = try generator.makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: Self.date(month: 5, day: 1, hour: 0, minute: 0),
            endDate: Self.date(month: 5, day: 31, hour: 23, minute: 59),
            rate: rate,
            formatting: formatting,
            calendar: Self.calendar
        )
        let monthlyPages = try Self.write(pdf: monthly.pdfData, named: "monthly", to: outputDirectory)

        // Annual: the whole seeded year.
        let annual = try generator.makeAnnualReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: Self.date(month: 1, day: 1, hour: 0, minute: 0),
            endDate: Self.date(month: 12, day: 31, hour: 23, minute: 59),
            rate: rate,
            formatting: formatting,
            calendar: Self.calendar
        )
        let annualPages = try Self.write(pdf: annual.pdfData, named: "annual", to: outputDirectory)

        print("""
        \(locale): per-drive \(receiptPages)p, monthly \(monthlyPages)p, annual \(annualPages)p \
        — year \(Int(annual.businessMiles.rounded())) \(rate.unit == .miles ? "mi" : "km"), \
        \(seed.currencyCode) \(annual.businessValue)
        """)
    }

    // MARK: - Output

    /// Writes the PDF plus a rasterised render of each page, up to `maxPages`.
    ///
    /// Card 04 stacks the pages so the sheets read as real multi-page
    /// documents, so a monthly or annual report needs page 2 and 3 on disk as
    /// well as its cover. The card shows a sheet at 624 device pixels wide, so
    /// 1200 leaves headroom.
    @discardableResult
    private static func write(
        pdf data: Data,
        named name: String,
        to directory: URL,
        maxPages: Int = 3
    ) throws -> Int {
        try data.write(to: directory.appending(path: "\(name).pdf"))

        let document = try XCTUnwrap(PDFDocument(data: data), "\(name): unreadable PDF")
        XCTAssertGreaterThan(document.pageCount, 0, "\(name): no pages")

        for index in 0..<min(document.pageCount, maxPages) {
            let page = try XCTUnwrap(document.page(at: index), "\(name): no page \(index + 1)")
            let bounds = page.bounds(for: .mediaBox)
            let width: CGFloat = 1200
            let size = NSSize(width: width, height: (width / bounds.width * bounds.height).rounded())

            let image = page.thumbnail(of: size, for: .mediaBox)
            let tiff = try XCTUnwrap(image.tiffRepresentation, "\(name): no bitmap")
            let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff), "\(name): no bitmap rep")
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "\(name): no PNG")
            try png.write(to: directory.appending(path: "\(name)-p\(index + 1).png"))
        }
        return document.pageCount
    }

    // MARK: - Seed

    private struct Seed: Decodable {
        let mileageRate: SeedRate
        let currencyCode: String
        let trips: [SeedTrip]
    }

    private struct SeedRate: Decodable {
        let amountPerUnit: Double
        let unit: String

        var rate: MileageRate {
            MileageRate(amountPerUnit: amountPerUnit, unit: unit == "kilometers" ? .kilometers : .miles)
        }
    }

    private struct SeedTrip: Decodable {
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let durationMinutes: Int
        let distanceMeters: Double
        let origin: String
        let destination: String
        let classification: String?
        let businessPurpose: String?
        let notes: String?
        let tolls: Double?
        let parking: Double?
        let encodedRoute: String?
    }

    private static func loadSeed(repo: URL, locale: String) throws -> Seed {
        let url = repo.appending(path: "MileageTracker/Resources/ScreenshotSeeds/AppStoreScreenshotSeeds.json")
        let all = try JSONDecoder().decode([String: Seed].self, from: Data(contentsOf: url))
        return try XCTUnwrap(all[locale], "seed has no locale \(locale)")
    }

    /// A fictional working photographer's year, built from the screenshot seed.
    ///
    /// The seed holds one showcase month plus a little history — enough to fill
    /// a phone screen, nowhere near enough to fill a report. Reports shown on
    /// card 04 have to look like a year of actual work: a monthly page with a
    /// full table on it, and an annual document that runs to several pages.
    /// So each of the seed's business drives is replayed twice a month across
    /// the whole year, on distinct days, keeping its real endpoints, distance,
    /// route and fees.
    private static func workingYear(from seeds: [SeedTrip]) -> [TripSummary] {
        let business = seeds.filter { $0.classification == "business" }
        guard !business.isEmpty else { return seeds.map { tripSummary(from: $0) } }

        var trips: [TripSummary] = []
        for month in 1...12 {
            let dayCount = calendar.range(
                of: .day, in: .month,
                for: date(month: month, day: 1, hour: 0, minute: 0)
            )?.count ?? 28
            for (index, seed) in (business + business).enumerated() {
                // Spread the drives evenly through the month, skipping the 31st
                // so short months stay valid.
                let day = min(dayCount, 1 + (index * 29) / max(1, (business.count * 2) - 1))
                trips.append(tripSummary(from: seed, month: month, day: day))
            }
        }
        // Keep the seed's own unclassified and personal drives so the reports'
        // audit lines still reflect a real, mixed ledger.
        trips.append(contentsOf: seeds.filter { $0.classification != "business" }.map { tripSummary(from: $0) })
        return trips
    }

    private static func tripSummary(from seed: SeedTrip, month: Int? = nil, day: Int? = nil) -> TripSummary {
        let start = date(
            month: month ?? seed.month,
            day: day ?? seed.day,
            hour: seed.hour,
            minute: seed.minute
        )
        let end = start.addingTimeInterval(TimeInterval(seed.durationMinutes) * 60)
        let classification: TripClassification? = switch seed.classification {
        case "business": .business
        case "personal": .personal
        default: nil
        }
        return TripSummary(
            id: UUID(),
            createdAt: start,
            updatedAt: end,
            captureSource: "screenshot-seed",
            startDate: start,
            endDate: end,
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: seed.origin,
            endAddress: seed.destination,
            distanceMeters: seed.distanceMeters,
            routePolyline: seed.encodedRoute,
            classification: classification,
            reviewStatus: classification == nil ? .needsReview : .readyToExport,
            businessPurpose: seed.businessPurpose,
            notes: seed.notes,
            tollsAmount: seed.tolls ?? 0,
            parkingAmount: seed.parking ?? 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil,
            legs: [],
            connectors: [],
            startBluetoothHintHashes: [],
            // Only the auto-classifiers set a source; a user's own call leaves it nil.
            classificationSource: nil,
            vehicleID: nil,
            vehicleAssignmentSource: nil,
            startAddressEnrichmentState: .complete,
            endAddressEnrichmentState: .complete,
            routeEnrichmentState: .complete
        )
    }

    // MARK: - Calendar

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }()

    private static func date(month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: seedYear, month: month, day: day, hour: hour, minute: minute
        )) ?? Date(timeIntervalSince1970: 0)
    }

    /// .../AppCorePackage/Tests/AppCoreTests/<this file> -> repository root.
    private static func repositoryRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()   // AppCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AppCorePackage
            .deletingLastPathComponent()   // repo
    }
}
#endif
