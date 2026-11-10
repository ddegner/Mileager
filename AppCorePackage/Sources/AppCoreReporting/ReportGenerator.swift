import AppCoreModels
import AppCorePersistence
import CoreGraphics
import Foundation
import MapKit
import PDFKit
import SwiftUI

public enum ReportRenderingError: Error, LocalizedError, Equatable {
    case unableToCreatePDFContext
    case emptyPDF
    case invalidPDF

    public var errorDescription: String? {
        switch self {
        case .unableToCreatePDFContext:
            String(
                localized: "The PDF renderer could not create a document.",
                bundle: .appCoreStrings
            )
        case .emptyPDF:
            String(
                localized: "The PDF renderer produced an empty document.",
                bundle: .appCoreStrings
            )
        case .invalidPDF:
            String(
                localized: "The PDF renderer produced an invalid document.",
                bundle: .appCoreStrings
            )
        }
    }
}

public enum ReportPDFValidator {
    public static func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw ReportRenderingError.emptyPDF
        }
        guard data.starts(with: Data("%PDF".utf8)),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else {
            throw ReportRenderingError.invalidPDF
        }
    }

    /// Inspect the finished pages before handing an export to the save/share UI.
    /// A valid PDF container alone does not prove that its text fits on paper.
    static func validateLayout(_ data: Data, pageCount: Int) throws {
        guard let document = PDFDocument(data: data), document.pageCount == pageCount else {
            throw ReportRenderingError.invalidPDF
        }
        for index in 0..<pageCount {
            guard let page = document.page(at: index),
                  let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReportRenderingError.invalidPDF
            }
            let box = page.bounds(for: .mediaBox)
            let footer = String(localized: "Page \(index + 1) of \(pageCount)", bundle: .appCoreStrings)
            guard text.contains(footer) else { throw ReportRenderingError.invalidPDF }
            for line in page.selection(for: box)?.selectionsByLine() ?? [] {
                guard let value = line.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let bounds = line.bounds(for: page)
                let inFooter = bounds.minY >= box.minY + PDFMetrics.bottomMargin - 1
                    && bounds.maxY <= box.minY + PDFMetrics.bottomMargin + PDFMetrics.footerHeight + 1
                guard bounds.minX >= box.minX + PDFMetrics.margin - 1,
                      bounds.maxX <= box.maxX - PDFMetrics.margin + 1,
                      bounds.maxY <= box.maxY - PDFMetrics.topMargin + 1,
                      inFooter || bounds.minY >= box.minY + PDFMetrics.bodyBottomInset - 1 else {
                    throw ReportRenderingError.invalidPDF
                }
            }
        }
    }

}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum ReportCSVFormat: Sendable {
    case canonical
    /// The US QuickBooks mileage importer, selected as "QuickBooks" in QBO.
    case quickBooks
}

/// Pure report generation: turns current trip, fee, and odometer data into a
/// transient `ReportSnapshot` (PDF, CSV, totals). Nothing is persisted — see
/// ADR 0005; users keep durable copies by exporting the files.
public final class ReportGenerator {
    public init() {}

    @MainActor
    public func makeReport(
        trips: [TripSummary],
        odometerCheckpoints: [OdometerCheckpoint],
        startDate: Date,
        endDate: Date,
        rate: MileageRate,
        rateSchedule: MileageRateSchedule? = nil,
        formatting: ReportFormattingContext = ReportFormattingContext(distanceUnit: .miles, currencyCode: "USD"),
        vehicleNamesByTripID: [UUID: String]? = nil,
        vehicleTitleSuffix: String? = nil,
        calendar: Calendar = .current,
        csvFormat: ReportCSVFormat = .canonical
    ) throws -> ReportSnapshot {
        var formatting = formatting
        formatting.timeZone = calendar.timeZone
        let effectiveRateSchedule = rateSchedule ?? MileageRateSchedule(baseRate: rate)
        let included = trips
            .flatMap { ReportTripAllocation.slices(of: $0, schedule: effectiveRateSchedule, calendar: calendar, currency: formatting.currency) }
            .filter { $0.startDate >= startDate && $0.startDate <= endDate }
            .sorted { $0.startDate < $1.startDate }
        let odometerEstimate = OdometerInterpolator.estimate(
            checkpoints: odometerCheckpoints,
            start: startDate,
            end: endDate
        )

        let businessTrips = included.filter(\.isExportableBusiness)
        let businessMiles = businessTrips.reduce(0) { $0 + $1.miles }
        let amounts = ReportAmounts(trips: businessTrips, schedule: effectiveRateSchedule, calendar: calendar, currency: formatting.currency)
        let businessParking = amounts.parking
        let businessTolls = amounts.tolls
        let value = amounts.mileage
        let csv = makeCSV(
            trips: businessTrips,
            format: csvFormat,
            rateSchedule: effectiveRateSchedule,
            formatting: formatting,
            calendar: calendar,
            vehicleNamesByTripID: vehicleNamesByTripID
        )
        let baseTitle = "Mileage Report \(Self.csvDateFormatter(timeZone: calendar.timeZone).string(from: startDate)) - \(Self.csvDateFormatter(timeZone: calendar.timeZone).string(from: endDate))"
        let title = vehicleTitleSuffix.map { "\(baseTitle) - \($0)" } ?? baseTitle
        let pdf = try MileagePDFBuilder.makePDF(
            startDate: startDate,
            endDate: endDate,
            trips: businessTrips,
            odometerEstimate: odometerEstimate,
            businessMiles: businessMiles,
            businessParking: businessParking,
            businessTolls: businessTolls,
            businessValue: value,
            rateSchedule: effectiveRateSchedule,
            calendar: calendar,
            formatting: formatting,
            audit: ReportAuditSummary(trips: included),
            vehicleNamesByTripID: vehicleNamesByTripID,
            vehicleTitleSuffix: vehicleTitleSuffix
        )

        return ReportSnapshot(
            startDate: startDate,
            endDate: endDate,
            title: title,
            csvText: csv,
            pdfData: pdf,
            businessMiles: businessMiles,
            businessValue: value,
            rateCentsPerMile: rate.converted(to: .miles).amountPerUnit * 100,
            includedTripIDs: ReportTripAllocation.sourceIDs(in: businessTrips)
        )
    }

    /// Annual (multi-month) report: same totals math as `makeReport`, plus a
    /// per-month summary up front and the trip table sectioned by month. Month
    /// lines use the identical per-trip rounding as standalone monthly reports
    /// so the two always agree.
    @MainActor
    public func makeAnnualReport(
        trips: [TripSummary],
        odometerCheckpoints: [OdometerCheckpoint],
        startDate: Date,
        endDate: Date,
        rate: MileageRate,
        rateSchedule: MileageRateSchedule? = nil,
        formatting: ReportFormattingContext = ReportFormattingContext(distanceUnit: .miles, currencyCode: "USD"),
        calendar: Calendar = .current,
        vehicleNamesByTripID: [UUID: String]? = nil,
        vehicleTitleSuffix: String? = nil,
        csvFormat: ReportCSVFormat = .canonical
    ) throws -> ReportSnapshot {
        var formatting = formatting
        formatting.timeZone = calendar.timeZone
        let effectiveRateSchedule = rateSchedule ?? MileageRateSchedule(baseRate: rate)
        let included = trips
            .flatMap { ReportTripAllocation.slices(of: $0, schedule: effectiveRateSchedule, calendar: calendar, currency: formatting.currency) }
            .filter { $0.startDate >= startDate && $0.startDate <= endDate }
            .sorted { $0.startDate < $1.startDate }
        let odometerEstimate = OdometerInterpolator.estimate(
            checkpoints: odometerCheckpoints,
            start: startDate,
            end: endDate
        )

        let businessTrips = included.filter(\.isExportableBusiness)
        let monthSections = AnnualReportBreakdown.monthSections(
            businessTrips: businessTrips,
            unit: formatting.distanceUnit,
            rateSchedule: effectiveRateSchedule,
            calendar: calendar,
            currencyCode: formatting.currencyCode
        )
        let businessMiles = businessTrips.reduce(0) { $0 + $1.miles }
        let amounts = ReportAmounts(trips: businessTrips, schedule: effectiveRateSchedule, calendar: calendar, currency: formatting.currency)
        let businessParking = amounts.parking
        let businessTolls = amounts.tolls
        let value = amounts.mileage
        let csv = makeCSV(
            trips: businessTrips,
            format: csvFormat,
            rateSchedule: effectiveRateSchedule,
            formatting: formatting,
            calendar: calendar,
            vehicleNamesByTripID: vehicleNamesByTripID
        )
        let baseTitle = "Mileage Report \(Self.csvDateFormatter(timeZone: calendar.timeZone).string(from: startDate)) - \(Self.csvDateFormatter(timeZone: calendar.timeZone).string(from: endDate))"
        let title = vehicleTitleSuffix.map { "\(baseTitle) - \($0)" } ?? baseTitle
        let pdf = try MileagePDFBuilder.makeAnnualPDF(
            startDate: startDate,
            endDate: endDate,
            monthSections: monthSections,
            calendar: calendar,
            odometerEstimate: odometerEstimate,
            businessMiles: businessMiles,
            businessParking: businessParking,
            businessTolls: businessTolls,
            businessValue: value,
            rateSchedule: effectiveRateSchedule,
            formatting: formatting,
            audit: ReportAuditSummary(trips: included),
            vehicleNamesByTripID: vehicleNamesByTripID,
            vehicleTitleSuffix: vehicleTitleSuffix
        )

        return ReportSnapshot(
            startDate: startDate,
            endDate: endDate,
            title: title,
            csvText: csv,
            pdfData: pdf,
            businessMiles: businessMiles,
            businessValue: value,
            rateCentsPerMile: rate.converted(to: .miles).amountPerUnit * 100,
            includedTripIDs: ReportTripAllocation.sourceIDs(in: businessTrips)
        )
    }

    @MainActor
    public func makeTripPDF(
        for trip: TripSummary,
        rate: MileageRate,
        generatedAt: Date = Date(),
        formatting: ReportFormattingContext = ReportFormattingContext(distanceUnit: .miles, currencyCode: "USD"),
        rateSchedule: MileageRateSchedule? = nil,
        calendar: Calendar = .current
    ) async throws -> Data {
        var formatting = formatting
        formatting.timeZone = calendar.timeZone
        return try await MileagePDFBuilder.makeTripPDF(for: trip, rateSchedule: rateSchedule ?? MileageRateSchedule(baseRate: rate), generatedAt: generatedAt, formatting: formatting, calendar: calendar)
    }

    private func makeCSV(
        trips: [TripSummary],
        format: ReportCSVFormat,
        rateSchedule: MileageRateSchedule,
        formatting: ReportFormattingContext,
        calendar: Calendar,
        vehicleNamesByTripID: [UUID: String]? = nil
    ) -> String {
        if format == .quickBooks {
            return makeQuickBooksCSV(trips: trips, calendar: calendar, vehicleNamesByTripID: vehicleNamesByTripID)
        }
        let dateFormatter = Self.csvDateFormatter(timeZone: calendar.timeZone)
        let timeFormatter = Self.csvTimeFormatter(timeZone: calendar.timeZone)
        let monthFormatter = Self.csvMonthFormatter(timeZone: calendar.timeZone)
        let rows = [tripTableHeader()] + trips.map { trip in
            let rate = rateSchedule.rate(on: trip.startDate, calendar: calendar)
            return tripTableRow(
                trip: trip,
                rate: rate,
                formatting: formatting,
                vehicleNamesByTripID: vehicleNamesByTripID,
                timeZone: calendar.timeZone,
                dateFormatter: dateFormatter,
                timeFormatter: timeFormatter,
                monthFormatter: monthFormatter
            )
        }
        return Self.joinedCSV(rows)
    }

    /// QBO imports its own mileage-download schema, not a bank-transaction CSV.
    /// Keep these English headers, US dates and miles independent of app locale
    /// and distance preferences. See docs/quickbooks-mileage-export.md for sources.
    private func makeQuickBooksCSV(
        trips: [TripSummary],
        calendar: Calendar,
        vehicleNamesByTripID: [UUID: String]?
    ) -> String {
        let dateFormatter = Self.csvDateFormatter(timeZone: calendar.timeZone)
        dateFormatter.dateFormat = "MM/dd/yyyy"
        let header = [
            "Date", "Type", "Trip Purpose", "Vehicle", "Start Address", "End Address",
            "Distance", "Deduction", "Logging Method"
        ]
        let rows = [header] + trips.map { trip in
            [
                dateFormatter.string(from: trip.startDate),
                "Business",
                trip.businessPurpose ?? "",
                vehicleNamesByTripID?[trip.id] ?? "",
                endpointText(address: trip.startAddress, coordinate: trip.startCoordinate),
                endpointText(address: trip.endAddress, coordinate: trip.endCoordinate),
                DistanceFormatting.csvValue(meters: trip.reportableDistanceMeters, unit: .miles),
                // This transfers mileage, not the app's custom reimbursement
                // rate/currency or fees. Zero is the supported placeholder in
                // the published import example; review deductions inside QBO.
                "0",
                // These are file-imported records, regardless of how Mileager
                // originally captured or merged them.
                "Manual"
            ]
        }
        return Self.joinedCSV(rows)
    }

    /// Stable, flat schema shared by monthly and annual canonical exports.
    /// Platform-specific bookkeeping CSVs can transform these same values
    /// without having to parse report headings, blank lines, or subtotal rows.
    private func tripTableHeader() -> [String] {
        [
            "Trip ID", "Report Month", "Start Date", "Start Time", "End Date", "End Time", "Time Zone",
            "Duration Minutes", "Origin", "Destination", "Reported Distance", "Distance Unit",
            "Original Recorded Distance", "Distance Adjusted", "Classification", "Vehicle", "Entry Method",
            "Business Purpose", "Notes", "Mileage Rate", "Currency", "Mileage Amount", "Tolls", "Parking",
            "Total Amount", "Leg Count", "Stop Count", "Leg Details"
        ]
    }

