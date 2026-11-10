import PDFKit
import XCTest
@testable import AppCore

/// Exercises the annual report against a year of drives: the flat canonical
/// trip ledger and, most important, the same per-trip rounding used by each
/// month's standalone report.
final class AnnualReportTests: XCTestCase {
    // Fixed reimbursement fixture; these totals do not depend on the current app default.
    private let fixtureRate = MileageRate(amountPerUnit: 0.725, unit: .miles)

    // Rate 0.725/mi throughout. Hand math:
    //  Feb: 10.00 mi ($7.25, $2 tolls) + 35.00 mi ($25.38) → 45.00 mi, $32.63
    //  Mar: 20.00 mi multi-leg ($14.50, $5 parking)        → 20.00 mi, $14.50
    //  Apr: no trips (zero line)
    //  May: 3 × 1.004 mi (rows print 1.00; $0.73 each)      →  3.00 mi,  $2.19
    //  Dec: 8.00 mi late Dec 31 ($5.80)                     →  8.00 mi,  $5.80
    //  Year: 7 trips, 76.00 mi, $55.12 + $5 parking + $2 tolls = $62.12

    @MainActor
    func testAnnualCSVUsesFlatCanonicalTripLedger() throws {
        let report = try makeAnnualReport(trips: yearSampleTrips())
        let csv = report.csvText

        XCTAssertTrue(csv.hasPrefix("Trip ID,Report Month,Start Date,Start Time,End Date,End Time,Time Zone"), csv)
        XCTAssertEqual(csv.components(separatedBy: ",2026-02,").count - 1, 2, csv)
        XCTAssertEqual(csv.components(separatedBy: ",2026-03,").count - 1, 1, csv)
        XCTAssertEqual(csv.components(separatedBy: ",2026-05,").count - 1, 3, csv)
        XCTAssertEqual(csv.components(separatedBy: ",2026-12,").count - 1, 1, csv)
        XCTAssertFalse(csv.contains(",2026-04,"), csv)
        XCTAssertTrue(csv.contains(",0.725,USD,7.25,2.00,0.00,9.25,1,0,"), csv)
        XCTAssertTrue(csv.contains(",0.725,USD,14.50,0.00,5.00,19.50,2,1,"), csv)
        XCTAssertFalse(csv.contains("Monthly summary"), csv)
        XCTAssertFalse(csv.contains("Year total"), csv)

        // Non-business trips stay out of the annual export entirely.
        XCTAssertFalse(csv.contains("999 Excluded Ave"), csv)

        XCTAssertEqual(report.includedTripIDs.count, 7)
        // Snapshot businessValue is the mileage amount; fees ride separately.
        XCTAssertEqual(report.businessValue, 55.12, accuracy: 0.001)
    }

    /// The correctness contract: monthly and annual snapshots use the same
    /// per-trip rounding and include the same rows for a given month.
    @MainActor
    func testAnnualMonthLinesMatchStandaloneMonthlyReports() throws {
        let trips = yearSampleTrips()
        let annual = try makeAnnualReport(trips: trips)

        let monthly = try ReportGenerator().makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: nyDate(2026, 2, 1, 0, 0),
            endDate: nyDate(2026, 2, 28, 23, 59),
            rate: fixtureRate,
            formatting: .enUS
        )
        XCTAssertEqual(monthly.includedTripIDs.count, 2)
        XCTAssertEqual(monthly.businessMiles, 45, accuracy: 0.001)
        XCTAssertEqual(monthly.businessValue, 32.63, accuracy: 0.001)
        for id in monthly.includedTripIDs {
            XCTAssertTrue(annual.csvText.contains(id.uuidString.lowercased()), annual.csvText)
            XCTAssertTrue(monthly.csvText.contains(id.uuidString.lowercased()), monthly.csvText)
        }

