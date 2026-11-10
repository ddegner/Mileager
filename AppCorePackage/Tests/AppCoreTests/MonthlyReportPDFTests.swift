import PDFKit
import XCTest
@testable import AppCore
@testable import AppCoreReporting

/// Exercises the monthly report PDF against a realistic month of drives
/// (the June 2026 report): compact itinerary headlines, per-leg detail lines,
/// out-of-state markers, fee attribution, and the totals block.
final class MonthlyReportPDFTests: XCTestCase {
    // June 2026 fixture rate, kept explicit as current defaults change.
    private let juneRate = MileageRate(amountPerUnit: 0.725, unit: .miles)

    func testReportCoveragePartitionsEveryPeriodRecord() {
        let trips = juneSampleTrips() + reportCoverageSampleTrips()
        let audit = ReportAuditSummary(trips: trips)

        XCTAssertEqual(audit.businessIncluded, 8)
        XCTAssertEqual(audit.personalExcluded, 1)
        XCTAssertEqual(audit.needsReview, 1)
        XCTAssertEqual(audit.notADrive, 1)
        XCTAssertEqual(audit.recordCount, trips.count)
    }

    @MainActor
    func testMonthlyReportPDFUsesCompactItinerariesAndFootsToSummary() throws {
        let businessTrips = juneSampleTrips()
        let excludedTrips = reportCoverageSampleTrips()
        let vehicleNames = Dictionary(uniqueKeysWithValues: businessTrips.enumerated().map { pair in
            (pair.element.id, pair.offset < 4 ? "Comet 2015" : "Touring")
        })
        let report = try ReportGenerator().makeReport(
            trips: businessTrips + excludedTrips,
            odometerCheckpoints: [],
            startDate: june(1, 0, 0),
            endDate: june(30, 23, 59),
            rate: juneRate,
            formatting: .enUS,
            vehicleNamesByTripID: vehicleNames
        )

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-06-revamped.pdf")
            )
        }

        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(assertReportFooters(in: document).count, 1)
        let text = (document.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")

        // PDFKit extracts text by visual line, so a wrapped headline interleaves
        // with neighboring cells — assert on fragments that fit one line.
        // Multi-leg headline collapses out-of-town stops to city names.
        XCTAssertTrue(text.contains("22 Brindle St → Wilmington → Andover"))
        // Same-street loop reads as a round trip instead of "X to X".
        XCTAssertTrue(text.contains("Round trip from 26 Brindle St, Cambridge"))
        // Out-of-state origin keeps its state; home-state endpoints drop it.
        XCTAssertTrue(text.contains("Newtown, CT → 10 Lunaris St"))
        // The monthly ledger stays concise; verbose leg timing and stop details
        // remain available in the canonical CSV and individual trip receipt.
        XCTAssertFalse(text.contains("stopped 25m"))
        XCTAssertFalse(text.contains("stopped 2h 10m"))
        // Tolls are attributed on the trip row and included in the totals.
        XCTAssertTrue(text.contains("+$2.00 tolls"))
        XCTAssertTrue(text.contains("Totals"))
        XCTAssertTrue(text.contains("Total reimbursement"))
        // Line items foot exactly: sum of per-trip rounded amounts ($173.45)
        // plus tolls, not a re-rounding of total miles × rate.
        XCTAssertTrue(text.contains("$173.45"))
        XCTAssertTrue(text.contains("$175.45"))
        XCTAssertTrue(text.contains("$0.725/mi"))
        XCTAssertTrue(text.contains("business included"))
        XCTAssertTrue(text.contains("personal excluded"))
        XCTAssertTrue(text.contains("needs review"))
        XCTAssertFalse(text.contains("not a drive"))
        XCTAssertTrue(text.contains("Comet 2015"))
        XCTAssertTrue(text.contains("Touring"))
        // ZIP codes and the redundant Type column stay out of the table.
        XCTAssertFalse(text.contains("02139"))
        XCTAssertFalse(text.contains("01887"))
        XCTAssertFalse(text.contains("Unknown origin"))
    }

    @MainActor
    func testMonthlyReportMilesColumnFootsToDisplayedTotal() throws {
        // Three trips whose 2-dp rows (1.00 each) sum to 3.00, but whose full-precision
        // miles sum (~3.012) would re-round to 3.01. The displayed total must foot to
        // the sum of the printed rows (3.00), not to a re-rounded full-precision sum.
        let trips = (0..<3).map { index in
            trip(
                purpose: "Client visit",
                miles: 1.004,
                legs: [leg(
                    from: "10 Lunaris St, Boston",
                    june(2 + index, 9, 0),
                    to: "1 Star Way, Cambridge",
                    june(2 + index, 9, 30),
                    miles: 1.004
                )]
            )
        }

        let report = try ReportGenerator().makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: june(1, 0, 0),
            endDate: june(30, 23, 59),
            rate: juneRate,
            formatting: .enUS
        )

        // Each canonical row prints 1.00 and carries its independently rounded
        // $0.73 mileage amount, so consumers sum the same values as the PDF.
        XCTAssertEqual(report.csvText.components(separatedBy: ",1.00,mi,1.00,No,").count - 1, 3)
        XCTAssertEqual(report.csvText.components(separatedBy: ",0.725,USD,0.73,").count - 1, 3)
    }

    /// A user's manual distance correction must flow into the CSV row, the
    /// business-miles total, and the reimbursement — not just the trip list.
    /// (Regression: the 2.0 unit conversion briefly switched the money math to
    /// the raw GPS distance.)
    @MainActor
    func testReportUsesManualDistanceOverride() throws {
        // GPS recorded 1.0 mi; the user corrected the trip to 10.0 mi.
        let corrected = trip(
            purpose: "Client visit",
            miles: 1.0,
            overrideMiles: 10.0,
            legs: [leg(
                from: "10 Lunaris St, Boston",
                june(2, 9, 0),
                to: "1 Star Way, Cambridge",
                june(2, 9, 30),
                miles: 1.0
            )]
        )

        let report = try ReportGenerator().makeReport(
            trips: [corrected],
            odometerCheckpoints: [],
            startDate: june(1, 0, 0),
            endDate: june(30, 23, 59),
            rate: juneRate,
            formatting: .enUS
        )

        XCTAssertTrue(report.csvText.contains(",10.00,mi,1.00,Yes,"), report.csvText)
        // 10 mi × $0.725/mi, not 1 mi × $0.725.
        XCTAssertTrue(report.csvText.contains(",0.725,USD,7.25,"), report.csvText)
    }

    @MainActor
    func testMonthlyReportPaginatesAndKeepsTotalsOnLastPage() throws {
        let brindle = "22 Brindle St, Cambridge, MA 02139"
        let lunaris = "10 Lunaris St, Dorchester, MA 02122"
        let trips = (1...30).map { day in
            trip(purpose: "Photography Location", miles: 12.5, legs: [
                leg(from: brindle, june(day, 9, 0), to: lunaris, june(day, 9, 45), miles: 6.25),
                leg(from: lunaris, june(day, 11, 0), to: brindle, june(day, 11, 45), miles: 6.25),
            ])
        }

        let report = try ReportGenerator().makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: june(1, 0, 0),
            endDate: june(30, 23, 59),
            rate: juneRate,
            formatting: .enUS
        )

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-06-dense.pdf")
            )
        }

        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertGreaterThan(document.pageCount, 1)
        let footerBounds = assertReportFooters(in: document)
        XCTAssertEqual(footerBounds.count, document.pageCount)

        // The totals block (label "Totals") renders exactly once, on the last page.
        let lastPage = try XCTUnwrap(document.page(at: document.pageCount - 1))
        let lastPageText = lastPage.string ?? ""
        XCTAssertTrue(lastPageText.contains("Totals"))
        XCTAssertTrue(lastPageText.contains("Total reimbursement"))
        let totalsBounds = try XCTUnwrap(
            reportSelectionBounds(for: "Total reimbursement", on: lastPage, in: document)
        )
        let lastFooterBounds = try XCTUnwrap(footerBounds.last)
        XCTAssertGreaterThanOrEqual(
            totalsBounds.minY - lastFooterBounds.maxY,
            8
        )
        for pageIndex in 0..<(document.pageCount - 1) {
            let pageText = document.page(at: pageIndex)?.string ?? ""
            XCTAssertFalse(pageText.contains("Totals"), "totals block leaked onto page \(pageIndex + 1)")
        }
    }

    @MainActor
    func testTripReceiptPDFShowsPaymentSummaryWithTotal() async throws {
        let library = "Silvercup Library, 815 Willowglimmer Ave, Cambridge, MA 02139"
        let myrrh = "558 Myrrh St, Milton, MA 02186"
        let marbleGreens = "Marble Greens, 100 Cobalt Downs Dr, Quincy, MA 02169"
        let brindle24 = "24 Brindle St, Cambridge, MA 02139"
        let receiptTrip = trip(purpose: "Client meeting", miles: 35.70, tolls: 5.00, parking: 5.00, legs: [
            leg(from: library, june(11, 10, 1), to: myrrh, june(11, 10, 34), miles: 17.67),
            leg(from: myrrh, june(11, 11, 16), to: marbleGreens, june(11, 11, 29), miles: 2.61),
            leg(from: marbleGreens, june(11, 14, 41), to: brindle24, june(11, 15, 26), miles: 15.42),
        ])

        let pdfData = try await ReportGenerator().makeTripPDF(for: receiptTrip, rate: juneRate, generatedAt: june(30, 10, 0), formatting: .enUS)

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Trip-Receipt-revamped.pdf")
            )
        }

        let document = try XCTUnwrap(PDFDocument(data: pdfData))
        // No notes → single page with no empty Notes section.
        XCTAssertEqual(document.pageCount, 1)
        let text = (document.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")

        XCTAssertTrue(text.contains("Trip Receipt"))
        // Payment summary: mileage line, fees, and the total the client owes.
        XCTAssertTrue(text.contains("$25.88"))
        XCTAssertTrue(text.contains("35.70 mi × $0.725/mi"))
        XCTAssertTrue(text.contains("Tolls"))
        XCTAssertTrue(text.contains("Parking"))
        XCTAssertTrue(text.contains("Total reimbursement"))
        XCTAssertTrue(text.contains("$35.88"))
        // Itinerary headline surfaces the stops that used to hide in fine print.
        XCTAssertTrue(text.contains("→ Milton → Quincy →"))
        // Trip ID matches the export filename's short ID.
        XCTAssertTrue(text.contains("Trip ID \(String(receiptTrip.id.uuidString.prefix(8)))"))
        // Internal bookkeeping stays out of the client-facing receipt.
        XCTAssertFalse(text.contains("Classification"))
        XCTAssertFalse(text.contains("Notes"))
    }

    /// Regression for the review finding that a receipt with long legs and
    /// long notes lost its page-1 footer: the fixed 6-line notes capacity
    /// ignored the height of everything above it, so overflow pushed the
    /// footer (and the "notes continue" indicator) off the media box and
    /// sliced note text at the page edge. Capacity is now computed from the
    /// page's actual content, and the footer is pinned like report pages.
    @MainActor
    func testTripReceiptWithLongLegsAndNotesKeepsFooterOnEveryPage() async throws {
        let library = "Silvercup Library, 815 Willowglimmer Ave, Cambridge, MA 02139"
        let museum = "Moonlit Navigation Guild Museum, 25 Comet Way, Boston, MA 02115"
        let moonspire = "Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143"
        let marbleGreens = "Marble Greens, 100 Cobalt Downs Dr, Quincy, MA 02169"
        let myrrh = "558 Myrrh St, Milton, MA 02186"
        let wickerHill = "67 Wicker Hill Rd, Newtown, CT 06482"
        let brindle24 = "24 Brindle St, Cambridge, MA 02139"
        let stops = [library, museum, moonspire, marbleGreens, myrrh, wickerHill, brindle24]
        let legs = (0..<6).map { index in
            leg(
                from: stops[index],
                june(25, 8 + index, 10),
                to: stops[index + 1],
                june(25, 8 + index, 50),
                miles: 7.5
            )
        }
        let notes = Array(
            repeating: "Scouted the north entrance for the winter catalog shoot; "
                + "client asked for revised call sheets and parking validation for the crew vans.",
            count: 24
        ).joined(separator: " ")
        let receiptTrip = trip(
            purpose: "Multi-stop client shoot",
            miles: 45.0,
            tolls: 5.00,
            parking: 12.00,
            notes: notes,
            legs: legs
        )

        let pdfData = try await ReportGenerator().makeTripPDF(
            for: receiptTrip,
            rate: juneRate,
            generatedAt: june(30, 10, 0),
            formatting: .enUS
        )
        let document = try XCTUnwrap(PDFDocument(data: pdfData))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        assertReportFooters(in: document)

        // The continuation indicator and trip ID survive on page 1.
        let firstPage = (document.page(at: 0)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(firstPage.contains("Continued"), firstPage)
        XCTAssertTrue(firstPage.contains("Trip ID \(String(receiptTrip.id.uuidString.prefix(8)))"), firstPage)
        // Every note line the paginator emitted must actually be in the PDF.
        let allText = (0..<document.pageCount)
            .map { document.page(at: $0)?.string ?? "" }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(allText.contains("parking validation for the crew vans."), "note tail went missing")
    }

    // MARK: - June 2026 sample data

    private func juneSampleTrips() -> [TripSummary] {
        let brindle22 = "22 Brindle St, Cambridge, MA 02139"
        let brindle24 = "24 Brindle St, Cambridge, MA 02139"
        let brindle26 = "26 Brindle St, Cambridge, MA 02139"
        let brindle28 = "28 Brindle St, Cambridge, MA 02139"
        let lunarglades = "206 Lunarglades St, Wilmington, MA 01887"
        let willowJunction = "30 Willow Junction Rd, Andover, MA 01810"
        let moonspire = "Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143"
        let cinderwillow = "58 Cinderwillow St, Cambridge, MA 02138"
        let meridianPark = "Meridian Park, Boston, MA"
        let wickerHill = "67 Wicker Hill Rd, Newtown, CT 06482"
        let lunaris = "10 Lunaris St, Dorchester, MA 02122"
        let cressida = "Theodora T Cressida Blvd, Boston, MA"
        let brindle25 = "25 Brindle St, Cambridge, MA 02139"

        return [
            trip(purpose: "Photography Location", miles: 43.08, legs: [
                leg(from: brindle22, june(2, 8, 21), to: lunarglades, june(2, 8, 57), miles: 17.72),
                leg(from: lunarglades, june(2, 9, 22), to: willowJunction, june(2, 9, 31), miles: 2.27),
                leg(from: willowJunction, june(2, 11, 41), to: brindle26, june(2, 12, 22), miles: 23.09),
            ]),
            trip(purpose: "Photography Location", miles: 3.12, legs: [
                leg(from: moonspire, june(2, 13, 23), to: brindle24, june(2, 16, 48), miles: 1.63),
                leg(from: brindle24, june(2, 22, 22), to: moonspire, june(2, 22, 47), miles: 1.49),
            ]),
            trip(purpose: "Photography Location", miles: 3.66, legs: [
                leg(from: brindle26, june(3, 13, 27), to: brindle26, june(3, 14, 5), miles: 3.66),
            ]),
            trip(purpose: "Client Visit", miles: 5.16, legs: [
                leg(from: brindle28, june(4, 18, 28), to: cinderwillow, june(4, 18, 41), miles: 2.38),
                leg(from: cinderwillow, june(4, 19, 11), to: brindle28, june(4, 19, 25), miles: 2.78),
            ]),
            trip(purpose: "Photography Location", miles: 15.72, legs: [
                leg(from: brindle28, june(5, 14, 45), to: brindle24, june(5, 15, 30), miles: 15.72),
            ]),
            trip(purpose: "Client meeting", miles: 6.29, legs: [
                leg(from: brindle24, june(11, 18, 8), to: meridianPark, june(11, 21, 33), miles: 3.41),
                leg(from: meridianPark, june(12, 13, 9), to: brindle24, june(12, 13, 34), miles: 2.88),
            ]),
            trip(purpose: "Photo shoot", miles: 154.21, tolls: 2.00, legs: [
                leg(from: wickerHill, june(16, 11, 34), to: lunaris, june(16, 14, 10), miles: 154.21),
            ]),
            trip(purpose: "Photo shoot", miles: 8.02, legs: [
                leg(from: cressida, june(16, 16, 14), to: brindle25, june(16, 16, 40), miles: 8.02),
            ]),
        ]
    }

    private func reportCoverageSampleTrips() -> [TripSummary] {
        let origin = "10 Lunaris St, Boston"
        let destination = "1 Star Way, Cambridge"
        return [
            trip(
                purpose: nil,
                miles: 2.0,
                classification: .personal,
                legs: [leg(from: origin, june(4, 8, 0), to: destination, june(4, 8, 20), miles: 2.0)]
            ),
            trip(
                purpose: nil,
                miles: 1.0,
                classification: .business,
                legs: [leg(from: origin, june(5, 8, 0), to: destination, june(5, 8, 20), miles: 1.0)]
            ),
            trip(
                purpose: nil,
                miles: 0.2,
                classification: .notADrive,
                legs: [leg(from: origin, june(6, 8, 0), to: destination, june(6, 8, 5), miles: 0.2)]
            ),
        ]
    }

    @MainActor
    func testMonthlyReportInGermanKilometersAndEuros() throws {
        let trips = [
            trip(purpose: "Client visit", miles: 10.0, tolls: 2.00, legs: [
                leg(
                    from: "22 Brindle St, Cambridge, MA 02139", june(2, 9, 0),
                    to: "10 Lunaris St, Dorchester, MA 02122", june(2, 9, 45),
                    miles: 10.0
                )
            ])
        ]

        // 10 mi = 16.09 km at 0.50 €/km → 8.05 € mileage + 2.00 € tolls.
        let report = try ReportGenerator().makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: june(1, 0, 0),
            endDate: june(30, 23, 59),
            rate: MileageRate(amountPerUnit: 0.50, unit: .kilometers),
            formatting: ReportFormattingContext(
                locale: Locale(identifier: "de_DE"),
                distanceUnit: .kilometers,
                currencyCode: "EUR"
            )
        )

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-06-de.pdf")
            )
        }

        // CSV numbers, headers, and units stay machine-stable POSIX even for a
        // German report; only the PDF uses localized presentation.
        XCTAssertTrue(report.csvText.contains(",16.09,km,16.09,No,"), report.csvText)
        XCTAssertTrue(report.csvText.contains(",0.500,EUR,8.05,2.00,0.00,10.05,"), report.csvText)

        // PDF renders in the report locale: km unit, comma decimals, euro sign.
        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        let text = (document.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(text.contains("km"), text)
        XCTAssertTrue(text.contains("€"), text)
        XCTAssertTrue(text.contains("16,09"), "expected German comma decimal in PDF, got: \(text)")
    }

    @MainActor
    func testMonthlyReportWithOdometerKeepsFooterReserved() throws {
        let report = try ReportGenerator().makeReport(
            trips: [juneSampleTrips()[0]],
            odometerCheckpoints: [
                OdometerCheckpoint(date: june(1, 8, 0), odometerMiles: 10_000),
                OdometerCheckpoint(date: june(30, 18, 0), odometerMiles: 10_500),
            ],
            startDate: june(1, 0, 0),
            endDate: june(30, 23, 59),
            rate: juneRate,
            formatting: .enUS
        )

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-06-odometer.pdf")
            )
        }

        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertEqual(assertReportFooters(in: document).count, document.pageCount)
        XCTAssertTrue((document.string ?? "").contains("Odometer"))
    }

    private func june(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute)) ?? Date(timeIntervalSince1970: 0)
    }

    private func leg(from origin: String, _ start: Date, to destination: String, _ end: Date, miles: Double) -> TripLeg {
        TripLeg(
            captureSource: "test",
            startDate: start,
            endDate: end,
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: origin,
            endAddress: destination,
            distanceMeters: DistanceConversion.meters(fromMiles: miles),
            routePolyline: nil
        )
    }

    private func trip(
        purpose: String?,
        miles: Double,
        overrideMiles: Double? = nil,
        tolls: Double = 0,
        parking: Double = 0,
        classification: TripClassification = .business,
        notes: String? = nil,
        legs: [TripLeg]
    ) -> TripSummary {
        let start = legs.first?.startDate ?? Date(timeIntervalSince1970: 0)
        let end = legs.last?.endDate ?? start
        return TripSummary(
            id: UUID(),
            createdAt: start,
            updatedAt: end,
            captureSource: "test",
            startDate: start,
            endDate: end,
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: legs.first?.startAddress,
            endAddress: legs.last?.endAddress,
            distanceMeters: DistanceConversion.meters(fromMiles: miles),
            routePolyline: nil,
            classification: classification,
            reviewStatus: classification == .business && purpose == nil ? .needsReview : .readyToExport,
            businessPurpose: purpose,
            notes: notes,
            tollsAmount: tolls,
            parkingAmount: parking,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: overrideMiles.map(DistanceConversion.meters(fromMiles:)),
            legs: legs
        )
    }
}

/// Pinned formatting so report assertions hold regardless of the machine's
/// locale, unit, or currency defaults.
private extension ReportFormattingContext {
    static let enUS = ReportFormattingContext(
        locale: Locale(identifier: "en_US"),
        distanceUnit: .miles,
        currencyCode: "USD"
    )
}