    private func tripTableRow(
        trip: TripSummary,
        rate: MileageRate,
        formatting: ReportFormattingContext,
        vehicleNamesByTripID: [UUID: String]?,
        timeZone: TimeZone,
        dateFormatter: DateFormatter,
        timeFormatter: DateFormatter,
        monthFormatter: DateFormatter
    ) -> [String] {
        let unit = formatting.distanceUnit
        let mileageAmount = formatting.currency.rounded(trip.reportableDistanceMeters * rate.amountPerMeter)
        let totalAmount = mileageAmount + trip.tollsAmount + trip.parkingAmount
        return [
            trip.id.uuidString.lowercased(),
            monthFormatter.string(from: trip.startDate),
            dateFormatter.string(from: trip.startDate),
            timeFormatter.string(from: trip.startDate),
            dateFormatter.string(from: trip.endDate),
            timeFormatter.string(from: trip.endDate),
            timeZone.identifier,
            Self.csvTwoPlaces(trip.durationSeconds / 60),
            endpointText(address: trip.startAddress, coordinate: trip.startCoordinate),
            endpointText(address: trip.endAddress, coordinate: trip.endCoordinate),
            DistanceFormatting.csvValue(meters: trip.reportableDistanceMeters, unit: unit),
            Self.csvDistanceUnit(unit),
            DistanceFormatting.csvValue(meters: trip.distanceMeters, unit: unit),
            trip.manualDistanceOverrideMeters == nil ? "No" : "Yes",
            Self.csvClassification(trip.classification),
            vehicleNamesByTripID?[trip.id] ?? "",
            Self.csvEntryMethod(trip),
            trip.businessPurpose ?? "",
            trip.notes ?? "",
            String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                rate.converted(to: unit).amountPerUnit
            ),
            formatting.currencyCode,
            formatting.currency.csv(mileageAmount),
            formatting.currency.csv(trip.tollsAmount),
            formatting.currency.csv(trip.parkingAmount),
            formatting.currency.csv(totalAmount),
            "\(trip.effectiveLegs.count)",
            "\(trip.stops.count)",
            legDetails(
                for: trip,
                formatting: formatting,
                dateFormatter: dateFormatter,
                timeFormatter: timeFormatter
            )
        ]
    }

    /// All 2-dp CSV number cells (money and pre-rounded distances) format
    /// through here so the export stays POSIX-stable and machine-parseable
    /// regardless of the user's locale.
    private static func csvTwoPlaces(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func joinedCSV(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map(Self.escapeCSV).joined(separator: ",")
        }
        .joined(separator: "\n")
    }

    private func endpointText(address: String?, coordinate: Coordinate?) -> String {
        AddressDisplayFormatter.endpointText(address: address, coordinate: coordinate, unknownLabel: "")
    }

    private func legDetails(
        for trip: TripSummary,
        formatting: ReportFormattingContext,
        dateFormatter: DateFormatter,
        timeFormatter: DateFormatter
    ) -> String {
        guard trip.effectiveLegs.count > 1 else { return "" }
        let unitSymbol = Self.csvDistanceUnit(formatting.distanceUnit)
        return trip.effectiveLegs.enumerated().map { index, leg in
            let origin = endpointText(address: leg.startAddress, coordinate: leg.startCoordinate)
            let destination = endpointText(address: leg.endAddress, coordinate: leg.endCoordinate)
            let start = "\(dateFormatter.string(from: leg.startDate)) \(timeFormatter.string(from: leg.startDate))"
            let end = "\(dateFormatter.string(from: leg.endDate)) \(timeFormatter.string(from: leg.endDate))"
            let distance = "\(DistanceFormatting.csvValue(meters: leg.distanceMeters, unit: formatting.distanceUnit)) \(unitSymbol)"
            let stop = leg.stopDurationAfterSeconds.map { " stop \(Self.csvDurationMinutes($0)) min" } ?? ""
            return "Leg \(index + 1): \(start) to \(end) | \(origin) to \(destination) | \(distance)\(stop)"
        }
        .joined(separator: "\n")
    }

    private static func csvDurationMinutes(_ seconds: Double) -> String {
        let minutes = seconds / 60
        return minutes.rounded() == minutes
            ? String(Int(minutes))
            : csvTwoPlaces(minutes)
    }

    private static func csvDistanceUnit(_ unit: DistanceUnit) -> String {
        switch unit {
        case .miles: "mi"
        case .kilometers: "km"
        }
    }

    private static func csvClassification(_ classification: TripClassification?) -> String {
        switch classification {
        case .business: "Business"
        case .personal: "Personal"
        case .notADrive: "Not a Drive"
        case nil: "Unreviewed"
        }
    }

    private static func csvEntryMethod(_ trip: TripSummary) -> String {
        if trip.isMerged { return "Merged" }
        switch trip.captureSource {
        case "automatic": return "Automatic"
        case "manual": return "Manual"
        default:
            return trip.captureSource.isEmpty
                ? "Unknown"
                : trip.captureSource.prefix(1).uppercased() + trip.captureSource.dropFirst()
        }
    }

    private static func escapeCSV(_ value: String) -> String {
        let firstNonSpace = value.drop(while: { $0 == " " }).first
        let spreadsheetFormulaPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        let protectedValue = firstNonSpace.map(spreadsheetFormulaPrefixes.contains) == true
            ? "'\(value)"
            : value
        let needsEscaping = protectedValue.contains(",")
            || protectedValue.contains("\"")
            || protectedValue.contains("\n")
            || protectedValue.contains("\r")
        let escaped = protectedValue.replacingOccurrences(of: "\"", with: "\"\"")
        return needsEscaping ? "\"\(escaped)\"" : escaped
    }

    private static func csvMonthFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }

    private static func csvDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func csvTimeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
}

enum MileagePDFBuilder {
    @MainActor
    static func makePDF(
        startDate: Date,
        endDate: Date,
        trips: [TripSummary],
        odometerEstimate: OdometerPeriodEstimate,
        businessMiles: Double,
        businessParking: Double,
        businessTolls: Double,
        businessValue: Double,
        rateSchedule: MileageRateSchedule,
        calendar: Calendar,
        formatting: ReportFormattingContext,
        audit: ReportAuditSummary,
        vehicleNamesByTripID: [UUID: String]?,
        vehicleTitleSuffix: String?
    ) throws -> Data {
        let document = MonthlyReportPDFDocument(
            startDate: startDate,
            endDate: endDate,
            trips: trips,
            odometerEstimate: odometerEstimate,
            businessMiles: businessMiles,
            businessParking: businessParking,
            businessTolls: businessTolls,
            businessValue: businessValue,
            rateSchedule: rateSchedule,
            calendar: calendar,
            formatting: formatting,
            audit: audit,
            vehicleNamesByTripID: vehicleNamesByTripID,
            vehicleTitleSuffix: vehicleTitleSuffix
        )

        return try NativePDFRenderer.render(pages: document.pages.map { AnyView(MonthlyReportPDFPage(model: $0)) })
    }

    @MainActor
    static func makeAnnualPDF(
        startDate: Date,
        endDate: Date,
        monthSections: [ReportMonthSection],
        calendar: Calendar,
        odometerEstimate: OdometerPeriodEstimate,
        businessMiles: Double,
        businessParking: Double,
        businessTolls: Double,
        businessValue: Double,
        rateSchedule: MileageRateSchedule,
        formatting: ReportFormattingContext,
        audit: ReportAuditSummary,
        vehicleNamesByTripID: [UUID: String]?,
        vehicleTitleSuffix: String?
    ) throws -> Data {
        let document = AnnualReportPDFDocument(
            startDate: startDate,
            endDate: endDate,
            monthSections: monthSections,
            calendar: calendar,
            odometerEstimate: odometerEstimate,
            businessMiles: businessMiles,
            businessParking: businessParking,
            businessTolls: businessTolls,
            businessValue: businessValue,
            rateSchedule: rateSchedule,
            formatting: formatting,
            audit: audit,
            vehicleNamesByTripID: vehicleNamesByTripID,
            vehicleTitleSuffix: vehicleTitleSuffix
        )
        return try NativePDFRenderer.render(pages: document.pages)
    }

    @MainActor
    static func makeTripPDF(
        for trip: TripSummary,
        rateSchedule: MileageRateSchedule,
        generatedAt: Date,
        formatting: ReportFormattingContext,
        calendar: Calendar
    ) async throws -> Data {
        let routeMap = await PDFRouteMapRenderer.makeMap(for: trip)
        let document = TripReceiptPDFDocument(trip: trip, rateSchedule: rateSchedule, generatedAt: generatedAt, routeMap: routeMap, formatting: formatting, calendar: calendar)
        return try NativePDFRenderer.render(pages: document.pages)
    }

}

/// A mutually exclusive accounting of every record in the requested period.
/// Business trips missing a purpose stay in `needsReview` instead of appearing
/// in the exportable-business count, so the coverage strip cannot imply that
/// an incomplete report is ready.
struct ReportAuditSummary: Equatable, Sendable {
    var businessIncluded: Int
    var personalExcluded: Int
    var needsReview: Int
    var notADrive: Int

    init(trips: [TripSummary]) {
        businessIncluded = 0
        personalExcluded = 0
        needsReview = 0
        notADrive = 0

        var seen: Set<UUID> = []
        for trip in trips where seen.insert(trip.id).inserted {
            if trip.isExportableBusiness {
                businessIncluded += 1
            } else if trip.classification == .personal {
                personalExcluded += 1
            } else if trip.classification == .notADrive {
                notADrive += 1
            } else {
                needsReview += 1
            }
        }
    }

    var recordCount: Int {
        businessIncluded + personalExcluded + needsReview + notADrive
    }
}

private struct ReportVehicleSummary: Identifiable {
    var id: String { name }
    var name: String
    var tripCount: Int
    var distanceMeters: Double
    var mileageValue: Double
    var parking: Double
    var tolls: Double

    var total: Double { mileageValue + parking + tolls }
}