        // May is the rounding trap: per-row 2 dp values (1.00 × 3) must foot
        // identically in both reports, not re-round to 3.01.
        let may = try ReportGenerator().makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: nyDate(2026, 5, 1, 0, 0),
            endDate: nyDate(2026, 5, 31, 23, 59),
            rate: fixtureRate,
            formatting: .enUS
        )
        XCTAssertEqual(may.includedTripIDs.count, 3)
        XCTAssertEqual(may.businessValue, 2.19, accuracy: 0.001)
        XCTAssertEqual(may.csvText.components(separatedBy: ",0.725,USD,0.73,").count - 1, 3, may.csvText)
    }

    @MainActor
    func testAnnualPDFSummaryPageAndMonthSections() throws {
        let report = try makeAnnualReport(trips: yearSampleTrips())

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-annual.pdf")
            )
        }

        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        XCTAssertEqual(assertReportFooters(in: document).count, document.pageCount)

        // Page 1 is the accountant's one-pager: title, totals, month table.
        let firstPage = (document.page(at: 0)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(firstPage.contains("Annual Mileage Report"), firstPage)
        XCTAssertTrue(firstPage.contains("Monthly summary"), firstPage)
        XCTAssertTrue(firstPage.contains("February 2026"), firstPage)
        XCTAssertTrue(firstPage.contains("April 2026"), firstPage)
        XCTAssertTrue(firstPage.contains("Year total"), firstPage)
        XCTAssertTrue(firstPage.contains("$62.12"), firstPage)
        XCTAssertFalse(firstPage.contains("not a drive"), firstPage)
        // The trip table starts on page 2, never on the summary page.
        XCTAssertFalse(firstPage.contains("Destination"), firstPage)

        // Trip pages carry month dividers and footing subtotals.
        let restText = (1..<document.pageCount)
            .map { document.page(at: $0)?.string ?? "" }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(restText.contains("February 2026 total"), restText)
        XCTAssertTrue(restText.contains("March 2026 total"), restText)

        // Year totals block renders exactly once, on the last page.
        let lastPageText = document.page(at: document.pageCount - 1)?.string ?? ""
        XCTAssertTrue(lastPageText.contains("Totals"))
        for pageIndex in 0..<(document.pageCount - 1) {
            let pageText = document.page(at: pageIndex)?.string ?? ""
            XCTAssertFalse(pageText.contains("Totals"), "totals block leaked onto page \(pageIndex + 1)")
        }
    }

    @MainActor
    func testAnnualPDFPaginatesLargeYearWithTotalsOnLastPage() throws {
        let brindle = "22 Brindle St, Cambridge, MA 02139"
        let lunaris = "10 Lunaris St, Dorchester, MA 02122"
        var trips: [TripSummary] = []
        for month in [3, 6] {
            trips.append(contentsOf: (1...30).map { day in
                trip(purpose: "Photography Location", miles: 12.5, legs: [
                    leg(from: brindle, nyDate(2026, month, day, 9, 0), to: lunaris, nyDate(2026, month, day, 9, 45), miles: 6.25),
                    leg(from: lunaris, nyDate(2026, month, day, 11, 0), to: brindle, nyDate(2026, month, day, 11, 45), miles: 6.25),
                ])
            })
        }

        let report = try makeAnnualReport(trips: trips)
        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-annual-dense.pdf")
            )
        }
        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertGreaterThan(document.pageCount, 2)
        let footerBounds = assertReportFooters(in: document)
        XCTAssertEqual(footerBounds.count, document.pageCount)

        let lastPage = try XCTUnwrap(document.page(at: document.pageCount - 1))
        let lastPageText = lastPage.string ?? ""
        XCTAssertTrue(lastPageText.contains("Totals"))
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
    func testAnnualPDFPaginatesDenseSummaryWithoutClippingVehiclesOdometerOrMonths() throws {
        let vehicleNames = [
            "Comet 2015",
            "Touring",
            "Transit Van",
            "Sprinter",
            "RAV4",
            "F-150",
        ]
        let trips = (1...12).map { month in
            trip(purpose: "Client visit", miles: Double(month), legs: [
                leg(
                    from: "22 Brindle St, Cambridge, MA 02139",
                    nyDate(2026, month, 15, 9, 0),
                    to: "10 Lunaris St, Dorchester, MA 02122",
                    nyDate(2026, month, 15, 9, 45),
                    miles: Double(month)
                )
            ])
        }
        let vehicleNamesByTripID = Dictionary(uniqueKeysWithValues: trips.enumerated().map { index, trip in
            (trip.id, vehicleNames[index % vehicleNames.count])
        })
        let report = try ReportGenerator().makeAnnualReport(
            trips: trips,
            odometerCheckpoints: [
                OdometerCheckpoint(date: nyDate(2026, 1, 10, 9, 0), odometerMiles: 10_000),
                OdometerCheckpoint(date: nyDate(2026, 12, 20, 9, 0), odometerMiles: 12_000),
            ],
            startDate: nyDate(2026, 1, 1, 0, 0),
            endDate: nyDate(2026, 12, 31, 23, 59),
            rate: fixtureRate,
            formatting: .enUS,
            calendar: newYorkCalendar,
            vehicleNamesByTripID: vehicleNamesByTripID
        )

        if let snapshotDirectory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] {
            try report.pdfData.write(
                to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("Mileage-2026-annual-many-vehicles.pdf")
            )
        }

        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertEqual(assertReportFooters(in: document).count, document.pageCount)
        let pageTexts = (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }

        let overviewText = pageTexts[0]
        XCTAssertTrue(overviewText.contains("Total reimbursement"), overviewText)
        XCTAssertTrue(overviewText.contains("Vehicles"), overviewText)
        for vehicleName in vehicleNames {
            XCTAssertTrue(overviewText.contains(vehicleName), "Missing \(vehicleName): \(overviewText)")
        }
        XCTAssertTrue(overviewText.contains("Odometer"), overviewText)
        XCTAssertTrue(overviewText.contains("10000.0 to 12000.0"), overviewText)
        XCTAssertTrue(overviewText.contains("Estimated from readings Jan 10, 2026"), overviewText)

        let monthlySummaryPages = pageTexts.enumerated().filter { $0.element.contains("Monthly summary") }
        XCTAssertEqual(monthlySummaryPages.count, 1, pageTexts.joined(separator: "\n---\n"))
        let monthlySummary = try XCTUnwrap(monthlySummaryPages.first)
        XCTAssertEqual(monthlySummary.offset, 1)
        for monthName in [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ] {
            XCTAssertTrue(
                monthlySummary.element.contains("\(monthName) 2026"),
                "Missing \(monthName): \(monthlySummary.element)"
            )
        }
        XCTAssertTrue(monthlySummary.element.contains("Year total"), monthlySummary.element)
        XCTAssertTrue(monthlySummary.element.contains("$56.56"), monthlySummary.element)
    }

    @MainActor
    func testAnnualReportWithNoBusinessTrips() throws {
        let personal = trip(purpose: "", miles: 5.0, classification: .personal, legs: [
            leg(
                from: "999 Excluded Ave, Boston, MA 02110", nyDate(2026, 4, 2, 9, 0),
                to: "22 Brindle St, Cambridge, MA 02139", nyDate(2026, 4, 2, 9, 30),
                miles: 5.0
            )
        ])

        let report = try makeAnnualReport(trips: [personal])
        XCTAssertEqual(report.csvText, "Trip ID,Report Month,Start Date,Start Time,End Date,End Time,Time Zone,Duration Minutes,Origin,Destination,Reported Distance,Distance Unit,Original Recorded Distance,Distance Adjusted,Classification,Vehicle,Entry Method,Business Purpose,Notes,Mileage Rate,Currency,Mileage Amount,Tolls,Parking,Total Amount,Leg Count,Stop Count,Leg Details")
        XCTAssertTrue(report.includedTripIDs.isEmpty)

        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertEqual(assertReportFooters(in: document).count, document.pageCount)
        let firstPage = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(firstPage.contains("No business trips recorded for this period."), firstPage)
    }

    @MainActor
    func testAnnualReportInGermanKilometersAndEuros() throws {
        let trips = [
            trip(purpose: "Client visit", miles: 10.0, tolls: 2.00, legs: [
                leg(
                    from: "22 Brindle St, Cambridge, MA 02139", nyDate(2026, 2, 2, 9, 0),
                    to: "10 Lunaris St, Dorchester, MA 02122", nyDate(2026, 2, 2, 9, 45),
                    miles: 10.0
                )
            ])
        ]

        // 10 mi = 16.09 km at 0.50 €/km → 8.05 € mileage + 2.00 € tolls.
        let report = try ReportGenerator().makeAnnualReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: nyDate(2026, 1, 1, 0, 0),
            endDate: nyDate(2026, 12, 31, 23, 59),
            rate: MileageRate(amountPerUnit: 0.50, unit: .kilometers),
            formatting: ReportFormattingContext(
                locale: Locale(identifier: "de_DE"),
                distanceUnit: .kilometers,
                currencyCode: "EUR"
            ),
            calendar: newYorkCalendar
        )

        // Canonical CSV headers, dates, units, and numbers stay invariant even
        // when the PDF uses the report locale.
        XCTAssertTrue(report.csvText.contains(",2026-02,2026-02-02,09:00:00,"), report.csvText)
        XCTAssertTrue(report.csvText.contains(",16.09,km,16.09,No,Business,"), report.csvText)
        XCTAssertTrue(report.csvText.contains(",0.500,EUR,8.05,2.00,0.00,10.05,"), report.csvText)
    }

    /// A trip minutes before midnight on Dec 31 belongs to December of this
    /// year — the same bucketing the Reports screen uses.
    @MainActor
    func testYearBoundaryTripLandsInDecember() throws {
        let interval = AnnualReportBreakdown.yearInterval(containing: nyDate(2026, 6, 15, 12, 0), calendar: newYorkCalendar)
        let endDate = AnnualReportBreakdown.reportEndDate(forYearContaining: nyDate(2026, 6, 15, 12, 0), calendar: newYorkCalendar)
        XCTAssertEqual(interval.start, nyDate(2026, 1, 1, 0, 0))
        XCTAssertTrue(endDate >= nyDate(2026, 12, 31, 23, 59))
        XCTAssertTrue(endDate < nyDate(2027, 1, 1, 0, 0))

        let lateTrip = trip(purpose: "Photo shoot", miles: 8.0, legs: [
            leg(
                from: "22 Brindle St, Cambridge, MA 02139", nyDate(2026, 12, 31, 23, 30),
                to: "10 Lunaris St, Dorchester, MA 02122", nyDate(2026, 12, 31, 23, 55),
                miles: 8.0
            )
        ])
        let report = try ReportGenerator().makeAnnualReport(
            trips: [lateTrip],
            odometerCheckpoints: [],
            startDate: interval.start,
            endDate: endDate,
            rate: fixtureRate,
            formatting: .enUS,
            calendar: newYorkCalendar
        )
        XCTAssertTrue(report.csvText.contains(",2026-12,2026-12-31,23:30:00,"), report.csvText)
        XCTAssertFalse(report.csvText.contains(",2027-01,"), report.csvText)
    }

    // MARK: - 2026 sample data

    /// Regression for the review finding that dense annual pages sliced their
    /// last row: pagination under-budgeted month dividers (24 pt vs 26 pt
    /// rendered) and wrapped route-title lines (9.8 pt vs ~10.03 pt), and the
    /// hard-clipped body then cut the overflowing row instead of nudging the
    /// footer. Every month split by a divider, every row carrying two fee
    /// notes and a wrapping route title, must keep all body text above the
    /// footer safety gap on every page.
    @MainActor
    func testDenseAnnualPDFKeepsEveryRowAboveFooterGap() throws {
        let museum = "Moonlit Navigation Guild Museum, 25 Comet Way, Boston, MA 02115"
        let moonspire = "Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143"
        var trips: [TripSummary] = []
        for month in 1...12 {
            for day in [4, 18] {
                trips.append(trip(
                    purpose: "Location scout and client walkthrough",
                    miles: 23.5,
                    tolls: 4.15,
                    parking: 12.00,
                    legs: [
                        leg(
                            from: museum,
                            nyDate(2026, month, day, 8, 30),
                            to: moonspire,
                            nyDate(2026, month, day, 9, 40),
                            miles: 23.5
                        )
                    ]
                ))
            }
        }

        let report = try makeAnnualReport(trips: trips)
        let document = try XCTUnwrap(PDFDocument(data: report.pdfData))
        XCTAssertGreaterThanOrEqual(document.pageCount, 3)
        assertReportFooters(in: document)
    }

    private func yearSampleTrips() -> [TripSummary] {
        let brindle = "22 Brindle St, Cambridge, MA 02139"
        let lunaris = "10 Lunaris St, Dorchester, MA 02122"
        let lunarglades = "206 Lunarglades St, Wilmington, MA 01887"
        let moonspire = "Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143"
        let excluded = "999 Excluded Ave, Boston, MA 02110"

        var trips: [TripSummary] = [
            trip(purpose: "Client visit", miles: 10.0, tolls: 2.00, legs: [
                leg(from: brindle, nyDate(2026, 2, 3, 9, 0), to: lunaris, nyDate(2026, 2, 3, 9, 45), miles: 10.0)
            ]),
            trip(purpose: "Photo shoot", miles: 35.0, legs: [
                leg(from: brindle, nyDate(2026, 2, 10, 8, 0), to: lunarglades, nyDate(2026, 2, 10, 9, 0), miles: 35.0)
            ]),
            trip(purpose: "Gallery delivery", miles: 20.0, parking: 5.00, legs: [
                leg(from: brindle, nyDate(2026, 3, 5, 10, 0), to: moonspire, nyDate(2026, 3, 5, 10, 30), miles: 12.5),
                leg(from: moonspire, nyDate(2026, 3, 5, 12, 0), to: brindle, nyDate(2026, 3, 5, 12, 30), miles: 7.5),
            ]),
            trip(purpose: "Photo shoot", miles: 8.0, legs: [
                leg(from: brindle, nyDate(2026, 12, 31, 23, 30), to: lunaris, nyDate(2026, 12, 31, 23, 55), miles: 8.0)
            ]),
        ]
        trips.append(contentsOf: (0..<3).map { index in
            trip(purpose: "Client visit", miles: 1.004, legs: [
                leg(from: lunaris, nyDate(2026, 5, 2 + index, 9, 0), to: brindle, nyDate(2026, 5, 2 + index, 9, 30), miles: 1.004)
            ])
        })
        // A personal and an unclassified trip: visible in month rows on the
        // Reports screen, but never in a report export.
        trips.append(trip(purpose: "", miles: 12.0, classification: .personal, legs: [
            leg(from: excluded, nyDate(2026, 2, 14, 9, 0), to: brindle, nyDate(2026, 2, 14, 9, 40), miles: 12.0)
        ]))
        trips.append(trip(purpose: "", miles: 6.0, classification: nil, legs: [
            leg(from: excluded, nyDate(2026, 3, 20, 9, 0), to: brindle, nyDate(2026, 3, 20, 9, 20), miles: 6.0)
        ]))
        return trips
    }

    @MainActor
    private func makeAnnualReport(trips: [TripSummary]) throws -> ReportSnapshot {
        try ReportGenerator().makeAnnualReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: nyDate(2026, 1, 1, 0, 0),
            endDate: nyDate(2026, 12, 31, 23, 59),
            rate: fixtureRate,
            formatting: .enUS,
            calendar: newYorkCalendar
        )
    }

    private var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func nyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        newYorkCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date(timeIntervalSince1970: 0)
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
        purpose: String,
        miles: Double,
        tolls: Double = 0,
        parking: Double = 0,
        classification: TripClassification? = .business,
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
            reviewStatus: .readyToExport,
            businessPurpose: purpose.isEmpty ? nil : purpose,
            notes: nil,
            tollsAmount: tolls,
            parkingAmount: parking,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil,
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
