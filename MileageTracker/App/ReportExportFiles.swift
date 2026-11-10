import AppCore
import Foundation

struct MileageReportExportFiles {
    var report: ReportSnapshot
    var csvURL: URL
    var pdfURL: URL
    var rateFreshnessMessage: String? = nil
}

enum MileageReportExportFormat {
    case csv
    case pdf
    case quickBooksCSV

    var csvFormat: ReportCSVFormat {
        self == .quickBooksCSV ? .quickBooks : .canonical
    }

    func url(from report: MileageReportExportFiles) -> URL {
        switch self {
        case .csv, .quickBooksCSV:
            report.csvURL
        case .pdf:
            report.pdfURL
        }
    }
}

enum MileageReportExportError: LocalizedError {
    case failedToGenerateReport
    case noBusinessTrips

    var errorDescription: String? {
        switch self {
        case .failedToGenerateReport:
            String(localized: "The report could not be generated.")
        case .noBusinessTrips:
            String(localized: "There are no business trips with a purpose to export for this period and vehicle.")
        }
    }
}

enum MileageReportPeriod {
    case month
    case year
}

enum MileageReportFileWriter {
    static func write(
        report: ReportSnapshot,
        period: MileageReportPeriod = .month,
        logicalPeriodID: String? = nil,
        csvFormat: ReportCSVFormat = .canonical
    ) throws -> MileageReportExportFiles {
        try ReportPDFValidator.validate(report.pdfData)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileageReports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaultPeriodID: String
        switch period {
        case .month:
            defaultPeriodID = ReportExportNaming.monthLogicalPeriodID(containing: report.startDate)
        case .year:
            defaultPeriodID = ReportExportNaming.yearLogicalPeriodID(containing: report.startDate)
        }
        let resolvedPeriodID = logicalPeriodID ?? defaultPeriodID
        let baseFilename = ReportExportNaming.baseFilename(
            logicalPeriodID: resolvedPeriodID,
            reportStartDate: report.startDate,
            reportEndDate: report.endDate
        )
        let csvSuffix = csvFormat == .quickBooks ? "-QuickBooks" : ""
        let csvURL = directory.appendingPathComponent("\(baseFilename)\(csvSuffix).csv")
        let pdfURL = directory.appendingPathComponent("\(baseFilename).pdf")

        // Exports only happen from interactive UI flows (device unlocked),
        // so the strictest protection class is safe here.
        try Data(report.csvText.utf8).write(to: csvURL, options: [.atomic, .completeFileProtection])
        try report.pdfData.write(to: pdfURL, options: [.atomic, .completeFileProtection])

        return MileageReportExportFiles(report: report, csvURL: csvURL, pdfURL: pdfURL)
    }

}

enum TripPDFExportFileWriter {
    static func write(trip: TripSummary, pdfData: Data) throws -> URL {
        try ReportPDFValidator.validate(pdfData)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileageTripExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let slug = tripSlug(for: trip.startDate)
        let shortID = String(trip.id.uuidString.prefix(8))
        let pdfURL = directory.appendingPathComponent("Mileage-Trip-\(slug)-\(shortID).pdf")
        try pdfData.write(to: pdfURL, options: [.atomic, .completeFileProtection])
        return pdfURL
    }

    private static func tripSlug(for date: Date) -> String {
        let formatter = DateFormatter()
        // Filenames stay ASCII/Gregorian regardless of device locale or calendar.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }
}