private enum ReportVehicleSummaryBuilder {
    static func make(
        trips: [TripSummary],
        rateSchedule: MileageRateSchedule,
        calendar: Calendar,
        vehicleNamesByTripID: [UUID: String]?,
        vehicleTitleSuffix: String?,
        formatting: ReportFormattingContext
    ) -> [ReportVehicleSummary] {
        guard vehicleTitleSuffix != nil || vehicleNamesByTripID != nil else {
            return []
        }

        var summaries: [String: ReportVehicleSummary] = [:]
        var seen: Set<UUID> = []
        for trip in trips {
            let name = vehicleTitleSuffix
                ?? vehicleNamesByTripID?[trip.id]
                ?? String(localized: "No vehicle", bundle: .appCoreStrings)
            let rate = rateSchedule.rate(on: trip.startDate, calendar: calendar)
            var summary = summaries[name] ?? ReportVehicleSummary(
                name: name,
                tripCount: 0,
                distanceMeters: 0,
                mileageValue: 0,
                parking: 0,
                tolls: 0
            )
            if seen.insert(trip.id).inserted { summary.tripCount += 1 }
            summary.distanceMeters += trip.reportableDistanceMeters
            summary.mileageValue += formatting.currency.rounded(
                trip.reportableDistanceMeters * rate.amountPerMeter
            )
            summary.parking += trip.parkingAmount
            summary.tolls += trip.tollsAmount
            summaries[name] = summary
        }

        if trips.isEmpty, let vehicleTitleSuffix {
            summaries[vehicleTitleSuffix] = ReportVehicleSummary(
                name: vehicleTitleSuffix,
                tripCount: 0,
                distanceMeters: 0,
                mileageValue: 0,
                parking: 0,
                tolls: 0
            )
        }

        return summaries.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

fileprivate enum PDFText {
    static func endpointText(address: String?, coordinate: Coordinate?, unknownLabel: String) -> String {
        AddressDisplayFormatter.endpointText(address: address, coordinate: coordinate, unknownLabel: unknownLabel)
    }

    static func compactEndpoint(address: String?, coordinate: Coordinate?, homeState: String?, unknownLabel: String) -> String {
        if let address = nonEmpty(address) {
            return AddressDisplayFormatter.compactAddress(address, omittingState: homeState)
        }
        return AddressDisplayFormatter.coordinateLabel(coordinate) ?? unknownLabel
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The state most trip endpoints fall in; the monthly table omits it so
    /// only out-of-state locations carry a state code.
    static func homeState(for trips: [TripSummary]) -> String? {
        var counts: [String: Int] = [:]
        for trip in trips {
            for address in [trip.startAddress, trip.endAddress] {
                guard let address = nonEmpty(address),
                      let code = AddressDisplayFormatter.parts(of: address).stateCode else { continue }
                counts[code, default: 0] += 1
            }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key
    }

    /// One-line itinerary for the monthly table: "22 Example St → Wilmington →
    /// Andover → 26 Example St, Cambridge". Stops in a different city collapse
    /// to the city name; the full detail lives in the per-leg lines below it.
    static func routeHeadline(for trip: TripSummary, homeState: String?) -> String {
        let originParts = nonEmpty(trip.startAddress).map(AddressDisplayFormatter.parts(of:))
        let destinationParts = nonEmpty(trip.endAddress).map(AddressDisplayFormatter.parts(of:))
        let origin = compactEndpoint(address: trip.startAddress, coordinate: trip.startCoordinate, homeState: homeState, unknownLabel: unknownOriginLabel)
        let destination = compactEndpoint(address: trip.endAddress, coordinate: trip.endCoordinate, homeState: homeState, unknownLabel: unknownDestinationLabel)

        let anchorCities = [originParts?.city, destinationParts?.city].compactMap { $0 }
        var vias: [String] = []
        for stop in trip.stops {
            guard let label = viaLabel(for: stop, anchorCities: anchorCities, homeState: homeState) else { continue }
            if label != vias.last {
                vias.append(label)
            }
        }

        if vias.isEmpty, origin.caseInsensitiveCompare(destination) == .orderedSame {
            return String(localized: "Round trip from \(origin)", bundle: .appCoreStrings)
        }

        var originLabel = origin
        if let originCity = originParts?.city,
           let destinationCity = destinationParts?.city,
           originCity.caseInsensitiveCompare(destinationCity) == .orderedSame,
           let originPrimary = originParts?.primary {
            originLabel = originPrimary
        }
        return ([originLabel] + vias + [destination]).joined(separator: " → ")
    }

    /// Secondary detail lines for multi-leg trips, one per leg:
    /// "1.  9:21 – 9:57 AM · 22 Example St, Cambridge → 206 Sample St, Wilmington · 17.72 mi · stopped 25m"
    static func routeLegLines(for trip: TripSummary, homeState: String?, formatting: ReportFormattingContext) -> String? {
        let legs = trip.effectiveLegs
        guard legs.count > 1 else { return nil }
        return legs.enumerated().map { index, leg in
            let origin = compactEndpoint(address: leg.startAddress, coordinate: leg.startCoordinate, homeState: homeState, unknownLabel: unknownOriginLabel)
            let destination = compactEndpoint(address: leg.endAddress, coordinate: leg.endCoordinate, homeState: homeState, unknownLabel: unknownDestinationLabel)
            return legLine(index: index, leg: leg, origin: origin, destination: destination, formatting: formatting)
        }
        .joined(separator: "\n")
    }

    static func receiptLegs(_ trip: TripSummary, formatting: ReportFormattingContext) -> [ReceiptLegContent] {
        guard trip.effectiveLegs.count > 1 else { return [] }
        let date = DateFormatter()
        date.locale = formatting.locale
        date.timeZone = formatting.timeZone
        date.dateStyle = .medium
        return trip.effectiveLegs.enumerated().map { index, leg in
            let time = timeRangeFormatter(locale: formatting.locale, timeZone: formatting.timeZone)
                .string(from: leg.startDate, to: leg.endDate)
            let heading = "\(index + 1). \(date.string(from: leg.startDate)) · \(time)"
            let origin = endpointText(address: leg.startAddress, coordinate: leg.startCoordinate, unknownLabel: unknownOriginLabel)
            let destination = endpointText(address: leg.endAddress, coordinate: leg.endCoordinate, unknownLabel: unknownDestinationLabel)
            var detail = "\(distanceValueText(meters: leg.distanceMeters, formatting: formatting)) \(DistanceFormatting.unitSymbol(formatting.distanceUnit, locale: formatting.locale))"
            if let stop = leg.stopDurationAfterSeconds, stop >= 60 {
                detail += " · " + String(localized: "stopped \(durationText(stop))", bundle: .appCoreStrings)
            }
            return ReceiptLegContent(heading: heading, route: "\(origin) → \(destination)", detail: detail)
        }
    }

    static var unknownOriginLabel: String {
        String(localized: "Unknown origin", bundle: .appCoreStrings)
    }

    static var unknownDestinationLabel: String {
        String(localized: "Unknown destination", bundle: .appCoreStrings)
    }

    /// Distance in the display unit for human-facing PDF text, e.g. "17.72".
    static func distanceValueText(meters: Double, formatting: ReportFormattingContext, fractionDigits: Int = 2) -> String {
        DistanceConversion.value(meters: meters, in: formatting.distanceUnit)
            .formatted(
                .number.precision(.fractionLength(fractionDigits))
                    .grouping(.never)
                    .locale(formatting.locale)
            )
    }

    static func rateText(_ rate: MileageRate, formatting: ReportFormattingContext) -> String {
        CurrencyFormatting.rateText(
            rate,
            code: formatting.currencyCode,
            unit: formatting.distanceUnit,
            locale: formatting.locale
        )
    }

    private static func legLine(index: Int, leg: TripDisplayLeg, origin: String, destination: String, formatting: ReportFormattingContext) -> String {
        // Non-breaking spaces keep atomic phrases ("9:21 – 9:57 AM", "17.72 mi",
        // "stopped 2h 10m") from wrapping mid-phrase in narrow table cells.
        let time = timeRangeFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: leg.startDate, to: leg.endDate)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
        let distance = "\(distanceValueText(meters: leg.distanceMeters, formatting: formatting))\u{00A0}\(DistanceFormatting.unitSymbol(formatting.distanceUnit, locale: formatting.locale))"
        var line = "\(index + 1). \(time) · \(origin) → \(destination) · \(distance)"
        if let stop = leg.stopDurationAfterSeconds, stop >= 60 {
            let stopped = String(localized: "stopped \(durationText(stop))", bundle: .appCoreStrings)
            line += " · \(stopped.replacingOccurrences(of: " ", with: "\u{00A0}"))"
        }
        return line
    }

    private static func viaLabel(for stop: TripStop, anchorCities: [String], homeState: String?) -> String? {
        guard let address = nonEmpty(stop.address) else {
            return AddressDisplayFormatter.coordinateLabel(stop.coordinate)
        }
        let parts = AddressDisplayFormatter.parts(of: address)
        if let city = parts.city,
           !anchorCities.contains(where: { $0.caseInsensitiveCompare(city) == .orderedSame }) {
            if let state = parts.stateCode, state.caseInsensitiveCompare(homeState ?? "") != .orderedSame {
                return "\(city), \(state)"
            }
            return city
        }
        return parts.primary ?? parts.city
    }

    private static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes)m", bundle: .appCoreStrings) }
        let hours = minutes / 60
        let remaining = minutes % 60
        return remaining == 0
            ? String(localized: "\(hours)h", bundle: .appCoreStrings)
            : String(localized: "\(hours)h \(remaining)m", bundle: .appCoreStrings)
    }

    static func timeRangeFormatter(locale: Locale, timeZone: TimeZone) -> DateIntervalFormatter {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}

private enum PDFTextLayout {
    static func wrappedLineCount(_ value: String, width: CGFloat, fontSize: CGFloat, horizontalPadding: CGFloat = 0) -> Int {
        lines(value, width: width - horizontalPadding, fontSize: fontSize).count
    }

    static func wrappedText(_ value: String, width: CGFloat, fontSize: CGFloat, horizontalPadding: CGFloat = 0) -> String {
        lines(value, width: width - horizontalPadding, fontSize: fontSize).joined(separator: "\n")
    }

    static func paginatedText(
        _ value: String, width: CGFloat, fontSize: CGFloat, firstPageLineCapacity: Int,
        continuationWidth: CGFloat, continuationFontSize: CGFloat, continuationLineCapacity: Int
    ) -> [String] {
        let firstLines = lines(value, width: width, fontSize: fontSize)
        let firstCount = min(max(0, firstPageLineCapacity), firstLines.count)
        var result = [firstLines.prefix(firstCount).joined(separator: "\n")]
        let remainder = firstLines.dropFirst(firstCount).joined(separator: "\n")
        if firstCount < firstLines.count {
            let rest = lines(remainder, width: continuationWidth, fontSize: continuationFontSize)
            let capacity = max(1, continuationLineCapacity)
            for offset in stride(from: 0, to: rest.count, by: capacity) {
                result.append(rest[offset..<min(offset + capacity, rest.count)].joined(separator: "\n"))
            }
        }
        return result
    }

    /// Measure glyphs as well as imposing a conservative character budget.
    /// Wide glyphs and long unbroken words cannot secretly wrap into extra
    /// lines after pagination has already assigned their height.
    private static func lines(_ value: String, width: CGFloat, fontSize: CGFloat) -> [String] {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        #else
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        #endif
        let maxWidth = max(1, width - 2)
        let maxCharacters = max(1, Int(maxWidth / (fontSize * 0.56)))
        func fits(_ text: String) -> Bool {
            text.count <= maxCharacters && (text as NSString).size(withAttributes: [.font: font]).width <= maxWidth
        }
        var result: [String] = []
        for paragraph in value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let words = paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if words.isEmpty { result.append(""); continue }
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if fits(candidate) { current = candidate; continue }
                if !current.isEmpty { result.append(current); current = "" }
                // Split by Character, never by a UTF-16 code unit, so composed
                // characters survive even when a word spans multiple pages.
                for character in word {
                    let next = current + String(character)
                    if !current.isEmpty && !fits(next) {
                        result.append(current)
                        current = ""
                    }
                    current.append(character)
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result.isEmpty ? [""] : result
    }
}

private enum NativePDFRenderer {
    static let pageSize = CGSize(width: 612, height: 792)

    @MainActor
    static func render(pages: [AnyView]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ReportRenderingError.unableToCreatePDFContext
        }

        for page in pages {
            context.beginPDFPage(nil)
            let renderer = ImageRenderer(content: page.frame(width: pageSize.width, height: pageSize.height))
            renderer.proposedSize = ProposedViewSize(width: pageSize.width, height: pageSize.height)
            renderer.scale = 1
            renderer.render { _, render in
                render(context)
            }
            context.endPDFPage()
        }

        context.closePDF()
        let rendered = data as Data
        try ReportPDFValidator.validate(rendered)
        try ReportPDFValidator.validateLayout(rendered, pageCount: pages.count)
        return rendered
    }
}

private struct PDFPalette {
    static let paper = Color(red: 0.995, green: 0.996, blue: 0.998)
    static let text = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let muted = Color(red: 0.38, green: 0.40, blue: 0.44)
    static let line = Color(red: 0.80, green: 0.82, blue: 0.86)
    // The report carries the same three semantic colors as the app: orange for
    // Mileager identity, green for included business mileage, and red for
    // personal/excluded or unresolved records.
    static let brand = Color(red: 0.95, green: 0.44, blue: 0.13)
    static let business = Color(red: 0.00, green: 0.55, blue: 0.30)
    static let personal = Color(red: 0.85, green: 0.14, blue: 0.15)
    static let brandWash = Color(red: 1.00, green: 0.95, blue: 0.91)
    static let businessWash = Color(red: 0.92, green: 0.98, blue: 0.95)
    static let personalWash = Color(red: 0.99, green: 0.93, blue: 0.93)
    static let panel = Color(red: 0.94, green: 0.96, blue: 0.95)
    static let stripe = Color(red: 0.970, green: 0.978, blue: 0.982)
    static let route = Color(red: 0.00, green: 0.41, blue: 0.72)
    static let start = Color(red: 0.10, green: 0.58, blue: 0.32)
    static let end = Color(red: 0.82, green: 0.20, blue: 0.24)
    static let mapFallback = Color(red: 0.91, green: 0.93, blue: 0.92)
    static let mapRoad = Color(red: 0.78, green: 0.82, blue: 0.82)
}

private struct PDFMetrics {
    static let margin: CGFloat = 42
    static let contentWidth: CGFloat = NativePDFRenderer.pageSize.width - margin * 2
    static let topMargin: CGFloat = 36
    static let bottomMargin: CGFloat = 26
    static let footerHeight: CGFloat = 10
    static let footerGap: CGFloat = 8
    static let bodyBottomInset = bottomMargin + footerHeight + footerGap
    static let bodyHeight = NativePDFRenderer.pageSize.height - topMargin - bodyBottomInset
}

private struct TripReceiptPDFPage: View {
    var trip: TripSummary
    var amounts: ReportAmounts
    var rateDescription: String
    var hasMultipleRates: Bool
    var content: ReceiptPageContent
    var notesOnlyContinuation: Bool
    var generatedAt: Date
    var routeMap: PDFRouteMap
    var formatting: ReportFormattingContext
    var notes: String?
    var pageNumber: Int
    var pageCount: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            PDFPalette.paper

            VStack(alignment: .leading, spacing: 0) {
                header

                Text(content.itinerary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PDFPalette.text)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                HStack(alignment: .top, spacing: 24) {
                    PDFRouteMapView(routeMap: routeMap)
                        .frame(width: 312, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PDFPalette.line, lineWidth: 0.8))

                    paymentPanel
                        .frame(width: PDFMetrics.contentWidth - 312 - 24, height: 220)
                }

                VStack(alignment: .leading, spacing: 10) {
                    PDFSummaryCard(label: String(localized: "Purpose", bundle: .appCoreStrings), value: content.purpose, minHeight: 50)
                    if trip.classification != .business {
                        Text(String(localized: "Classification: \(trip.classification?.displayName ?? String(localized: "Unreviewed", bundle: .appCoreStrings))", bundle: .appCoreStrings))
                            .font(.system(size: 9))
                            .foregroundStyle(PDFPalette.muted)
                    } else if trip.isUnresolved {
                        Text(String(localized: "Needs Review", bundle: .appCoreStrings))
                            .font(.system(size: 9))
                            .foregroundStyle(PDFPalette.personal)
                    }
                    HStack(alignment: .top, spacing: 36) {
                        PDFEndpointColumn(label: String(localized: "Origin", bundle: .appCoreStrings), value: content.origin)
                        PDFEndpointColumn(label: String(localized: "Destination", bundle: .appCoreStrings), value: content.destination)
                    }
                    .padding(.top, 4)
                    if !content.legs.isEmpty {
                        ReceiptLegList(legs: content.legs)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 16)

                if let notes {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Notes", bundle: .appCoreStrings))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(PDFPalette.text)
                        Divider().overlay(PDFPalette.line)
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(PDFPalette.text)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.top, 18)
                }

                Spacer(minLength: 0)
            }
            .frame(
                width: PDFMetrics.contentWidth,
                height: PDFMetrics.bodyHeight,
                alignment: .topLeading
            )
            .clipped()
            .padding(.leading, PDFMetrics.margin)
            .padding(.top, PDFMetrics.topMargin)
            .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height, alignment: .topLeading)

            // Fixed footer band, matching the report pages: body overflow can
            // clip above it, but can never push the footer off the media box.
            footer
                .padding(.horizontal, PDFMetrics.margin)
                .padding(.bottom, PDFMetrics.bottomMargin)
                .frame(
                    width: NativePDFRenderer.pageSize.width,
                    height: NativePDFRenderer.pageSize.height,
                    alignment: .bottomLeading
                )
        }
        .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .center, spacing: 8) {
                    Text(verbatim: "M")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(PDFPalette.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(String(localized: "Trip Receipt", bundle: .appCoreStrings))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(PDFPalette.text)
                }
                Spacer()
                Text(String(localized: "Generated \(Self.dateTimeFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: generatedAt))", bundle: .appCoreStrings))
                    .font(.system(size: 8.5))
                    .foregroundStyle(PDFPalette.muted)
            }
            Text(verbatim: "\(Self.shortDayFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: trip.startDate)) · \(PDFText.timeRangeFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: trip.startDate, to: trip.endDate)) · \(String(localized: "Rate", bundle: .appCoreStrings)) \(rateDescription)")
                .font(.system(size: 10))
                .foregroundStyle(PDFPalette.muted)
        }
        .padding(.bottom, 12)
    }

    // Mirrors ReportPDFSummaryPanel's flat language (brand accent bar, bold
    // hero total, hairline-separated rows) in the receipt's narrow column.
    private var paymentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Total reimbursement", bundle: .appCoreStrings))
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(PDFPalette.muted)
                Text(currency(amounts.total))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                Text(verbatim: distanceAndRate)
                    .font(.system(size: 8.2, weight: .semibold))
                    .foregroundStyle(trip.classification == .business ? PDFPalette.business : PDFPalette.muted)
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(PDFPalette.brand)
                    .frame(width: 4)
            }

            Rectangle()
                .fill(PDFPalette.line)
                .frame(height: 0.6)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 5) {
                paymentRow(String(localized: "Mileage", bundle: .appCoreStrings), currency(amounts.mileage))
                if amounts.tolls > 0 {
                    paymentRow(String(localized: "Tolls", bundle: .appCoreStrings), currency(amounts.tolls))
                }
                if amounts.parking > 0 {
                    paymentRow(String(localized: "Parking", bundle: .appCoreStrings), currency(amounts.parking))
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func paymentRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(PDFPalette.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PDFPalette.text)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line.opacity(0.6)).frame(height: 0.5) }
    }

    private var footer: some View {
        HStack {
            Text(String(localized: "Page \(pageNumber) of \(pageCount)", bundle: .appCoreStrings))
            if pageNumber < pageCount {
                Spacer()
                Text(notesOnlyContinuation
                    ? String(localized: "Notes continue on the next page.", bundle: .appCoreStrings)
                    : String(localized: "Continued", bundle: .appCoreStrings))
            }
            Spacer()
            Text(String(localized: "Trip ID \(String(trip.id.uuidString.prefix(8)))", bundle: .appCoreStrings))
        }
        .font(.system(size: 8))
        .foregroundStyle(PDFPalette.muted)
    }

    private var distanceAndRate: String {
        let distance = "\(PDFText.distanceValueText(meters: trip.reportableDistanceMeters, formatting: formatting)) \(DistanceFormatting.unitSymbol(formatting.distanceUnit, locale: formatting.locale))"
        guard trip.isExportableBusiness else { return distance }
        return distance + (hasMultipleRates ? " · " : " × ") + rateDescription
    }

    private func currency(_ value: Double) -> String {
        CurrencyFormatting.label(value, code: formatting.currencyCode, locale: formatting.locale)
    }

    private static func dateTimeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static func shortDayFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }
}

