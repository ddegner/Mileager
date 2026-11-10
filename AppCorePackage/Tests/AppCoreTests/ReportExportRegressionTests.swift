import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import XCTest
@testable import AppCore
@testable import AppCoreReporting

final class ReportExportRegressionTests: XCTestCase {
    // Fixed rate for the 2026 calculation and rendered-report fixtures.
    private let fixtureRate = MileageRate(amountPerUnit: 0.725, unit: .miles)

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var formatting: ReportFormattingContext {
        ReportFormattingContext(locale: Locale(identifier: "en_US"), distanceUnit: .miles, currencyCode: "USD")
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    private var schedule: MileageRateSchedule {
        MileageRateSchedule(baseRate: MileageRate(amountPerUnit: 0.70, unit: .miles), rules: [
            MileageRateRule(effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 1, day: 1), rate: fixtureRate)
        ])
    }

    @MainActor
    func testMergedTripsKeepTheirYearRateAndFeeAttribution() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let december = try makeTrip(store, start: date(2025, 12, 31), distanceMiles: 10, classification: .business, businessPurpose: "Client visit", tolls: 3)
        let january = try makeTrip(store, start: date(2026, 1, 1), distanceMiles: 10, classification: .business, businessPurpose: "Client visit", parking: 5)
        let merged = try store.mergeTrips(ids: [december.id, january.id])
        let generator = ReportGenerator()
        let previousYear = try annual([merged], year: 2025)
        let nextYear = try annual([merged], year: 2026)
        XCTAssertEqual(previousYear.businessMiles, 10, accuracy: 0.0001)
        XCTAssertEqual(nextYear.businessMiles, 10, accuracy: 0.0001)
        XCTAssertEqual(previousYear.businessValue, 7, accuracy: 0.0001)
        XCTAssertEqual(nextYear.businessValue, 7.25, accuracy: 0.0001)
        XCTAssertEqual(previousYear.includedTripIDs, [merged.id])
        XCTAssertEqual(nextYear.includedTripIDs, [merged.id])
        XCTAssertTrue(previousYear.csvText.contains(",0.700,USD,7.00,3.00,0.00,10.00,"))
        XCTAssertTrue(nextYear.csvText.contains(",0.725,USD,7.25,0.00,5.00,12.25,"))
        let receipt = try await generator.makeTripPDF(for: merged, rate: schedule.baseRate, formatting: formatting, rateSchedule: schedule, calendar: calendar)
        let receiptText = try pdf(receipt, name: "merged-year-receipt").string ?? ""
        XCTAssertTrue(receiptText.contains("$22.25"))
        XCTAssertTrue(receiptText.contains("Multiple rates"))
        try save(previousYear, name: "merged-2025")
        try save(nextYear, name: "merged-2026")
        // Exporting has not split or edited the stored record.
        XCTAssertEqual(try store.fetchTrip(id: merged.id), merged)
        XCTAssertEqual(try store.fetchTrips().count, 1)
    }

    @MainActor
    func testAnnualAndMonthlySlicesAgreeAcrossMidMonthRateChange() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let dates = [date(2026, 1, 10), date(2026, 1, 20), date(2026, 2, 2)]
        let sources = try dates.map { try makeTrip(store, start: $0, distanceMiles: 10, classification: .business, businessPurpose: "Client visit") }
        let merged = try store.mergeTrips(ids: sources.map(\.id))
        let rates = MileageRateSchedule(baseRate: MileageRate(amountPerUnit: 0.50, unit: .miles), rules: [
            MileageRateRule(effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 1, day: 15), rate: MileageRate(amountPerUnit: 0.75, unit: .miles))
        ])
        let january = try monthly([merged], month: 1, rates: rates)
        let february = try monthly([merged], month: 2, rates: rates)
        let year = try annual([merged], year: 2026, rates: rates)
        XCTAssertEqual(january.businessMiles, 20, accuracy: 0.0001)
        XCTAssertEqual(january.businessValue, 12.50, accuracy: 0.0001)
        XCTAssertEqual(year.businessValue, january.businessValue + february.businessValue, accuracy: 0.0001)
        XCTAssertEqual(year.includedTripIDs, [merged.id])
        XCTAssertEqual(january.csvText.components(separatedBy: merged.id.uuidString.lowercased()).count - 1, 2)
        XCTAssertEqual(year.csvText.components(separatedBy: merged.id.uuidString.lowercased()).count - 1, 3)
        let text = try pdf(year.pdfData, name: "merged-rate-annual").string ?? ""
        XCTAssertTrue(text.contains("$20.00"))
        XCTAssertTrue(text.contains("Multiple rates"))
    }

    func testCorrectionsConnectorsAndLegacyFeesAreConservedAcrossSlices() {
        let first = leg(index: 0, start: date(2025, 12, 31), miles: 5)
        let second = leg(index: 1, start: date(2026, 1, 1), miles: 10)
        let connector = TripLegConnector(fromLegID: first.id, toLegID: second.id, startCoordinate: Coordinate(latitude: 0, longitude: 0), endCoordinate: Coordinate(latitude: 0, longitude: 0.01), distanceMeters: DistanceConversion.meters(fromMiles: 5))
        var merged = trip(legs: [first, second])
        merged.connectors = [connector]
        merged.distanceMeters = DistanceConversion.meters(fromMiles: 20)
        merged.manualDistanceOverrideMeters = DistanceConversion.meters(fromMiles: 40)
        // Legacy aggregate with no leg attribution belongs to the first slice.
        merged.tollsAmount = 3
        let slices = ReportTripAllocation.slices(of: merged, schedule: schedule, calendar: calendar, currency: formatting.currency)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].miles, 10, accuracy: 0.0001)
        XCTAssertEqual(slices[1].miles, 30, accuracy: 0.0001)
        XCTAssertEqual(slices[1].effectiveLegs[0].distanceMeters, DistanceConversion.meters(fromMiles: 15), accuracy: 0.001)
        XCTAssertEqual(slices.map(\.tollsAmount), [3, 0])
        XCTAssertEqual(slices.reduce(0) { $0 + $1.reportableDistanceMeters }, merged.reportableDistanceMeters, accuracy: 0.0001)
        XCTAssertTrue(slices.allSatisfy { $0.id == merged.id })
    }

    @MainActor
    func testIneligibleReceiptsNeverClaimMileageOrFees() async throws {
        for classification in [TripClassification.business, .personal, .notADrive, nil] {
            var record = trip()
            record.classification = classification
            record.businessPurpose = classification == .business ? "  \n " : nil
            record.tollsAmount = 3
            record.parkingAmount = 5
            let data = try await ReportGenerator().makeTripPDF(for: record, rate: fixtureRate, formatting: formatting)
            let document = try pdf(data, name: "ineligible-\(classification?.rawValue ?? "unreviewed")")
            let text = document.string ?? ""
            XCTAssertTrue(text.contains("$0.00"))
            XCTAssertFalse(text.contains("$15.25"))
            XCTAssertFalse(text.contains("$8.00"))
            if classification == .business { XCTAssertTrue(text.contains("Needs Review")) }
            if classification == nil { XCTAssertTrue(text.contains("Unreviewed")) }
        }
    }

    @MainActor
    func testTwentyLegReceiptPreservesEveryLegAndFooter() async throws {
        let legs = (0..<20).map { leg(index: $0, start: date(2026, 1, 2).addingTimeInterval(Double($0) * 3600)) }
        let record = trip(legs: legs)
        let data = try await ReportGenerator().makeTripPDF(for: record, rate: fixtureRate, formatting: formatting)
        let document = try pdf(data, name: "twenty-leg-receipt")
        XCTAssertGreaterThan(document.pageCount, 1)
        let text = document.string ?? ""
        for index in 1...20 { XCTAssertTrue(text.contains("\(index). "), "Missing leg \(index)") }
    }

    @MainActor
    func testThirteenLegThreeDayReceiptKeepsEachLegTogetherWithConsistentType() async throws {
        let stops = [
            "City Hall, 815 Massachusetts Ave, Cambridge, MA 02139",
            "Port Plaza Shopping Center, 37 Storey Ave, Newburyport, MA 01950",
            "Visitor Center, 200 Main Street, Bartlett, NH 03812",
            "Mountain View Lodge, 100 US-302, Glen, NH 03838"
        ]
        let legs = (0..<13).map { index in
            var value = leg(index: index, start: date(2026, 9, 11 + index / 5).addingTimeInterval(Double(index % 5) * 3600), miles: Double(index + 1))
            value.startAddress = stops[index % stops.count]
            value.endAddress = stops[(index + 1) % stops.count] + " ENDLEG\(index + 1)"
            return value
        }
        for locale in ["en_US", "de_DE", "fr_FR", "es_ES"] {
            var context = formatting
            context.locale = Locale(identifier: locale)
            var record = trip(legs: legs)
            record.businessPurpose = "Layout preview - sample three-day photo assignment"
            let data = try await ReportGenerator().makeTripPDF(for: record, rate: fixtureRate, generatedAt: date(2026, 9, 14), formatting: context, calendar: calendar)
            let document = try pdf(data, name: "three-day-leg-layout-\(locale)")
            XCTAssertGreaterThan(document.pageCount, 1)
            let headingDate = DateFormatter()
            headingDate.locale = context.locale
            headingDate.timeZone = calendar.timeZone
            headingDate.dateStyle = .medium
            for index in 1...13 {
                let prefix = "\(index). \(headingDate.string(from: legs[index - 1].startDate))"
                let heading = try XCTUnwrap(document.findString(prefix, withOptions: []).first { selection in
                    // Avoid treating the tail of 11/12/13 as legs 1/2/3.
                    guard let page = selection.pages.first else { return false }
                    return abs(selection.bounds(for: page).minX - 42) < 1
                })
                let page = try XCTUnwrap(heading.pages.first)
                XCTAssertTrue((page.string ?? "").contains("ENDLEG\(index)"), "Leg \(index) split across pages")
                let attributes = try XCTUnwrap(heading.attributedString?.attributes(at: 0, effectiveRange: nil))
                #if canImport(AppKit)
                let font = try XCTUnwrap(attributes[.font] as? NSFont)
                #else
                let font = try XCTUnwrap(attributes[.font] as? UIFont)
                #endif
                XCTAssertEqual(font.pointSize, 11, accuracy: 0.01)
            }
            let day = DateFormatter()
            day.locale = context.locale
            day.timeZone = calendar.timeZone
            day.dateStyle = .medium
            for number in 11...13 {
                XCTAssertTrue((document.string ?? "").contains(day.string(from: date(2026, 9, number))))
            }
        }
    }

    @MainActor
    func testOversizedLegRepeatsHeadingAndPreservesAllAddressText() async throws {
        var first = leg(index: 0, start: date(2026, 1, 2))
        let markers = (0..<350).map { String(format: "Address%03d", $0) }
        first.endAddress = markers.joined(separator: " ") + " ADDRESSEND"
        let record = trip(legs: [first, leg(index: 1, start: date(2026, 1, 3))])
        let data = try await ReportGenerator().makeTripPDF(for: record, rate: fixtureRate, formatting: formatting, calendar: calendar)
        let document = try pdf(data, name: "oversized-leg-receipt")
        let text = document.string ?? ""
        for marker in markers { XCTAssertTrue(text.contains(marker), "Missing \(marker)") }
        XCTAssertTrue(text.contains("ADDRESSEND"))
        for index in 1..<document.pageCount {
            let pageText = document.page(at: index)?.string ?? ""
            if pageText.contains("Legs / Stops") && pageText.contains("Address") {
                XCTAssertTrue(pageText.contains("1. Jan 2, 2026"))
            }
        }
    }

    @MainActor
    func testExportLayoutCheckRejectsTextOutsidePageMargins() async throws {
        let data = try await ReportGenerator().makeTripPDF(for: trip(), rate: fixtureRate, formatting: formatting)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        page.setBounds(box.offsetBy(dx: 20, dy: 0), for: .mediaBox)
        let cropped = try XCTUnwrap(document.dataRepresentation())
        XCTAssertNoThrow(try ReportPDFValidator.validate(cropped))
        XCTAssertThrowsError(try ReportPDFValidator.validateLayout(cropped, pageCount: document.pageCount))
    }

    @MainActor
    func testLongPurposeAndEndpointsContinueWithoutLosingText() async throws {
        var record = trip()
        let markers = (0..<130).map { String(format: "PurposeMarker%03d", $0) }
        record.businessPurpose = markers.map { "\($0) photograph client facilities and document installations for project delivery." }.joined(separator: " ")
        record.startAddress = String(repeating: "Warehouse district office entrance ", count: 30) + "ORIGINENDMARKER"
        record.endAddress = String(repeating: "Client location delivery entrance ", count: 30) + "DESTINATIONENDMARKER"
        let generator = ReportGenerator()
        let receiptData = try await generator.makeTripPDF(for: record, rate: fixtureRate, formatting: formatting)
        let receipt = try pdf(receiptData, name: "long-details-receipt")
        let month = try monthly([record], month: 1)
        let monthPDF = try pdf(month.pdfData, name: "long-details-month")
        let year = try annual([record], year: 2026)
        let yearPDF = try pdf(year.pdfData, name: "long-details-annual")
        for document in [receipt, monthPDF, yearPDF] {
            XCTAssertGreaterThan(document.pageCount, 1)
            let text = document.string ?? ""
            for marker in markers { XCTAssertTrue(text.contains(marker), "Missing \(marker)") }
            XCTAssertTrue(text.contains("ORIGINENDMARKER"))
            XCTAssertTrue(text.contains("DESTINATIONENDMARKER"))
        }
        // Splitting a printed row must not print its charge again.
        let normal = try monthly([trip()], month: 1)
        let normalPDF = try pdf(normal.pdfData)
        XCTAssertEqual(occurrences("$7.25", in: monthPDF), occurrences("$7.25", in: normalPDF))
        try save(month, name: "long-details-month")
    }

    @MainActor
    func testFractionalFeesReconcileBetweenCSVReceiptsAndPeriodPDFs() async throws {
        var record = trip()
        record.tollsAmount = 0.014
        var second = record
        second.id = UUID()
        var third = record
        third.id = UUID()
        let month = try monthly([record, second, third], month: 1)
        let year = try annual([record, second, third], year: 2026)
        for report in [month, year] {
            XCTAssertEqual(report.csvText.components(separatedBy: ",7.25,0.01,0.00,7.26,").count - 1, 3)
            let text = try pdf(report.pdfData).string ?? ""
            XCTAssertTrue(text.contains("$21.78"))
            XCTAssertFalse(text.contains("$21.79"))
        }
        let receipt = try await ReportGenerator().makeTripPDF(for: record, rate: fixtureRate, formatting: formatting)
        XCTAssertTrue((try pdf(receipt).string ?? "").contains("$7.26"))
        try save(month, name: "fractional-fees-month")
    }

    @MainActor
    func testCurrencyPrecisionMatchesPDFRowsCSVAndTotals() throws {
        for (code, rateAmount, rowAmount, total) in [("JPY", 0.073, "1", 3.0), ("KWD", 0.07364, "0.736", 2.208), ("CLF", 0.073649, "0.7365", 2.2095)] {
            var context = formatting
            context.currencyCode = code
            let records = (0..<3).map { _ in trip() }
            let rates = MileageRateSchedule(baseRate: MileageRate(amountPerUnit: rateAmount, unit: .miles))
            let month = try monthly(records, month: 1, rates: rates, context: context)
            let year = try annual(records, year: 2026, rates: rates, context: context)
            for report in [month, year] {
                XCTAssertEqual(report.businessValue, total, accuracy: 0.000001)
                XCTAssertEqual(report.csvText.components(separatedBy: ",\(code),\(rowAmount),").count - 1, 3)
                let text = try pdf(report.pdfData).string ?? ""
                XCTAssertTrue(text.filter { !$0.isWhitespace }.contains(CurrencyFormatting.label(total, code: code, locale: context.locale).filter { !$0.isWhitespace }), text)
            }
            try save(month, name: "currency-\(code)")
        }
    }

    @MainActor
    private func annual(_ trips: [TripSummary], year: Int, rates: MileageRateSchedule? = nil, context: ReportFormattingContext? = nil) throws -> ReportSnapshot {
        let date = date(year, 1, 1)
        let rates = rates ?? schedule
        return try ReportGenerator().makeAnnualReport(trips: trips, odometerCheckpoints: [], startDate: AnnualReportBreakdown.yearInterval(containing: date, calendar: calendar).start, endDate: AnnualReportBreakdown.reportEndDate(forYearContaining: date, calendar: calendar), rate: rates.baseRate, rateSchedule: rates, formatting: context ?? formatting, calendar: calendar)
    }

    @MainActor
    private func monthly(_ trips: [TripSummary], month: Int, rates: MileageRateSchedule? = nil, context: ReportFormattingContext? = nil) throws -> ReportSnapshot {
        let interval = calendar.dateInterval(of: .month, for: date(2026, month, 1))!
        let rates = rates ?? schedule
        return try ReportGenerator().makeReport(trips: trips, odometerCheckpoints: [], startDate: interval.start, endDate: interval.end.addingTimeInterval(-0.001), rate: rates.baseRate, rateSchedule: rates, formatting: context ?? formatting, calendar: calendar)
    }

    private func leg(index: Int, start: Date, miles: Double = 1) -> TripLeg {
        TripLeg(captureSource: "automatic", startDate: start, endDate: start.addingTimeInterval(1800), startCoordinate: nil, endCoordinate: nil, startAddress: "\(index + 10) Main St, Boston, MA", endAddress: "\(index + 11) Main St, Boston, MA", distanceMeters: DistanceConversion.meters(fromMiles: miles), routePolyline: nil)
    }

    private func trip(legs: [TripLeg] = []) -> TripSummary {
        let start = legs.first?.startDate ?? date(2026, 1, 2)
        return TripSummary(
            id: UUID(), createdAt: start, updatedAt: start,
            captureSource: legs.isEmpty ? "manual" : "merged",
            startDate: start, endDate: legs.last?.endDate ?? start.addingTimeInterval(1800),
            startCoordinate: nil, endCoordinate: nil,
            startAddress: "10 Main St, Boston, MA", endAddress: "20 Main St, Boston, MA",
            distanceMeters: legs.isEmpty ? DistanceConversion.meters(fromMiles: 10) : legs.reduce(0) { $0 + $1.distanceMeters },
            routePolyline: nil, classification: .business, reviewStatus: .readyToExport,
            businessPurpose: "Client visit", notes: nil, tollsAmount: 0, parkingAmount: 0,
            needsAttention: false, attentionReasons: [], manualDistanceOverrideMeters: nil, legs: legs
        )
    }

    @MainActor
    private func pdf(_ data: Data, name: String? = nil) throws -> PDFDocument {
        let document = try XCTUnwrap(PDFDocument(data: data))
        assertReportFooters(in: document)
        if let directory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"], let name {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".pdf"))
        }
        return document
    }

    private func save(_ report: ReportSnapshot, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PDF_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory)
        try report.pdfData.write(to: url.appendingPathComponent(name + ".pdf"))
        try report.csvText.write(to: url.appendingPathComponent(name + ".csv"), atomically: true, encoding: .utf8)
    }

    private func occurrences(_ text: String, in document: PDFDocument) -> Int {
        (document.string ?? "").components(separatedBy: text).count - 1
    }
}
