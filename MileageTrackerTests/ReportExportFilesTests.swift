import AppCore
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import MileageTracker

final class ReportExportFilesTests: XCTestCase {
    func testMileageReportFileWriterWritesNamedCSVAndPDFArtifacts() throws {
        let start = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let report = ReportSnapshot(
            startDate: start,
            endDate: start.addingTimeInterval(86_400),
            title: "May Report",
            csvText: "Date,Miles\n2026-05-01,10",
            pdfData: try validPDFData(),
            businessMiles: 10,
            businessValue: 7.25,
            rateCentsPerMile: 72.5,
            includedTripIDs: []
        )

        let files = try MileageReportFileWriter.write(report: report)

        XCTAssertEqual(files.csvURL.lastPathComponent, "Mileage-2026-05.csv")
        XCTAssertEqual(files.pdfURL.lastPathComponent, "Mileage-2026-05.pdf")
        XCTAssertEqual(try String(contentsOf: files.csvURL, encoding: .utf8), report.csvText)
        XCTAssertEqual(try Data(contentsOf: files.pdfURL), report.pdfData)
        try assertFileProtectionComplete(at: files.csvURL)
        try assertFileProtectionComplete(at: files.pdfURL)
    }

    func testMileageReportFileWriterUsesYearSlugForAnnualReports() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31)))
        let report = ReportSnapshot(
            startDate: start,
            endDate: end,
            title: "2026 Report",
            csvText: "Month,Miles\nJanuary 2026,10.00",
            pdfData: try validPDFData(),
            businessMiles: 10,
            businessValue: 7.25,
            rateCentsPerMile: 72.5,
            includedTripIDs: []
        )

        let files = try MileageReportFileWriter.write(report: report, period: .year)

        XCTAssertEqual(files.csvURL.lastPathComponent, "Mileage-2026.csv")
        XCTAssertEqual(files.pdfURL.lastPathComponent, "Mileage-2026.pdf")
        XCTAssertEqual(try String(contentsOf: files.csvURL, encoding: .utf8), report.csvText)
        try assertFileProtectionComplete(at: files.csvURL)
        try assertFileProtectionComplete(at: files.pdfURL)
    }

    func testTripPDFFileWriterUsesTripDateAndStableShortID() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tripID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let trip = TripSummary(
            id: tripID,
            createdAt: start,
            updatedAt: start,
            captureSource: "manual",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            routePolyline: nil,
            classification: .business,
            reviewStatus: .readyToExport,
            businessPurpose: "Client",
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
        let pdfData = try validPDFData()

        let url = try TripPDFExportFileWriter.write(trip: trip, pdfData: pdfData)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("Mileage-Trip-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-11111111.pdf"))
        XCTAssertEqual(try Data(contentsOf: url), pdfData)
        try assertFileProtectionComplete(at: url)
    }

    func testReportWritersRejectEmptyOrMalformedPDFData() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = ReportSnapshot(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            title: "Broken Report",
            csvText: "Date,Miles",
            pdfData: Data(),
            businessMiles: 0,
            businessValue: 0,
            rateCentsPerMile: 72.5,
            includedTripIDs: []
        )
        let trip = TripSummary(
            id: UUID(),
            createdAt: start,
            updatedAt: start,
            captureSource: "manual",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: "Start",
            endAddress: "End",
            distanceMeters: 1_000,
            routePolyline: nil,
            classification: .personal,
            reviewStatus: .readyToExport,
            businessPurpose: nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )

        XCTAssertThrowsError(try MileageReportFileWriter.write(report: report)) { error in
            XCTAssertEqual(error as? ReportRenderingError, .emptyPDF)
        }
        XCTAssertThrowsError(try TripPDFExportFileWriter.write(trip: trip, pdfData: Data("not pdf".utf8))) { error in
            XCTAssertEqual(error as? ReportRenderingError, .invalidPDF)
        }
        XCTAssertThrowsError(try TripPDFExportFileWriter.write(trip: trip, pdfData: Data("%PDF".utf8))) { error in
            XCTAssertEqual(error as? ReportRenderingError, .invalidPDF)
        }
    }

    func testReportExportFormatSelectsExpectedFileURL() throws {
        let start = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let report = ReportSnapshot(
            startDate: start,
            endDate: start.addingTimeInterval(86_400),
            title: "May Report",
            csvText: "Date,Miles\n2026-05-01,10",
            pdfData: try validPDFData(),
            businessMiles: 10,
            businessValue: 7.25,
            rateCentsPerMile: 72.5,
            includedTripIDs: []
        )
        let files = try MileageReportFileWriter.write(report: report)

        XCTAssertEqual(MileageReportExportFormat.csv.url(from: files), files.csvURL)
        XCTAssertEqual(MileageReportExportFormat.pdf.url(from: files), files.pdfURL)
        XCTAssertEqual(MileageReportExportFormat.quickBooksCSV.url(from: files), files.csvURL)
    }

    @MainActor
    func testQuickBooksExportsUseSelectedPeriodAndVehicleAndDistinctFilenames() async throws {
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        let selected = try XCTUnwrap(model.createVehicle(name: "Work car"))
        let other = try XCTUnwrap(model.createVehicle(name: "Other car"))
        let calendar = Calendar(identifier: .gregorian)
        let may = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 9)))
        let june = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9)))
        for (start, miles, vehicle) in [(may, 10.0, selected), (june, 20.0, selected), (may, 50.0, other)] {
            let trip = try XCTUnwrap(model.createManualTrip(
                startDate: start, endDate: start.addingTimeInterval(1800), distanceMiles: miles,
                origin: "Office", destination: "Client", classification: .business,
                purpose: "Client visit", notes: "", tolls: 5, parking: 7
            ))
            model.assignVehicle(trip, vehicleID: vehicle.id)
        }
        let monthly = try await model.prepareMonthlyReportExport(
            forMonthContaining: may, vehicleFilter: .vehicle(selected.id), format: .quickBooksCSV
        )
        let annual = try await model.prepareAnnualReportExport(
            forYearContaining: may, vehicleFilter: .vehicle(selected.id), format: .quickBooksCSV
        )
        defer {
            for file in [monthly.csvURL, monthly.pdfURL, annual.csvURL, annual.pdfURL] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        XCTAssertEqual(monthly.csvURL.lastPathComponent, "Mileage-2026-05-QuickBooks.csv")
        XCTAssertEqual(annual.csvURL.lastPathComponent, "Mileage-2026-QuickBooks.csv")
        let monthlyText = try String(contentsOf: monthly.csvURL, encoding: .utf8)
        let annualText = try String(contentsOf: annual.csvURL, encoding: .utf8)
        XCTAssertTrue(monthlyText.contains("05/15/2026,Business,Client visit,Work car,Office,Client,10.00,0,Manual"))
        XCTAssertFalse(monthlyText.contains("06/15/2026"))
        XCTAssertTrue(annualText.contains("06/15/2026,Business,Client visit,Work car,Office,Client,20.00,0,Manual"))
        XCTAssertFalse(annualText.contains("Other car"))
        XCTAssertEqual(monthly.report.businessMiles, 10, accuracy: 0.001)
        XCTAssertEqual(annual.report.businessMiles, 30, accuracy: 0.001)
        try assertFileProtectionComplete(at: monthly.csvURL)
        try assertFileProtectionComplete(at: annual.csvURL)
    }

    @MainActor
    func testQuickBooksExportRejectsPeriodsWithoutEligibleBusinessTrips() async throws {
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            _ = try await model.prepareMonthlyReportExport(forMonthContaining: date, format: .quickBooksCSV)
            XCTFail("Expected no eligible business trips")
        } catch {
            guard case MileageReportExportError.noBusinessTrips = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        do {
            _ = try await model.prepareAnnualReportExport(forYearContaining: date, format: .quickBooksCSV)
            XCTFail("Expected no eligible business trips")
        } catch {
            guard case MileageReportExportError.noBusinessTrips = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testAppModelExportsMergedTripUsingTheFullRateSchedule() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )
        let calendar = Calendar(identifier: .gregorian)
        let december = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 12)))
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
        let schedule = MileageRateSchedule(
            baseRate: MileageRate(amountPerUnit: 0.70, unit: .miles),
            // The merged fixture crosses the historical 2025/January 2026 rates.
            rules: [MileageRateRule(effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 1, day: 1),
                                    rate: MileageRate(amountPerUnit: 0.725, unit: .miles))]
        )
        model.saveMileageRateSchedule(schedule)
        var ids: [UUID] = []
        for start in [december, january] {
            let trip = try XCTUnwrap(model.createManualTrip(
                startDate: start, endDate: start.addingTimeInterval(1800), distanceMiles: 10,
                origin: "Office", destination: "Client", classification: .business,
                purpose: "Client visit", notes: "", tolls: 0, parking: 0
            ))
            ids.append(trip.id)
        }
        model.merge(tripIDs: ids)
        let merged = try XCTUnwrap(model.trips.first(where: \.isMerged))
        let receiptURL = await model.exportTripPDF(merged)
        let url = try XCTUnwrap(receiptURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let expected = CurrencyFormatting.label(14.25, code: model.currencyCode)
        XCTAssertTrue((document.string ?? "").filter { !$0.isWhitespace }.contains(expected.filter { !$0.isWhitespace }))
        let report = try await model.prepareAnnualReportExport(forYearContaining: january)
        defer {
            try? FileManager.default.removeItem(at: report.csvURL)
            try? FileManager.default.removeItem(at: report.pdfURL)
        }
        XCTAssertEqual(report.report.businessMiles, 10, accuracy: 0.001)
        XCTAssertEqual(report.report.businessValue, 7.25, accuracy: 0.001)
    }

    @MainActor
    func testAppModelPreparesMonthlyReportExportFiles() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )
        let start = try XCTUnwrap(Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 5, day: 15, hour: 9)
        ))

        XCTAssertNotNil(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 10,
            origin: "Office",
            destination: "Client",
            classification: .business,
            purpose: "Client",
            notes: "",
            tolls: 0,
            parking: 0
        ))

        let files = try await model.prepareMonthlyReportExport(forMonthContaining: start)

        XCTAssertEqual(files.csvURL.lastPathComponent, "Mileage-2026-05.csv")
        XCTAssertEqual(files.pdfURL.lastPathComponent, "Mileage-2026-05.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.pdfURL.path))
    }

    @MainActor
    func testAppModelPreparesAnnualReportExportFiles() async throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )
        let calendar = Calendar(identifier: .gregorian)
        let february = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 2, day: 10, hour: 9)
        ))
        let may = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 5, day: 15, hour: 9)
        ))

        for (start, destination) in [(february, "Gallery"), (may, "Client")] {
            XCTAssertNotNil(model.createManualTrip(
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                distanceMiles: 10,
                origin: "Office",
                destination: destination,
                classification: .business,
                purpose: destination,
                notes: "",
                tolls: 0,
                parking: 0
            ))
        }

        let files = try await model.prepareAnnualReportExport(forYearContaining: may)

        XCTAssertEqual(files.csvURL.lastPathComponent, "Mileage-2026.csv")
        XCTAssertEqual(files.pdfURL.lastPathComponent, "Mileage-2026.pdf")
        let csv = try String(contentsOf: files.csvURL, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("Trip ID,Report Month,Start Date,Start Time,End Date,End Time,Time Zone"), csv)
        XCTAssertEqual(csv.components(separatedBy: ",2026-02,").count - 1, 1, csv)
        XCTAssertEqual(csv.components(separatedBy: ",2026-05,").count - 1, 1, csv)
        XCTAssertFalse(csv.contains(",2026-03,"), csv)
        XCTAssertEqual(files.report.includedTripIDs.count, 2)
    }
}

private func validPDFData() throws -> Data {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// The simulator doesn't implement Data Protection and records no
/// `.protectionKey` attribute, so the class check only runs on device.
func assertFileProtectionComplete(
    at url: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #if targetEnvironment(simulator)
    XCTAssertNotNil(attributes[.size], file: file, line: line)
    #else
    XCTAssertEqual(
        attributes[.protectionKey] as? FileProtectionType,
        .complete,
        file: file,
        line: line
    )
    #endif
}