private struct PDFEndpointColumn: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PDFPalette.muted)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PDFPalette.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: (PDFMetrics.contentWidth - 36) / 2, alignment: .topLeading)
    }
}

private struct ReceiptLegContent {
    var heading: String
    var routeLines: [String]
    var detailLines: [String]
    var continued = false

    static let lineHeight: CGFloat = 14
    static let rowPadding: CGFloat = 20
    var headingLines: [String] {
        Self.wrap(heading + (continued ? " · " + String(localized: "Continued", bundle: .appCoreStrings) : ""), font: 11)
    }
    var height: CGFloat {
        CGFloat(headingLines.count + routeLines.count + detailLines.count) * Self.lineHeight + Self.rowPadding
    }

    init(heading: String, route: String, detail: String) {
        self.heading = heading
        routeLines = Self.wrap(route, font: 10.5)
        detailLines = Self.wrap(detail, font: 10)
    }

    private static func wrap(_ text: String, font: CGFloat) -> [String] {
        PDFTextLayout.wrappedText(text, width: PDFMetrics.contentWidth, fontSize: font).components(separatedBy: "\n")
    }

    static func paginate(_ legs: [Self], firstHeight: CGFloat, continuationHeight: CGFloat) -> [[Self]] {
        var pages: [[Self]] = [[]]
        var remaining = firstHeight
        for leg in legs {
            var pending = leg
            // Ordinary legs move intact. Only a leg longer than a whole page
            // may split, and each portion repeats its identity and date.
            if pending.height > remaining {
                pages.append([])
                remaining = continuationHeight
            }
            while pending.height > remaining {
                let reserved = CGFloat(pending.headingLines.count + pending.detailLines.count) * lineHeight + rowPadding
                let count = max(1, Int((remaining - reserved) / lineHeight))
                var portion = pending
                portion.routeLines = Array(pending.routeLines.prefix(count))
                pages[pages.count - 1].append(portion)
                pending.routeLines = Array(pending.routeLines.dropFirst(count))
                pending.continued = true
                pages.append([])
                remaining = continuationHeight
            }
            pages[pages.count - 1].append(pending)
            remaining -= pending.height
        }
        return pages
    }
}

private struct ReceiptLegList: View {
    var legs: [ReceiptLegContent]
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text(String(localized: "Legs / Stops", bundle: .appCoreStrings))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                    .padding(.bottom, 10)
            }
            ForEach(legs.indices, id: \.self) { index in
                let leg = legs[index]
                VStack(alignment: .leading, spacing: 0) {
                    lines(leg.headingLines, size: 11, weight: .semibold, color: PDFPalette.text)
                        .padding(.bottom, 4)
                    lines(leg.routeLines, size: 10.5, weight: .regular, color: PDFPalette.text)
                        .padding(.bottom, 4)
                    lines(leg.detailLines, size: 10, weight: .medium, color: PDFPalette.muted)
                }
                .padding(.vertical, 6)
                .frame(width: PDFMetrics.contentWidth, height: leg.height, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(PDFPalette.line.opacity(0.6)).frame(height: 0.5)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lines(_ values: [String], size: CGFloat, weight: Font.Weight, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Text(verbatim: values[index])
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                    .fixedSize()
                    .frame(height: ReceiptLegContent.lineHeight, alignment: .leading)
            }
        }
    }
}

private struct ReceiptPageContent {
    var itinerary: String
    var purpose: String
    var origin: String
    var destination: String
    var legs: [ReceiptLegContent]
}

private struct ReceiptContinuation {
    var title: String
    var text: String = ""
    var legs: [ReceiptLegContent] = []
}

private struct TripReceiptPDFDocument {
    var pages: [AnyView]

    init(trip: TripSummary, rateSchedule: MileageRateSchedule, generatedAt: Date, routeMap: PDFRouteMap, formatting: ReportFormattingContext, calendar: Calendar) {
        let slices = ReportTripAllocation.slices(of: trip, schedule: rateSchedule, calendar: calendar, currency: formatting.currency)
        let amounts = ReportAmounts(trips: slices, schedule: rateSchedule, calendar: calendar, currency: formatting.currency)
        let hasMultipleRates = Set(slices.map { rateSchedule.rate(on: $0.startDate, calendar: calendar).amountPerMeter }).count > 1
        let rateDescription = hasMultipleRates
            ? String(localized: "Multiple rates", bundle: .appCoreStrings)
            : PDFText.rateText(rateSchedule.rate(on: trip.startDate, calendar: calendar), formatting: formatting)
        var continuations: [ReceiptContinuation] = []
        let width = PDFMetrics.contentWidth - 28
        func take(_ text: String, title: String, lines: Int, width: CGFloat, font: CGFloat) -> String {
            let chunks = PDFTextLayout.paginatedText(
                text, width: width, fontSize: font, firstPageLineCapacity: lines,
                continuationWidth: PDFMetrics.contentWidth - 28,
                continuationFontSize: 11, continuationLineCapacity: 40
            )
            continuations += chunks.dropFirst().map { ReceiptContinuation(title: title, text: $0) }
            return chunks.first ?? ""
        }
        let itinerary = take(PDFText.routeHeadline(for: trip, homeState: PDFText.homeState(for: [trip])), title: String(localized: "Route and purpose", bundle: .appCoreStrings), lines: 3, width: width, font: 12)
        let purpose = take(PDFText.nonEmpty(trip.businessPurpose) ?? "-", title: String(localized: "Purpose", bundle: .appCoreStrings), lines: 3, width: width, font: 14)
        let endpointWidth = (PDFMetrics.contentWidth - 36) / 2 - 14
        let origin = take(PDFText.endpointText(address: trip.startAddress, coordinate: trip.startCoordinate, unknownLabel: PDFText.unknownOriginLabel), title: String(localized: "Origin", bundle: .appCoreStrings), lines: 3, width: endpointWidth, font: 12)
        let destination = take(PDFText.endpointText(address: trip.endAddress, coordinate: trip.endCoordinate, unknownLabel: PDFText.unknownDestinationLabel), title: String(localized: "Destination", bundle: .appCoreStrings), lines: 3, width: endpointWidth, font: 12)
        func lines(_ text: String) -> CGFloat { CGFloat(text.components(separatedBy: "\n").count) }
        // All first-page fields have bounded, explicitly wrapped lines. Reserve
        // the fixed map and footer first, then spend only the remaining space.
        var used: CGFloat = 56 + lines(itinerary) * 14.5 + 14 + 220 + 16
        used += max(50, 19 + lines(purpose) * 17)
        if trip.isUnresolved || trip.classification != .business { used += 21 }
        used += 37 + max(lines(origin), lines(destination)) * 14.5
        let legPages = ReceiptLegContent.paginate(
            PDFText.receiptLegs(trip, formatting: formatting),
            firstHeight: max(0, PDFMetrics.bodyHeight - used - 48),
            continuationHeight: PDFMetrics.bodyHeight - 72
        )
        let firstLegs = legPages.first ?? []
        if !firstLegs.isEmpty {
            used += 40 + firstLegs.reduce(0) { $0 + $1.height }
        }
        continuations += legPages.dropFirst().map {
            ReceiptContinuation(title: String(localized: "Legs / Stops", bundle: .appCoreStrings), legs: $0)
        }
        let notesOnlyContinuation = continuations.isEmpty
        var notes: String?
        if let text = PDFText.nonEmpty(trip.notes) {
            let capacity = max(0, Int((PDFMetrics.bodyHeight - used - 56 - 18) / 14.5))
            let first = take(text, title: String(localized: "Notes", bundle: .appCoreStrings), lines: capacity, width: width, font: 12)
            if !first.isEmpty { notes = first }
        }
        let pageCount = 1 + continuations.count
        pages = [AnyView(TripReceiptPDFPage(
            trip: trip, amounts: amounts, rateDescription: rateDescription,
            hasMultipleRates: hasMultipleRates,
            content: ReceiptPageContent(itinerary: itinerary, purpose: purpose, origin: origin, destination: destination, legs: firstLegs),
            notesOnlyContinuation: notesOnlyContinuation,
            generatedAt: generatedAt, routeMap: routeMap, formatting: formatting,
            notes: notes, pageNumber: 1, pageCount: pageCount
        ))]
        pages += continuations.enumerated().map { index, section in
            AnyView(TripDetailsContinuationPDFPage(
                title: section.title, notes: section.text, legs: section.legs, tripID: trip.id,
                pageNumber: index + 2, pageCount: pageCount
            ))
        }
    }
}

private struct TripDetailsContinuationPDFPage: View {
    var title: String
    var notes: String
    var legs: [ReceiptLegContent]
    var tripID: UUID
    var pageNumber: Int
    var pageCount: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            PDFPalette.paper

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(verbatim: "M")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(PDFPalette.brand)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(String(localized: "Trip Receipt", bundle: .appCoreStrings))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(PDFPalette.text)
                    }
                    Spacer()
                    Text(String(localized: "Continued", bundle: .appCoreStrings))
                        .font(.system(size: 8.5))
                        .foregroundStyle(PDFPalette.muted)
                }
                .frame(height: 36, alignment: .top)

                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                    .padding(.bottom, 10)

                if legs.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(PDFPalette.text)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    ReceiptLegList(legs: legs, showsTitle: false)
                }

                Spacer(minLength: 0)
            }
            .frame(
                width: PDFMetrics.contentWidth,
                height: PDFMetrics.bodyHeight,
                alignment: .topLeading
            )
            .clipped()
            .padding(.leading, PDFMetrics.margin)
            .padding(.top, PDFMetrics.topMargin)
            .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height, alignment: .topLeading)

            HStack {
                Text(String(localized: "Page \(pageNumber) of \(pageCount)", bundle: .appCoreStrings))
                Spacer()
                Text(String(localized: "Trip ID \(String(tripID.uuidString.prefix(8)))", bundle: .appCoreStrings))
            }
            .font(.system(size: 8))
            .foregroundStyle(PDFPalette.muted)
            .frame(height: PDFMetrics.footerHeight, alignment: .leading)
            .padding(.horizontal, PDFMetrics.margin)
            .padding(.bottom, PDFMetrics.bottomMargin)
            .frame(
                width: NativePDFRenderer.pageSize.width,
                height: NativePDFRenderer.pageSize.height,
                alignment: .bottomLeading
            )
        }
        .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height)
    }
}

private struct PDFSummaryCard: View {
    var label: String
    var value: String
    var minHeight: CGFloat = 78
    var fillsAvailableHeight = false
    var valueFontSize: CGFloat = 14
    var valueWeight: Font.Weight = .bold

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PDFPalette.muted)
            Text(value)
                .font(.system(size: valueFontSize, weight: valueWeight))
                .foregroundStyle(PDFPalette.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: minHeight,
            maxHeight: fillsAvailableHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .fixedSize(horizontal: false, vertical: !fillsAvailableHeight)
    }
}

private struct PDFRouteMap: Sendable {
    var image: CGImage?
    var normalizedPoints: [CGPoint]
    var normalizedSegments: [[CGPoint]]
}

private enum PDFRouteMapRenderer {
    static func makeMap(for trip: TripSummary, size: CGSize = CGSize(width: 600, height: 472)) async -> PDFRouteMap {
        let segments = routeSegments(for: trip)
        let coordinates = segments.flatMap { $0 }
        guard coordinates.count >= 2 else {
            let points = normalizedPoints(for: coordinates)
            return PDFRouteMap(image: nil, normalizedPoints: points, normalizedSegments: points.isEmpty ? [] : [points])
        }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.region = region(for: coordinates)
        options.showsBuildings = false
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let imageSize = snapshot.platformImageSize
            let normalizedSegments = segments.map { segment in
                segment.map { coordinate in
                    let point = snapshot.point(for: CLLocationCoordinate2D(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ))
                    return CGPoint(
                        x: point.x / max(imageSize.width, 1),
                        y: point.y / max(imageSize.height, 1)
                    )
                }
            }
            let points = normalizedSegments.flatMap { $0 }
            return PDFRouteMap(image: snapshot.cgImage, normalizedPoints: points, normalizedSegments: normalizedSegments)
        } catch {
            let normalizedSegments = normalizedSegments(for: segments)
            return PDFRouteMap(image: nil, normalizedPoints: normalizedSegments.flatMap { $0 }, normalizedSegments: normalizedSegments)
        }
    }

    private static func normalizedSegments(for segments: [[Coordinate]]) -> [[CGPoint]] {
        let coordinates = segments.flatMap { $0 }
        guard coordinates.count >= 2 else { return [] }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max() else {
            return []
        }

        let latRange = max(maxLat - minLat, 0.000_001)
        let lonRange = max(maxLon - minLon, 0.000_001)
        return segments.map { segment in
            segment.map { coordinate in
                CGPoint(
                    x: 0.08 + ((coordinate.longitude - minLon) / lonRange) * 0.84,
                    y: 0.92 - ((coordinate.latitude - minLat) / latRange) * 0.84
                )
            }
        }
    }

    private static func normalizedPoints(for coordinates: [Coordinate]) -> [CGPoint] {
        normalizedSegments(for: [coordinates]).flatMap { $0 }
    }

    private static func routeSegments(for trip: TripSummary) -> [[Coordinate]] {
        if let routePolyline = trip.routePolyline,
           let segments = EncodedPolyline.decodeSegments(routePolyline),
           !segments.isEmpty {
            return segments
        }
        let endpoints = [trip.startCoordinate, trip.endCoordinate].compactMap { $0 }
        return endpoints.count >= 2 ? [endpoints] : []
    }

    private static func region(for coordinates: [Coordinate]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.55, 0.018),
                longitudeDelta: max((maxLon - minLon) * 1.55, 0.018)
            )
        )
    }
}

private extension MKMapSnapshotter.Snapshot {
    var cgImage: CGImage? {
        #if canImport(UIKit)
        image.cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        nil
        #endif
    }

    var platformImageSize: CGSize {
        #if canImport(UIKit) || canImport(AppKit)
        image.size
        #else
        .zero
        #endif
    }
}

private struct PDFRouteMapView: View {
    var routeMap: PDFRouteMap

    var body: some View {
        ZStack {
            if let image = routeMap.image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                PDFMapFallbackBackground()
            }

            if routeMap.normalizedPoints.count >= 2 {
                ForEach(Array(routeMap.normalizedSegments.indices), id: \.self) { index in
                    PDFRouteShape(points: routeMap.normalizedSegments[index])
                        .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    PDFRouteShape(points: routeMap.normalizedSegments[index])
                        .stroke(PDFPalette.route, style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                }
                PDFEndpointMarkers(points: routeMap.normalizedPoints)
                PDFStopMarkers(segments: routeMap.normalizedSegments)
            } else {
                Text(String(localized: "No route map available", bundle: .appCoreStrings))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PDFPalette.muted)
            }
        }
        .clipped()
    }
}

private struct PDFStopMarkers: View {
    var segments: [[CGPoint]]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(stopPoints.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(PDFPalette.route, lineWidth: 2))
                        .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                }
            }
        }
    }

    private var stopPoints: [CGPoint] {
        guard segments.count > 1 else { return [] }
        return segments.dropLast().compactMap(\.last)
    }
}

private struct PDFMapFallbackBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PDFPalette.mapFallback
                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    var x = -height
                    while x < width + height {
                        path.move(to: CGPoint(x: x, y: height))
                        path.addLine(to: CGPoint(x: x + height, y: 0))
                        x += 46
                    }
                    var y: CGFloat = 28
                    while y < height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y + 18))
                        y += 44
                    }
                }
                .stroke(PDFPalette.mapRoad, lineWidth: 1)
            }
        }
    }
}

private struct PDFRouteShape: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: actualPoint(first, in: rect))
        for point in points.dropFirst() {
            path.addLine(to: actualPoint(point, in: rect))
        }
        return path
    }

    private func actualPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}

private struct PDFEndpointMarkers: View {
    var points: [CGPoint]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let first = points.first {
                    marker(at: first, in: proxy.size, color: PDFPalette.start)
                }
                if let last = points.last {
                    marker(at: last, in: proxy.size, color: PDFPalette.end)
                }
            }
        }
    }

    private func marker(at point: CGPoint, in size: CGSize, color: Color) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().fill(color).frame(width: 9, height: 9))
            .position(x: point.x * size.width, y: point.y * size.height)
    }
}

private enum MonthlyReportPDFLayout {
    static let dateWidth: CGFloat = 62
    static let routeWidth: CGFloat = 334
    static let purposeWidth: CGFloat = 0
    static let milesWidth: CGFloat = 54
    static let amountWidth: CGFloat = 78
    static let cellHorizontalPadding: CGFloat = 8
    /// Matches `MonthlyReportTableRow`'s 5-point padding on both edges.
    static let rowVerticalPadding: CGFloat = 10
    /// Must stay ≥ the true line height of `mainFontSize` (8.4 pt SF renders
    /// ~10.03 pt). Under-budgeting here accumulates across wrapped route
    /// titles and, with the body hard-clipped above the footer band, slices
    /// the page's last row instead of nudging the footer.
    static let rowLineHeight: CGFloat = 10.1
    static let detailLineHeight: CGFloat = 9.2
    static let mainFontSize: CGFloat = 8.4
    static let detailFontSize: CGFloat = 7.3
    static let detailWidth: CGFloat = PDFMetrics.contentWidth - dateWidth - 12
    static let totalsHeight: CGFloat = 74
    static let monthDividerHeight: CGFloat = 24
    /// The divider renders `monthDividerHeight` plus 2 pt of bottom padding —
    /// pagination must budget the rendered height, not the frame height.
    static let monthDividerEstimatedHeight: CGFloat = monthDividerHeight + 2

    private static let firstHeaderHeight: CGFloat = 58
    private static let continuationHeaderHeight: CGFloat = 36
    private static let odometerHeight: CGFloat = 76
    private static let tableTitleAndHeaderHeight: CGFloat = 44

    static func overviewHeight(vehicleSummaryCount: Int, includesCoverage: Bool) -> CGFloat {
        // Summary panel (94) plus its lower padding (8).
        var height: CGFloat = 102
        if includesCoverage {
            // The strip is 30 points tall. It has 8 points below it when a
            // vehicle table follows, otherwise 14.
            height += vehicleSummaryCount > 1 ? 38 : 44
        }
        if vehicleSummaryCount > 1 {
            // Section heading, table spacing, the lower padding, and two
            // editorial vehicle blocks per row.
            height += 34 + CGFloat((vehicleSummaryCount + 1) / 2) * 60
        }
        return height
    }

    static func rowBudget(
        pageNumber: Int,
        hasOdometer: Bool,
        firstPageOverviewHeight: CGFloat = 0
    ) -> CGFloat {
        // The body ends above a fixed footer band. Keeping these values tied to
        // the page view prevents a full table from pushing the footer outside
        // the media box.
        let contentHeight = PDFMetrics.bodyHeight
        var usedHeight = tableTitleAndHeaderHeight

        if pageNumber == 1 {
            usedHeight += firstHeaderHeight + firstPageOverviewHeight
            if hasOdometer {
                usedHeight += odometerHeight
            }
        } else {
            usedHeight += continuationHeaderHeight
        }

        return max(0, contentHeight - usedHeight)
    }

    static func estimatedRowHeight(
        routeTitle: String,
        purpose: String,
        vehicleName: String?,
        detail: String?,
        feeNoteCount: Int
    ) -> CGFloat {
        let metadata = vehicleName.map { "\(purpose) · \($0)" } ?? purpose
        let routeHeight = CGFloat(lineCount(routeTitle, width: routeWidth)) * rowLineHeight
        let metadataHeight = CGFloat(lineCount(metadata, width: routeWidth, fontSize: 7.3)) * detailLineHeight
        var contentHeight = max(routeHeight + metadataHeight + 2, CGFloat(1 + feeNoteCount) * rowLineHeight)
        if let detail {
            let detailLines = lineCount(detail, width: detailWidth, fontSize: detailFontSize)
            contentHeight += CGFloat(detailLines) * detailLineHeight + 4
        }
        // The date/time cell needs two lines regardless of the content column.
        return max(contentHeight, 2 * rowLineHeight) + rowVerticalPadding
    }

    static func wrappedCellText(_ value: String, width: CGFloat, fontSize: CGFloat = mainFontSize) -> String {
        PDFTextLayout.wrappedText(
            value,
            width: width,
            fontSize: fontSize,
            horizontalPadding: cellHorizontalPadding
        )
    }

    private static func lineCount(_ value: String, width: CGFloat, fontSize: CGFloat = mainFontSize) -> Int {
        PDFTextLayout.wrappedLineCount(
            value,
            width: width,
            fontSize: fontSize,
            horizontalPadding: cellHorizontalPadding
        )
    }
}

private struct MonthlyReportPDFDocument {
    var pages: [MonthlyReportPDFPageModel]

    init(
        startDate: Date,
        endDate: Date,
        trips: [TripSummary],
        odometerEstimate: OdometerPeriodEstimate,
        businessMiles: Double,
        businessParking: Double,
        businessTolls: Double,
        businessValue: Double,
        rateSchedule: MileageRateSchedule,
        calendar: Calendar,
        formatting: ReportFormattingContext,
        audit: ReportAuditSummary,
        vehicleNamesByTripID: [UUID: String]?,
        vehicleTitleSuffix: String?
    ) {
        let vehicleSummaries = ReportVehicleSummaryBuilder.make(
            trips: trips,
            rateSchedule: rateSchedule,
            calendar: calendar,
            vehicleNamesByTripID: vehicleNamesByTripID,
            vehicleTitleSuffix: vehicleTitleSuffix,
            formatting: formatting
        )
        let showsVehicleOnRows = vehicleSummaries.count > 1
        let homeState = PDFText.homeState(for: trips)
        let rows = trips.map {
            let rate = rateSchedule.rate(on: $0.startDate, calendar: calendar)
            return ReportTableRowModel.trip(MonthlyReportRowModel(
                trip: $0,
                rate: rate,
                homeState: homeState,
                formatting: formatting,
                vehicleName: showsVehicleOnRows
                    ? (vehicleNamesByTripID?[$0.id] ?? String(localized: "No vehicle", bundle: .appCoreStrings))
                    : nil
            ))
        }
        let rateDescription = Self.rateDescription(
            for: trips,
            fallbackDate: startDate,
            rateSchedule: rateSchedule,
            calendar: calendar,
            formatting: formatting
        )
        let odometer: OdometerPeriodEstimate? = odometerEstimate == .none ? nil : odometerEstimate
        let overviewHeight = MonthlyReportPDFLayout.overviewHeight(
            vehicleSummaryCount: vehicleSummaries.count,
            includesCoverage: true
        )
        let chunks = ReportTablePagination.paginate(
            rows: rows,
            firstPageNumber: 1,
            hasOdometer: odometer != nil,
            firstPageOverviewHeight: overviewHeight
        )

        // Round each trip's converted distance to the 2 dp shown per row before
        // summing so the displayed total foots to the printed rows.
        // Full-precision `businessMiles` still feeds the business-use-% math.
        let displayedBusinessDistance = trips.reduce(0) {
            $0 + ReportMilesRounding.twoPlaces(DistanceConversion.value(meters: $1.reportableDistanceMeters, in: formatting.distanceUnit))
        }

        let pageCount = chunks.count
        pages = chunks.enumerated().map { index, rows in
            MonthlyReportPDFPageModel(
                startDate: startDate,
                endDate: endDate,
                generatedAt: Date(),
                tripCount: Set(trips.map(\.id)).count,
                businessMiles: businessMiles,
                displayedBusinessDistance: displayedBusinessDistance,
                businessParking: businessParking,
                businessTolls: businessTolls,
                businessValue: businessValue,
                rateDescription: rateDescription,
                formatting: formatting,
                audit: audit,
                vehicleSummaries: vehicleSummaries,
                vehicleScopeTitle: vehicleTitleSuffix
                    ?? (vehicleSummaries.count > 1
                        ? String(localized: "All vehicles", bundle: .appCoreStrings)
                        : vehicleSummaries.first?.name),
                odometer: index == 0 ? odometer : nil,
                rows: rows,
                pageNumber: index + 1,
                pageCount: pageCount
            )
        }
    }

    private static func rateDescription(
        for trips: [TripSummary],
        fallbackDate: Date,
        rateSchedule: MileageRateSchedule,
        calendar: Calendar,
        formatting: ReportFormattingContext
    ) -> String {
        let rates = trips.map { rateSchedule.rate(on: $0.startDate, calendar: calendar) }
        let distinctAmounts = Set(rates.map(\.amountPerMeter))
        guard distinctAmounts.count <= 1 else {
            return String(localized: "Multiple rates", bundle: .appCoreStrings)
        }
        let rate = rates.first ?? rateSchedule.rate(on: fallbackDate, calendar: calendar)
        return PDFText.rateText(rate, formatting: formatting)
    }
}

/// A row in the report trip table: a trip, or the month divider/subtotal rows
/// annual reports interleave between months.
private enum ReportTableRowModel: Identifiable {
    case trip(MonthlyReportRowModel)
    case monthHeader(ReportMonthDividerModel)
    case monthSubtotal(ReportMonthSubtotalModel)

    var id: String {
        switch self {
        case let .trip(row): row.id
        case let .monthHeader(divider): "month-header-\(divider.id)"
        case let .monthSubtotal(subtotal): "month-subtotal-\(subtotal.id)"
        }
    }

    var estimatedHeight: CGFloat {
        switch self {
        case let .trip(row): row.estimatedHeight
        case .monthHeader: MonthlyReportPDFLayout.monthDividerEstimatedHeight
        case let .monthSubtotal(subtotal): subtotal.estimatedHeight
        }
    }
}

private struct ReportMonthDividerModel {
    var id: String
    var label: String
}

private struct ReportMonthSubtotalModel {
    var id: String
    var label: String
    var miles: String
    var amount: String
    var feeNotes: [String]

    var estimatedHeight: CGFloat {
        18 + CGFloat(feeNotes.count) * 9
    }
}

private enum ReportTablePagination {
    /// Splits table rows into page-sized chunks by estimated height.
    /// `firstPageNumber` picks the first page's row budget: monthly reports
    /// start the table on page 1 under the summary panel; annual reports start
    /// on page 2 because page 1 is the summary page.
    static func paginate(
        rows: [ReportTableRowModel],
        firstPageNumber: Int,
        hasOdometer: Bool,
        firstPageOverviewHeight: CGFloat = 0
    ) -> [[ReportTableRowModel]] {
        guard !rows.isEmpty else { return [[]] }
        let continuationBudget = MonthlyReportPDFLayout.rowBudget(pageNumber: 2, hasOdometer: false)
        let maximumRowHeight = continuationBudget - MonthlyReportPDFLayout.monthDividerEstimatedHeight - 54
        let rows = rows.flatMap { row -> [ReportTableRowModel] in
            guard case let .trip(trip) = row else { return [row] }
            return trip.continuationRows(maxHeight: maximumRowHeight).map(ReportTableRowModel.trip)
        }

        var chunks: [[ReportTableRowModel]] = []
        var pageRows: [ReportTableRowModel] = []
        var pageNumber = firstPageNumber
        var pageHeight: CGFloat = 0
        var rowBudget = MonthlyReportPDFLayout.rowBudget(
            pageNumber: pageNumber,
            hasOdometer: hasOdometer,
            firstPageOverviewHeight: firstPageOverviewHeight
        )

        for (index, row) in rows.enumerated() {
            // A month divider must not orphan at the bottom of a page (reserve
            // room for the row that follows it), and a month subtotal must not
            // orphan at the top of one (reserve room for it alongside the last
            // trip it foots).
            var requiredHeight = row.estimatedHeight
            if case .monthHeader = row, index + 1 < rows.count {
                requiredHeight += rows[index + 1].estimatedHeight
            }
            if index + 1 < rows.count, case .monthSubtotal = rows[index + 1] {
                requiredHeight += rows[index + 1].estimatedHeight
            }

            if pageHeight + requiredHeight > rowBudget {
                chunks.append(pageRows)
                pageRows = []
                pageNumber += 1
                pageHeight = 0
                rowBudget = MonthlyReportPDFLayout.rowBudget(pageNumber: pageNumber, hasOdometer: false)
            }

            pageRows.append(row)
            pageHeight += row.estimatedHeight
        }

        if !pageRows.isEmpty {
            chunks.append(pageRows)
        }

        // The last page also renders the totals block; spill to a fresh page
        // when the final rows leave no room for it.
        if pageHeight + MonthlyReportPDFLayout.totalsHeight > rowBudget {
            chunks.append([])
        }

        return chunks
    }
}

private struct MonthlyReportPDFPageModel {
    var startDate: Date
    var endDate: Date
    var generatedAt: Date
    var tripCount: Int
    /// Full-precision business miles, kept for the business-use-% math.
    var businessMiles: Double
    /// Sum of per-row-rounded distances in the display unit, so the printed
    /// total foots to the printed rows.
    var displayedBusinessDistance: Double
    var businessParking: Double
    var businessTolls: Double
    var businessValue: Double
    var rateDescription: String
    var formatting: ReportFormattingContext
    var audit: ReportAuditSummary
    var vehicleSummaries: [ReportVehicleSummary]
    var vehicleScopeTitle: String?
    var odometer: OdometerPeriodEstimate?
    var rows: [ReportTableRowModel]
    var pageNumber: Int
    var pageCount: Int
}

private struct ReportPDFFooter: View {
    var pageNumber: Int
    var pageCount: Int

    var body: some View {
        Text(String(localized: "Page \(pageNumber) of \(pageCount)", bundle: .appCoreStrings))
            .font(.system(size: 8))
            .foregroundStyle(PDFPalette.muted)
            .frame(height: PDFMetrics.footerHeight, alignment: .leading)
    }
}

private struct MonthlyReportRowModel: Identifiable {
    var id: String
    var date: String
    var time: String
    var routeTitle: String
    var routeDetail: String?
    var purpose: String
    var miles: String
    var amount: String
    var feeNotes: [String]
    var vehicleName: String?
    var estimatedHeight: CGFloat

    init(
        trip: TripSummary,
        rate: MileageRate,
        homeState: String?,
        formatting: ReportFormattingContext,
        vehicleName: String? = nil
    ) {
        id = "\(trip.id.uuidString)-\(trip.startDate.timeIntervalSinceReferenceDate)"
        date = Self.dayFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: trip.startDate)
        time = Self.timeFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: trip.startDate)
        let rawTitle = PDFText.routeHeadline(for: trip, homeState: homeState)
        // The monthly/annual PDF is the concise human-readable ledger. Full
        // per-leg times, stop durations, and addresses remain in the canonical
        // CSV and the individual trip receipt instead of turning every report
        // row into a paragraph.
        let rawDetail: String? = nil
        let rawPurpose = PDFText.nonEmpty(trip.businessPurpose) ?? PDFText.nonEmpty(trip.notes) ?? "-"
        routeTitle = MonthlyReportPDFLayout.wrappedCellText(rawTitle, width: MonthlyReportPDFLayout.routeWidth)
        routeDetail = rawDetail.map {
            MonthlyReportPDFLayout.wrappedCellText(
                $0,
                width: MonthlyReportPDFLayout.detailWidth,
                fontSize: MonthlyReportPDFLayout.detailFontSize
            )
        }
        purpose = rawPurpose
        miles = PDFText.distanceValueText(meters: trip.reportableDistanceMeters, formatting: formatting)
        if trip.isExportableBusiness {
            amount = CurrencyFormatting.label(
                formatting.currency.rounded(trip.reportableDistanceMeters * rate.amountPerMeter),
                code: formatting.currencyCode,
                locale: formatting.locale
            )
        } else {
            amount = "-"
        }
        var notes: [String] = []
        if trip.tollsAmount > 0 {
            let tollsAmount = CurrencyFormatting.label(trip.tollsAmount, code: formatting.currencyCode, locale: formatting.locale)
            notes.append(String(localized: "+\(tollsAmount) tolls", bundle: .appCoreStrings))
        }
        if trip.parkingAmount > 0 {
            let parkingAmount = CurrencyFormatting.label(trip.parkingAmount, code: formatting.currencyCode, locale: formatting.locale)
            notes.append(String(localized: "+\(parkingAmount) parking", bundle: .appCoreStrings))
        }
        feeNotes = notes
        self.vehicleName = vehicleName
        estimatedHeight = MonthlyReportPDFLayout.estimatedRowHeight(
            routeTitle: rawTitle,
            purpose: rawPurpose,
            vehicleName: vehicleName,
            detail: rawDetail,
            feeNoteCount: notes.count
        )
    }

    func continuationRows(maxHeight: CGFloat) -> [Self] {
        guard estimatedHeight > maxHeight else { return [self] }
        let metadata = vehicleName.map { "\(purpose) · \($0)" } ?? purpose
        let routeLines = routeTitle.components(separatedBy: "\n").map { (route: true, text: $0) }
        let purposeLines = MonthlyReportPDFLayout.wrappedCellText(metadata, width: MonthlyReportPDFLayout.routeWidth, fontSize: 7.3)
            .components(separatedBy: "\n").map { (route: false, text: $0) }
        let lines = routeLines + purposeLines
        let capacity = max(1, Int((maxHeight - MonthlyReportPDFLayout.rowVerticalPadding) / MonthlyReportPDFLayout.rowLineHeight) - 4)
        return stride(from: 0, to: lines.count, by: capacity).enumerated().map { index, offset in
            let part = lines[offset..<min(offset + capacity, lines.count)]
            var row = self
            row.id += "-part-\(index)"
            row.routeTitle = part.filter(\.route).map(\.text).joined(separator: "\n")
            if row.routeTitle.isEmpty { row.routeTitle = String(localized: "Continued", bundle: .appCoreStrings) }
            row.purpose = part.filter { !$0.route }.map(\.text).joined(separator: "\n")
            row.vehicleName = nil
            if index > 0 {
                // Continuation text is evidence for the same line item, not
                // another charge. Amounts and distances appear exactly once.
                row.miles = ""
                row.amount = ""
                row.feeNotes = []
            }
            row.estimatedHeight = MonthlyReportPDFLayout.estimatedRowHeight(
                routeTitle: row.routeTitle, purpose: row.purpose, vehicleName: nil,
                detail: row.routeDetail, feeNoteCount: row.feeNotes.count
            )
            return row
        }
    }

    private static func dayFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }

    private static func timeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}

private struct MonthlyReportPDFPage: View {
    var model: MonthlyReportPDFPageModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            PDFPalette.paper
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.pageNumber == 1 {
                    ReportPDFSummaryPanel(
                        tripCount: model.tripCount,
                        displayedBusinessDistance: model.displayedBusinessDistance,
                        businessValue: model.businessValue,
                        businessParking: model.businessParking,
                        businessTolls: model.businessTolls,
                        rateDescription: model.rateDescription,
                        formatting: model.formatting
                    )
                    .padding(.bottom, 8)
                    ReportPDFCoverageStrip(audit: model.audit)
                        .padding(.bottom, model.vehicleSummaries.count > 1 ? 8 : 14)
                    if model.vehicleSummaries.count > 1 {
                        ReportPDFVehicleSummaryTable(
                            summaries: model.vehicleSummaries,
                            formatting: model.formatting
                        )
                        .padding(.bottom, 14)
                    }
                    if let odometer = model.odometer {
                        ReportPDFOdometerPanel(
                            odometer: odometer,
                            businessMiles: model.businessMiles,
                            formatting: model.formatting
                        )
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                    }
                }
                tripTable
                Spacer(minLength: 0)
            }
            .frame(
                width: PDFMetrics.contentWidth,
                height: PDFMetrics.bodyHeight,
                alignment: .topLeading
            )
            .clipped()
            .padding(.leading, PDFMetrics.margin)
            .padding(.top, PDFMetrics.topMargin)
            .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height, alignment: .topLeading)

            ReportPDFFooter(pageNumber: model.pageNumber, pageCount: model.pageCount)
                .padding(.horizontal, PDFMetrics.margin)
                .padding(.bottom, PDFMetrics.bottomMargin)
                .frame(
                    width: NativePDFRenderer.pageSize.width,
                    height: NativePDFRenderer.pageSize.height,
                    alignment: .bottomLeading
                )
        }
        .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .center, spacing: 8) {
                    Text(verbatim: "M")
                        .font(.system(size: model.pageNumber == 1 ? 10 : 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: model.pageNumber == 1 ? 20 : 16, height: model.pageNumber == 1 ? 20 : 16)
                        .background(PDFPalette.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(String(localized: "Mileage Report", bundle: .appCoreStrings))
                        .font(.system(size: model.pageNumber == 1 ? 22 : 16, weight: .bold))
                        .foregroundStyle(PDFPalette.text)
                }
                Spacer()
                Text(
                    model.pageNumber == 1
                        ? String(localized: "Generated \(Self.dateTimeFormatter(locale: model.formatting.locale, timeZone: model.formatting.timeZone).string(from: model.generatedAt))", bundle: .appCoreStrings)
                        : String(localized: "Continued", bundle: .appCoreStrings)
                )
                    .font(.system(size: 8.5))
                    .foregroundStyle(PDFPalette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(Self.longDateFormatter(locale: model.formatting.locale, timeZone: model.formatting.timeZone).string(from: model.startDate)) – \(Self.longDateFormatter(locale: model.formatting.locale, timeZone: model.formatting.timeZone).string(from: model.endDate))")
                Text(verbatim: "• \(String(localized: "Rate", bundle: .appCoreStrings)) \(model.rateDescription)")
                if let vehicleScopeTitle = model.vehicleScopeTitle {
                    Text(verbatim: "• \(vehicleScopeTitle)")
                        .foregroundStyle(PDFPalette.brand)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(PDFPalette.muted)
        }
        .frame(height: model.pageNumber == 1 ? 58 : 36, alignment: .top)
    }

    private var tripTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Business trips", bundle: .appCoreStrings))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PDFPalette.text)
                .padding(.bottom, 8)

            if model.rows.isEmpty, model.tripCount == 0 {
                Text(String(localized: "No business trips recorded for this period.", bundle: .appCoreStrings))
                    .font(.system(size: 10))
                    .foregroundStyle(PDFPalette.muted)
                    .padding(.top, 8)
            } else {
                if !model.rows.isEmpty {
                    MonthlyReportTableHeader(formatting: model.formatting)
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        switch row {
                        case let .trip(trip):
                            MonthlyReportTableRow(row: trip, isStriped: index.isMultiple(of: 2))
                        case let .monthHeader(divider):
                            MonthlyReportMonthDivider(model: divider)
                        case let .monthSubtotal(subtotal):
                            MonthlyReportMonthSubtotalRow(model: subtotal)
                        }
                    }
                }
                if model.pageNumber == model.pageCount {
                    totalsBlock
                        .padding(.top, 6)
                }
            }
        }
    }

    private var totalsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            totalsRow(
                label: String(localized: "Totals", bundle: .appCoreStrings),
                miles: distanceText(model.displayedBusinessDistance),
                amount: currency(model.businessValue)
            )
            if model.businessParking > 0 {
                totalsRow(
                    label: String(localized: "Parking", bundle: .appCoreStrings),
                    miles: "",
                    amount: "+\(currency(model.businessParking))"
                )
            }
            if model.businessTolls > 0 {
                totalsRow(
                    label: String(localized: "Tolls", bundle: .appCoreStrings),
                    miles: "",
                    amount: "+\(currency(model.businessTolls))"
                )
            }
            totalsRow(
                label: String(localized: "Total reimbursement", bundle: .appCoreStrings),
                miles: "",
                amount: currency(totalReimbursement),
                emphasized: true
            )
        }
    }

    private func totalsRow(label: String, miles: String, amount: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 8.2, weight: emphasized ? .bold : .semibold))
                .foregroundStyle(emphasized ? PDFPalette.text : PDFPalette.muted)
                .padding(.horizontal, 4)
                .frame(
                    width: MonthlyReportPDFLayout.dateWidth + MonthlyReportPDFLayout.routeWidth + MonthlyReportPDFLayout.purposeWidth,
                    alignment: .trailing
                )
            Text(miles)
                .font(.system(size: 8.2, weight: emphasized ? .bold : .semibold))
                .foregroundStyle(PDFPalette.text)
                .padding(.horizontal, 4)
                .frame(width: MonthlyReportPDFLayout.milesWidth, alignment: .trailing)
            Text(amount)
                .font(.system(size: 8.2, weight: emphasized ? .bold : .semibold))
                .foregroundStyle(PDFPalette.text)
                .padding(.horizontal, 4)
                .frame(width: MonthlyReportPDFLayout.amountWidth, alignment: .trailing)
        }
        .frame(height: 16)
        .overlay(alignment: .top) {
            if emphasized {
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(PDFPalette.line)
                        .frame(width: MonthlyReportPDFLayout.milesWidth + MonthlyReportPDFLayout.amountWidth + 120, height: 0.6)
                }
            }
        }
    }

    private var totalReimbursement: Double {
        model.businessValue + model.businessParking + model.businessTolls
    }

    private func currency(_ value: Double) -> String {
        CurrencyFormatting.label(value, code: model.formatting.currencyCode, locale: model.formatting.locale)
    }

    /// Formats a value already expressed in the display unit.
    private func distanceText(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(2))
                .grouping(.never)
                .locale(model.formatting.locale)
        )
    }

    private static func longDateFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private static func dateTimeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

/// The reimbursement summary card shared by the monthly report's first page
/// and the annual report's summary page.
private struct ReportPDFSummaryPanel: View {
    var tripCount: Int
    var displayedBusinessDistance: Double
    var businessValue: Double
    var businessParking: Double
    var businessTolls: Double
    var rateDescription: String
    var formatting: ReportFormattingContext

    var body: some View {
        HStack(alignment: .center, spacing: 34) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Total reimbursement", bundle: .appCoreStrings))
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(PDFPalette.muted)
                Text(currency(totalReimbursement))
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                Text(verbatim: "\(distanceText(displayedBusinessDistance)) \(DistanceFormatting.unitSymbol(formatting.distanceUnit, locale: formatting.locale)) · \(tripCount) \(String(localized: "business trips", bundle: .appCoreStrings))")
                    .font(.system(size: 8.2, weight: .semibold))
                    .foregroundStyle(PDFPalette.business)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(PDFPalette.brand)
                    .frame(width: 4)
            }

            VStack(alignment: .leading, spacing: 5) {
                summaryRow(String(localized: "Mileage", bundle: .appCoreStrings), currency(businessValue))
                summaryRow(String(localized: "Parking", bundle: .appCoreStrings), currency(businessParking))
                summaryRow(String(localized: "Tolls", bundle: .appCoreStrings), currency(businessTolls))
                summaryRow(String(localized: "Rate", bundle: .appCoreStrings), rateDescription)
            }
            .frame(width: 208)
        }
        .padding(.vertical, 10)
        .frame(height: 94)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(PDFPalette.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PDFPalette.text)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line.opacity(0.6)).frame(height: 0.5) }
    }

    private func currency(_ value: Double) -> String {
        CurrencyFormatting.label(value, code: formatting.currencyCode, locale: formatting.locale)
    }

    private var totalReimbursement: Double {
        businessValue + businessParking + businessTolls
    }

    /// Formats a value already expressed in the display unit.
    private func distanceText(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(2))
                .grouping(.never)
                .locale(formatting.locale)
        )
    }
}

private struct ReportPDFCoverageStrip: View {
    var audit: ReportAuditSummary

    var body: some View {
        HStack(spacing: 18) {
            Text(String(localized: "Report coverage", bundle: .appCoreStrings))
                .font(.system(size: 7.6, weight: .bold))
                .foregroundStyle(PDFPalette.text)
            coverageCell(
                label: String(localized: "business included", bundle: .appCoreStrings),
                value: audit.businessIncluded,
                color: PDFPalette.business
            )
            coverageCell(
                label: String(localized: "personal excluded", bundle: .appCoreStrings),
                value: audit.personalExcluded,
                color: PDFPalette.personal
            )
            coverageCell(
                label: String(localized: "needs review", bundle: .appCoreStrings),
                value: audit.needsReview,
                color: audit.needsReview == 0 ? PDFPalette.business : PDFPalette.personal
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Report coverage", bundle: .appCoreStrings))
    }

    private func coverageCell(label: String, value: Int, color: Color) -> some View {
        HStack(alignment: .center, spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(verbatim: "\(value.formatted()) \(label)")
                .font(.system(size: 7.2))
                .foregroundStyle(PDFPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct ReportPDFVehicleSummaryTable: View {
    var summaries: [ReportVehicleSummary]
    var formatting: ReportFormattingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Vehicles", bundle: .appCoreStrings))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                Spacer()
                Text(verbatim: "\(distance(totalDistance)) \(DistanceFormatting.unitSymbol(formatting.distanceUnit, locale: formatting.locale)) · \(summaries.count) \(String(localized: "vehicles", bundle: .appCoreStrings))")
                    .font(.system(size: 7.2))
                    .foregroundStyle(PDFPalette.muted)
            }
            ForEach(vehiclePairs.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 0) {
                    vehicleBlock(vehiclePairs[index].0)
                    Rectangle()
                        .fill(PDFPalette.line)
                        .frame(width: 0.6, height: 42)
                        .padding(.horizontal, 14)
                    if let second = vehiclePairs[index].1 {
                        vehicleBlock(second)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, minHeight: 42)
                    }
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
            }
            Rectangle().fill(PDFPalette.line).frame(height: 0.6)
        }
    }

    private func vehicleBlock(_ summary: ReportVehicleSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.name)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                Spacer()
                Text(currency(summary.total))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(PDFPalette.business)
            }
            HStack(spacing: 18) {
                detail(String(localized: "Trips", bundle: .appCoreStrings), "\(summary.tripCount)")
                detail(distanceLabel, distance(summary.distanceMeters))
                detail(String(localized: "Fees", bundle: .appCoreStrings), currency(summary.parking + summary.tolls))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 6.6))
                .foregroundStyle(PDFPalette.muted)
            Text(value)
                .font(.system(size: 7.6, weight: .semibold))
                .foregroundStyle(PDFPalette.text)
        }
    }

    private var vehiclePairs: [(ReportVehicleSummary, ReportVehicleSummary?)] {
        stride(from: 0, to: summaries.count, by: 2).map { index in
            (summaries[index], summaries.indices.contains(index + 1) ? summaries[index + 1] : nil)
        }
    }

    private var totalDistance: Double { summaries.reduce(0) { $0 + $1.distanceMeters } }

    private var distanceLabel: String {
        formatting.distanceUnit == .miles
            ? String(localized: "Miles", bundle: .appCoreStrings)
            : String(localized: "Kilometers", bundle: .appCoreStrings)
    }

    private func distance(_ meters: Double) -> String {
        DistanceFormatting.valueText(
            meters: meters,
            unit: formatting.distanceUnit,
            fractionDigits: 2,
            locale: formatting.locale
        )
    }

    private func currency(_ value: Double) -> String {
        CurrencyFormatting.label(value, code: formatting.currencyCode, locale: formatting.locale)
    }
}

/// The odometer strip shared by the monthly report's first page and the
/// annual report's summary page.
private struct ReportPDFOdometerPanel: View {
    var odometer: OdometerPeriodEstimate
    var businessMiles: Double
    var formatting: ReportFormattingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 16) {
                Text(String(localized: "Odometer", bundle: .appCoreStrings))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(PDFPalette.muted)
                switch odometer {
                case .none:
                    EmptyView()
                case let .singleReading(checkpoint):
                    Text(verbatim: "\(odometerValueText(miles: checkpoint.odometerMiles)) \(DistanceFormatting.unitSymbol(formatting.distanceUnit, locale: formatting.locale))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PDFPalette.text)
                    Text(String(localized: "recorded \(Self.longDateFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: checkpoint.date))", bundle: .appCoreStrings))
                        .font(.system(size: 9))
                        .foregroundStyle(PDFPalette.muted)
                case let .range(start, end, _, _):
                    Text(String(localized: "\(odometerValueText(miles: start.miles)) to \(odometerValueText(miles: end.miles))", bundle: .appCoreStrings))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PDFPalette.text)
                    if let detail = odometerRangeDetail(odometer) {
                        Text(detail)
                            .font(.system(size: 9))
                            .foregroundStyle(PDFPalette.muted)
                    }
                }
                Spacer()
            }
            if case let .range(_, _, firstDate, lastDate) = odometer, odometer.isEstimated {
                Text(String(localized: "Estimated from readings \(Self.longDateFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: firstDate)) – \(Self.longDateFormatter(locale: formatting.locale, timeZone: formatting.timeZone).string(from: lastDate))", bundle: .appCoreStrings))
                    .font(.system(size: 8))
                    .foregroundStyle(PDFPalette.muted)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
    }

    private func odometerRangeDetail(_ odometer: OdometerPeriodEstimate) -> String? {
        var parts: [String] = []
        if let total = odometer.totalMiles, total > 0 {
            let totalText = odometerValueText(miles: total)
            parts.append(
                formatting.distanceUnit == .miles
                    ? String(localized: "\(totalText) total miles", bundle: .appCoreStrings)
                    : String(localized: "\(totalText) total kilometers", bundle: .appCoreStrings)
            )
        }
        if let percent = odometer.businessUsePercent(businessMiles: businessMiles) {
            let percentText = String(format: "%.0f%%", percent)
            parts.append(String(localized: "\(percentText) business use", bundle: .appCoreStrings))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Odometer readings are stored in miles; convert to the display unit.
    private func odometerValueText(miles: Double) -> String {
        DistanceConversion.value(meters: DistanceConversion.meters(fromMiles: miles), in: formatting.distanceUnit)
            .formatted(
                .number.precision(.fractionLength(1))
                    .grouping(.never)
                    .locale(formatting.locale)
            )
    }

    private static func longDateFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

/// "March 2026" band separating months in the annual trip table.
private struct MonthlyReportMonthDivider: View {
    var model: ReportMonthDividerModel

    var body: some View {
        Text(model.label)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(PDFPalette.text)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MonthlyReportPDFLayout.monthDividerHeight, alignment: .bottomLeading)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.8) }
    }
}

/// The subtotal line closing a month's section in the annual trip table.
/// The amount column keeps its per-trip semantics (mileage only); the
/// month's fees appear as the same small note lines trips use.
private struct MonthlyReportMonthSubtotalRow: View {
    var model: ReportMonthSubtotalModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(model.label)
                .font(.system(size: 8.2, weight: .semibold))
                .foregroundStyle(PDFPalette.muted)
                .padding(.horizontal, 4)
                .frame(
                    width: MonthlyReportPDFLayout.dateWidth + MonthlyReportPDFLayout.routeWidth + MonthlyReportPDFLayout.purposeWidth,
                    alignment: .trailing
                )
            Text(model.miles)
                .font(.system(size: 8.2, weight: .bold))
                .foregroundStyle(PDFPalette.text)
                .padding(.horizontal, 4)
                .frame(width: MonthlyReportPDFLayout.milesWidth, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.amount)
                    .font(.system(size: 8.2, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                ForEach(model.feeNotes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 7))
                        .foregroundStyle(PDFPalette.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .frame(width: MonthlyReportPDFLayout.amountWidth, alignment: .topTrailing)
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
    }
}

/// Localized "March 2026" labels used by annual CSV sections, PDF month
/// dividers, and the summary table. The time zone must match the calendar
/// that bucketed the months, or a month-start instant can label as the
/// neighboring month.
enum ReportMonthLabel {
    static func formatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }
}

private enum AnnualSummaryPDFLayout {
    static let firstHeaderHeight: CGFloat = 58
    static let continuationHeaderHeight: CGFloat = 36
    static let odometerHeight: CGFloat = 76
    static let monthTitleHeight: CGFloat = 26
    static let monthHeaderHeight: CGFloat = 20
    static let monthRowHeight: CGFloat = 18
    static let totalRowHeight: CGFloat = 20

    static func requiresMonthlySummaryContinuation(
        vehicleSummaryCount: Int,
        hasOdometer: Bool,
        monthRowCount: Int
    ) -> Bool {
        let overviewHeight = MonthlyReportPDFLayout.overviewHeight(
            vehicleSummaryCount: vehicleSummaryCount,
            includesCoverage: true
        )
        let odometer = hasOdometer ? odometerHeight : 0
        let requiredHeight = firstHeaderHeight
            + overviewHeight
            + odometer
            + monthTableHeight(rowCount: monthRowCount)

        // Keep a little slack above the clipped body edge. Text glyphs must
        // remain at least eight points above the fixed footer on every page.
        return requiredHeight > PDFMetrics.bodyHeight - PDFMetrics.footerGap
    }

    private static func monthTableHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return monthTitleHeight + 28 }
        return monthTitleHeight
            + monthHeaderHeight
            + CGFloat(rowCount) * monthRowHeight
            + totalRowHeight
    }
}

private struct AnnualReportPDFDocument {
    var pages: [AnyView]

    init(
        startDate: Date,
        endDate: Date,
        monthSections: [ReportMonthSection],
        calendar: Calendar,
        odometerEstimate: OdometerPeriodEstimate,
        businessMiles: Double,
        businessParking: Double,
        businessTolls: Double,
        businessValue: Double,
        rateSchedule: MileageRateSchedule,
        formatting: ReportFormattingContext,
        audit: ReportAuditSummary,
        vehicleNamesByTripID: [UUID: String]?,
        vehicleTitleSuffix: String?
    ) {
        let allTrips = monthSections.flatMap(\.trips)
        let vehicleSummaries = ReportVehicleSummaryBuilder.make(
            trips: allTrips,
            rateSchedule: rateSchedule,
            calendar: calendar,
            vehicleNamesByTripID: vehicleNamesByTripID,
            vehicleTitleSuffix: vehicleTitleSuffix,
            formatting: formatting
        )
        let showsVehicleOnRows = vehicleSummaries.count > 1
        let homeState = PDFText.homeState(for: allTrips)
        let monthFormatter = ReportMonthLabel.formatter(locale: formatting.locale, timeZone: calendar.timeZone)
        let odometer: OdometerPeriodEstimate? = odometerEstimate == .none ? nil : odometerEstimate

        var rows: [ReportTableRowModel] = []
        for section in monthSections where !section.trips.isEmpty {
            let monthLabel = monthFormatter.string(from: section.monthStart)
            let monthID = "\(section.monthStart.timeIntervalSinceReferenceDate)"
            rows.append(.monthHeader(ReportMonthDividerModel(id: monthID, label: monthLabel)))
            rows.append(contentsOf: section.trips.map {
                let rate = rateSchedule.rate(on: $0.startDate, calendar: calendar)
                return .trip(MonthlyReportRowModel(
                    trip: $0,
                    rate: rate,
                    homeState: homeState,
                    formatting: formatting,
                    vehicleName: showsVehicleOnRows
                        ? (vehicleNamesByTripID?[$0.id] ?? String(localized: "No vehicle", bundle: .appCoreStrings))
                        : nil
                ))
            })
            var feeNotes: [String] = []
            if section.tolls > 0 {
                let tollsAmount = CurrencyFormatting.label(section.tolls, code: formatting.currencyCode, locale: formatting.locale)
                feeNotes.append(String(localized: "+\(tollsAmount) tolls", bundle: .appCoreStrings))
            }
            if section.parking > 0 {
                let parkingAmount = CurrencyFormatting.label(section.parking, code: formatting.currencyCode, locale: formatting.locale)
                feeNotes.append(String(localized: "+\(parkingAmount) parking", bundle: .appCoreStrings))
            }
            rows.append(.monthSubtotal(ReportMonthSubtotalModel(
                id: monthID,
                label: String(localized: "\(monthLabel) total", bundle: .appCoreStrings),
                miles: Self.distanceText(section.displayedBusinessDistance, formatting: formatting),
                amount: CurrencyFormatting.label(section.mileageReimbursement, code: formatting.currencyCode, locale: formatting.locale),
                feeNotes: feeNotes
            )))
        }

        let displayedBusinessDistance = monthSections.reduce(0) { $0 + $1.displayedBusinessDistance }
        let allRates = allTrips.map { rateSchedule.rate(on: $0.startDate, calendar: calendar) }
        let distinctRateAmounts = Set(allRates.map(\.amountPerMeter))
        let rateDescription: String
        if distinctRateAmounts.count > 1 {
            rateDescription = String(localized: "Multiple rates", bundle: .appCoreStrings)
        } else {
            let rate = allRates.first ?? rateSchedule.rate(on: startDate, calendar: calendar)
            rateDescription = PDFText.rateText(rate, formatting: formatting)
        }

        let monthRows = monthSections.map { section in
            AnnualMonthSummaryRowModel(
                id: "\(section.monthStart.timeIntervalSinceReferenceDate)",
                label: monthFormatter.string(from: section.monthStart),
                trips: "\(section.tripCount)",
                distance: Self.distanceText(section.displayedBusinessDistance, formatting: formatting),
                amount: CurrencyFormatting.label(section.mileageReimbursement, code: formatting.currencyCode, locale: formatting.locale),
                parkingAndTolls: CurrencyFormatting.label(section.parkingAndTolls, code: formatting.currencyCode, locale: formatting.locale),
                total: CurrencyFormatting.label(section.totalReimbursement, code: formatting.currencyCode, locale: formatting.locale)
            )
        }
        let hasMonthlySummaryContinuation = AnnualSummaryPDFLayout.requiresMonthlySummaryContinuation(
            vehicleSummaryCount: vehicleSummaries.count,
            hasOdometer: odometer != nil,
            monthRowCount: monthRows.count
        )
        let summaryPageCount = hasMonthlySummaryContinuation ? 2 : 1

        // Trip pages always use the compact continuation header. Their actual
        // page number follows however many summary pages were required.
        let chunks = ReportTablePagination.paginate(
            rows: rows,
            firstPageNumber: summaryPageCount + 1,
            hasOdometer: false
        )
        let pageCount = chunks.count + summaryPageCount

        let summaryModel = AnnualReportSummaryPDFPageModel(
            startDate: startDate,
            endDate: endDate,
            generatedAt: Date(),
            tripCount: Set(allTrips.map(\.id)).count,
            businessMiles: businessMiles,
            displayedBusinessDistance: displayedBusinessDistance,
            businessParking: businessParking,
            businessTolls: businessTolls,
            businessValue: businessValue,
            rateDescription: rateDescription,
            formatting: formatting,
            audit: audit,
            vehicleSummaries: vehicleSummaries,
            vehicleScopeTitle: Self.vehicleScopeTitle(
                vehicleTitleSuffix: vehicleTitleSuffix,
                summaries: vehicleSummaries
            ),
            odometer: odometer,
            monthRows: monthRows,
            showsOverview: true,
            showsMonthTable: !hasMonthlySummaryContinuation,
            pageNumber: 1,
            pageCount: pageCount
        )

        pages = [AnyView(AnnualReportSummaryPDFPage(model: summaryModel))]
        if hasMonthlySummaryContinuation {
            var continuationModel = summaryModel
            continuationModel.showsOverview = false
            continuationModel.showsMonthTable = true
            continuationModel.pageNumber = 2
            pages.append(AnyView(AnnualReportSummaryPDFPage(model: continuationModel)))
        }
        pages.append(contentsOf: chunks.enumerated().map { index, rows in
            AnyView(MonthlyReportPDFPage(model: MonthlyReportPDFPageModel(
                startDate: startDate,
                endDate: endDate,
                generatedAt: summaryModel.generatedAt,
                tripCount: Set(allTrips.map(\.id)).count,
                businessMiles: businessMiles,
                displayedBusinessDistance: displayedBusinessDistance,
                businessParking: businessParking,
                businessTolls: businessTolls,
                businessValue: businessValue,
                rateDescription: rateDescription,
                formatting: formatting,
                audit: audit,
                vehicleSummaries: vehicleSummaries,
                vehicleScopeTitle: summaryModel.vehicleScopeTitle,
                odometer: nil,
                rows: rows,
                pageNumber: index + summaryPageCount + 1,
                pageCount: pageCount
            )))
        })
    }

    private static func vehicleScopeTitle(
        vehicleTitleSuffix: String?,
        summaries: [ReportVehicleSummary]
    ) -> String? {
        if let vehicleTitleSuffix {
            return vehicleTitleSuffix
        }
        if summaries.count > 1 {
            return String(localized: "All vehicles", bundle: .appCoreStrings)
        }
        return summaries.first?.name
    }

    private static func distanceText(_ value: Double, formatting: ReportFormattingContext) -> String {
        value.formatted(
            .number.precision(.fractionLength(2))
                .grouping(.never)
                .locale(formatting.locale)
        )
    }
}

private struct AnnualMonthSummaryRowModel: Identifiable {
    var id: String
    var label: String
    var trips: String
    var distance: String
    var amount: String
    var parkingAndTolls: String
    var total: String
}

private struct AnnualReportSummaryPDFPageModel {
    var startDate: Date
    var endDate: Date
    var generatedAt: Date
    var tripCount: Int
    var businessMiles: Double
    var displayedBusinessDistance: Double
    var businessParking: Double
    var businessTolls: Double
    var businessValue: Double
    var rateDescription: String
    var formatting: ReportFormattingContext
    var audit: ReportAuditSummary
    var vehicleSummaries: [ReportVehicleSummary]
    var vehicleScopeTitle: String?
    var odometer: OdometerPeriodEstimate?
    var monthRows: [AnnualMonthSummaryRowModel]
    var showsOverview: Bool
    var showsMonthTable: Bool
    var pageNumber: Int
    var pageCount: Int
}

private enum AnnualSummaryTableLayout {
    static let monthWidth: CGFloat = 128
    static let tripsWidth: CGFloat = 64
    static let distanceWidth: CGFloat = 78
    static let amountWidth: CGFloat = 86
    static let parkingAndTollsWidth: CGFloat = 86
    static let totalWidth: CGFloat = PDFMetrics.contentWidth - monthWidth - tripsWidth - distanceWidth - amountWidth - parkingAndTollsWidth
}

/// Annual overview and, when needed, a dedicated monthly-summary continuation.
private struct AnnualReportSummaryPDFPage: View {
    var model: AnnualReportSummaryPDFPageModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            PDFPalette.paper
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.showsOverview {
                    ReportPDFSummaryPanel(
                        tripCount: model.tripCount,
                        displayedBusinessDistance: model.displayedBusinessDistance,
                        businessValue: model.businessValue,
                        businessParking: model.businessParking,
                        businessTolls: model.businessTolls,
                        rateDescription: model.rateDescription,
                        formatting: model.formatting
                    )
                    .padding(.bottom, 8)
                    ReportPDFCoverageStrip(audit: model.audit)
                        .padding(.bottom, model.vehicleSummaries.count > 1 ? 8 : 14)
                    if model.vehicleSummaries.count > 1 {
                        ReportPDFVehicleSummaryTable(
                            summaries: model.vehicleSummaries,
                            formatting: model.formatting
                        )
                        .padding(.bottom, 14)
                    }
                    if let odometer = model.odometer {
                        ReportPDFOdometerPanel(
                            odometer: odometer,
                            businessMiles: model.businessMiles,
                            formatting: model.formatting
                        )
                        .padding(.bottom, 14)
                    }
                }
                if model.showsMonthTable {
                    monthTable
                }
                Spacer(minLength: 0)
            }
            .frame(
                width: PDFMetrics.contentWidth,
                height: PDFMetrics.bodyHeight,
                alignment: .topLeading
            )
            .clipped()
            .padding(.leading, PDFMetrics.margin)
            .padding(.top, PDFMetrics.topMargin)
            .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height, alignment: .topLeading)

            ReportPDFFooter(pageNumber: model.pageNumber, pageCount: model.pageCount)
                .padding(.horizontal, PDFMetrics.margin)
                .padding(.bottom, PDFMetrics.bottomMargin)
                .frame(
                    width: NativePDFRenderer.pageSize.width,
                    height: NativePDFRenderer.pageSize.height,
                    alignment: .bottomLeading
                )
        }
        .frame(width: NativePDFRenderer.pageSize.width, height: NativePDFRenderer.pageSize.height)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .center, spacing: 8) {
                    Text(verbatim: "M")
                        .font(.system(size: model.pageNumber == 1 ? 10 : 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(
                            width: model.pageNumber == 1 ? 20 : 16,
                            height: model.pageNumber == 1 ? 20 : 16
                        )
                        .background(PDFPalette.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(String(localized: "Annual Mileage Report", bundle: .appCoreStrings))
                        .font(.system(size: model.pageNumber == 1 ? 22 : 16, weight: .bold))
                        .foregroundStyle(PDFPalette.text)
                }
                Spacer()
                Text(
                    model.pageNumber == 1
                        ? String(localized: "Generated \(Self.dateTimeFormatter(locale: model.formatting.locale, timeZone: model.formatting.timeZone).string(from: model.generatedAt))", bundle: .appCoreStrings)
                        : String(localized: "Continued", bundle: .appCoreStrings)
                )
                    .font(.system(size: 8.5))
                    .foregroundStyle(PDFPalette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(Self.longDateFormatter(locale: model.formatting.locale, timeZone: model.formatting.timeZone).string(from: model.startDate)) – \(Self.longDateFormatter(locale: model.formatting.locale, timeZone: model.formatting.timeZone).string(from: model.endDate))")
                Text(verbatim: "• \(String(localized: "Rate", bundle: .appCoreStrings)) \(model.rateDescription)")
                if let vehicleScopeTitle = model.vehicleScopeTitle {
                    Text(verbatim: "• \(vehicleScopeTitle)")
                        .foregroundStyle(PDFPalette.brand)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(PDFPalette.muted)
        }
        .frame(
            height: model.pageNumber == 1
                ? AnnualSummaryPDFLayout.firstHeaderHeight
                : AnnualSummaryPDFLayout.continuationHeaderHeight,
            alignment: .top
        )
    }

    private var monthTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Monthly summary", bundle: .appCoreStrings))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PDFPalette.text)
                .frame(height: AnnualSummaryPDFLayout.monthTitleHeight, alignment: .topLeading)

            if model.monthRows.isEmpty {
                Text(String(localized: "No business trips recorded for this period.", bundle: .appCoreStrings))
                    .font(.system(size: 10))
                    .foregroundStyle(PDFPalette.muted)
                    .padding(.top, 8)
            } else {
                headerRow
                ForEach(Array(model.monthRows.enumerated()), id: \.element.id) { index, row in
                    monthRow(row, isStriped: index.isMultiple(of: 2))
                }
                totalRow
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            headerCell(String(localized: "Month", bundle: .appCoreStrings), width: AnnualSummaryTableLayout.monthWidth)
            headerCell(String(localized: "Business trips", bundle: .appCoreStrings), width: AnnualSummaryTableLayout.tripsWidth, alignment: .trailing)
            headerCell(
                model.formatting.distanceUnit == .miles
                    ? String(localized: "Miles", bundle: .appCoreStrings)
                    : String(localized: "Kilometers", bundle: .appCoreStrings),
                width: AnnualSummaryTableLayout.distanceWidth,
                alignment: .trailing
            )
            headerCell(String(localized: "Amount", bundle: .appCoreStrings), width: AnnualSummaryTableLayout.amountWidth, alignment: .trailing)
            headerCell(String(localized: "Parking & tolls", bundle: .appCoreStrings), width: AnnualSummaryTableLayout.parkingAndTollsWidth, alignment: .trailing)
            headerCell(String(localized: "Total", bundle: .appCoreStrings), width: AnnualSummaryTableLayout.totalWidth, alignment: .trailing)
        }
        .frame(height: AnnualSummaryPDFLayout.monthHeaderHeight)
        .background(Color(red: 0.91, green: 0.93, blue: 0.95))
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
    }

    private func headerCell(_ value: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(value)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(PDFPalette.muted)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
    }

    private func monthRow(_ row: AnnualMonthSummaryRowModel, isStriped: Bool) -> some View {
        HStack(spacing: 0) {
            valueCell(row.label, width: AnnualSummaryTableLayout.monthWidth, weight: .semibold)
            valueCell(row.trips, width: AnnualSummaryTableLayout.tripsWidth, alignment: .trailing)
            valueCell(row.distance, width: AnnualSummaryTableLayout.distanceWidth, alignment: .trailing)
            valueCell(row.amount, width: AnnualSummaryTableLayout.amountWidth, alignment: .trailing)
            valueCell(row.parkingAndTolls, width: AnnualSummaryTableLayout.parkingAndTollsWidth, alignment: .trailing)
            valueCell(row.total, width: AnnualSummaryTableLayout.totalWidth, alignment: .trailing, weight: .semibold)
        }
        .frame(height: AnnualSummaryPDFLayout.monthRowHeight)
        .background(isStriped ? PDFPalette.stripe : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
    }

    private var totalRow: some View {
        HStack(spacing: 0) {
            valueCell(String(localized: "Year total", bundle: .appCoreStrings), width: AnnualSummaryTableLayout.monthWidth, weight: .bold)
            valueCell("\(model.tripCount)", width: AnnualSummaryTableLayout.tripsWidth, alignment: .trailing, weight: .bold)
            valueCell(distanceText(model.displayedBusinessDistance), width: AnnualSummaryTableLayout.distanceWidth, alignment: .trailing, weight: .bold)
            valueCell(currency(model.businessValue), width: AnnualSummaryTableLayout.amountWidth, alignment: .trailing, weight: .bold)
            valueCell(currency(model.businessParking + model.businessTolls), width: AnnualSummaryTableLayout.parkingAndTollsWidth, alignment: .trailing, weight: .bold)
            valueCell(currency(model.businessValue + model.businessParking + model.businessTolls), width: AnnualSummaryTableLayout.totalWidth, alignment: .trailing, weight: .bold)
        }
        .frame(height: AnnualSummaryPDFLayout.totalRowHeight)
    }

    private func valueCell(_ value: String, width: CGFloat, alignment: Alignment = .leading, weight: Font.Weight = .regular) -> some View {
        Text(value)
            .font(.system(size: 8.4, weight: weight))
            .foregroundStyle(PDFPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
    }

    private func currency(_ value: Double) -> String {
        CurrencyFormatting.label(value, code: model.formatting.currencyCode, locale: model.formatting.locale)
    }

    private func distanceText(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(2))
                .grouping(.never)
                .locale(model.formatting.locale)
        )
    }

    private static func longDateFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private static func dateTimeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

private struct MonthlyReportTableHeader: View {
    var formatting: ReportFormattingContext

    var body: some View {
        HStack(spacing: 0) {
            cell(String(localized: "Date", bundle: .appCoreStrings), width: MonthlyReportPDFLayout.dateWidth)
            cell(String(localized: "Route and purpose", bundle: .appCoreStrings), width: MonthlyReportPDFLayout.routeWidth)
            cell(
                formatting.distanceUnit == .miles
                    ? String(localized: "Miles", bundle: .appCoreStrings)
                    : String(localized: "Kilometers", bundle: .appCoreStrings),
                width: MonthlyReportPDFLayout.milesWidth,
                alignment: .trailing
            )
            cell(String(localized: "Amount", bundle: .appCoreStrings), width: MonthlyReportPDFLayout.amountWidth, alignment: .trailing)
        }
        .frame(height: 18)
        .overlay(alignment: .top) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line).frame(height: 0.6) }
    }

    private func cell(_ value: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(value)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(PDFPalette.muted)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
    }
}

private struct MonthlyReportTableRow: View {
    var row: MonthlyReportRowModel
    var isStriped: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0.5) {
                Text(row.date)
                    .font(.system(size: 8.2, weight: .bold))
                    .foregroundStyle(PDFPalette.text)
                Text(row.time)
                    .font(.system(size: 7.5))
                    .foregroundStyle(PDFPalette.muted)
            }
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: MonthlyReportPDFLayout.dateWidth, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.routeTitle)
                    .font(.system(size: 8.4, weight: .semibold))
                    .foregroundStyle(PDFPalette.text)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                metadata
                    .font(.system(size: 7.1, weight: .semibold))
                    .foregroundStyle(PDFPalette.muted)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.routeDetail {
                    Text(detail)
                        .font(.system(size: MonthlyReportPDFLayout.detailFontSize))
                        .foregroundStyle(PDFPalette.muted)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .frame(width: MonthlyReportPDFLayout.routeWidth, alignment: .topLeading)

            rowCell(row.miles, width: MonthlyReportPDFLayout.milesWidth, alignment: .trailing, weight: .bold)
            amountCell
        }
        .padding(.vertical, MonthlyReportPDFLayout.rowVerticalPadding / 2)
        .overlay(alignment: .bottom) { Rectangle().fill(PDFPalette.line.opacity(0.65)).frame(height: 0.5) }
    }

    private var metadata: Text {
        if let vehicle = row.vehicleName {
            var value = AttributedString(row.purpose)
            var suffix = AttributedString(" · \(vehicle)")
            suffix.foregroundColor = PDFPalette.business
            value += suffix
            return Text(value)
        } else {
            return Text(row.purpose)
        }
    }

    private var amountCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(row.amount)
                .font(.system(size: 8.2, weight: .bold))
                .foregroundStyle(PDFPalette.text)
            ForEach(row.feeNotes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 7))
                    .foregroundStyle(PDFPalette.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .frame(width: MonthlyReportPDFLayout.amountWidth, alignment: .topTrailing)
    }

    private func rowCell(
        _ value: String,
        width: CGFloat,
        alignment: Alignment = .leading,
        lineLimit: Int? = nil,
        weight: Font.Weight = .regular
    ) -> some View {
        Text(value)
            .font(.system(size: 8.2, weight: weight))
            .foregroundStyle(PDFPalette.text)
            .lineLimit(lineLimit)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
    }
}
