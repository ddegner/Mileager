import Foundation
import XCTest
@testable import AppCore

final class QuickBooksMileageCSVTests: XCTestCase {
    private let header = "Date,Type,Trip Purpose,Vehicle,Start Address,End Address,Distance,Deduction,Logging Method"

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @MainActor
    func testQuickBooksSchemaUsesMilesAndUSDatesRegardlessOfDisplayPreferences() throws {
        var drive = trip(date(2026, 9, 17), miles: 8)
        drive.manualDistanceOverrideMeters = DistanceConversion.meters(fromMiles: 1234.56)
        drive.businessPurpose = "Client \"portrait\", delivery\nSecond stop"
        drive.startAddress = "10 Main St, Boston"
        drive.endAddress = "Café"
        drive.tollsAmount = 5
        drive.parkingAmount = 9
        let report = try makeReport([drive], vehicleNames: [drive.id: "Car, blue"])

        XCTAssertEqual(report.csvText, header + "\n" +
            "09/17/2026,Business,\"Client \"\"portrait\"\", delivery\nSecond stop\",\"Car, blue\",\"10 Main St, Boston\",Café,1234.56,0,Manual")
        XCTAssertEqual(report.businessMiles, 1234.56, accuracy: 0.0001)
    }

    @MainActor
    func testOnlyEligibleBusinessTripsInTheSelectedPeriodAreIncluded() throws {
        let first = trip(date(2026, 9, 1, hour: 0), miles: 2)
        let last = trip(date(2026, 9, 30, hour: 23), miles: 3)
        var personal = trip(date(2026, 9, 10), miles: 20)
        personal.classification = .personal
        var unreviewed = personal
        unreviewed.id = UUID()
        unreviewed.classification = nil
        var notADrive = personal
        notADrive.id = UUID()
        notADrive.classification = .notADrive
        var missingPurpose = trip(date(2026, 9, 12), miles: 30)
        missingPurpose.businessPurpose = " \n\t "
        let report = try makeReport([
            last, personal, unreviewed, notADrive, missingPurpose,
            trip(date(2026, 8, 31, hour: 23), miles: 40),
            trip(date(2026, 10, 1, hour: 0), miles: 50), first
        ])

        XCTAssertEqual(report.csvText, [
            header,
            "09/01/2026,Business,Client visit,,Office,Client,2.00,0,Manual",
            "09/30/2026,Business,Client visit,,Office,Client,3.00,0,Manual"
        ].joined(separator: "\n"))
        XCTAssertEqual(report.includedTripIDs, [first.id, last.id])
        XCTAssertEqual(report.businessMiles, 5, accuracy: 0.0001)
    }

    @MainActor
    func testCSVUsesReportTimeZoneAndGregorianYear() throws {
        // September 18 in UTC is still September 17 in the report's time zone.
        let timestamp = ISO8601DateFormatter().date(from: "2026-09-18T01:30:00Z")!
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let report = try makeReport([trip(timestamp)], reportCalendar: buddhist)
        XCTAssertTrue(report.csvText.contains("\n09/17/2026,Business,"))
    }

    @MainActor
    func testFormulaLikeTextIsProtectedAndMissingAddressesStayEmpty() throws {
        var drive = trip(date(2026, 9, 17))
        drive.businessPurpose = "=1+1"
        drive.startAddress = nil
        drive.endAddress = nil
        let report = try makeReport([drive], vehicleNames: [drive.id: "@vehicle"])
        XCTAssertEqual(report.csvText, header + "\n09/17/2026,Business,'=1+1,'@vehicle,,,10.00,0,Manual")
    }

    @MainActor
    func testEmptyReportContainsOnlyTheSchema() throws {
        XCTAssertEqual(try makeReport([]).csvText, header)
    }

    @MainActor
    func testMergedTripAllocationsRetainYearMileageAndDoNotChangeStoredTrips() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let starts = [date(2025, 12, 31), date(2026, 1, 1)]
        let sources = try starts.map { start in
            try store.createManualTrip(ManualTripInput(
                startDate: start, endDate: start.addingTimeInterval(1800),
                startAddress: "Office", endAddress: "Client",
                distanceMeters: DistanceConversion.meters(fromMiles: 10),
                classification: .business, businessPurpose: "Client visit"
            ))
        }
        let merged = try store.mergeTrips(ids: sources.map(\.id))
        let rates = MileageRateSchedule(baseRate: MileageRate(amountPerUnit: 0.70, unit: .miles), rules: [
            MileageRateRule(effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 1, day: 1), rate: .default)
        ])
        let generator = ReportGenerator()
        let annual = try generator.makeAnnualReport(
            trips: [merged], odometerCheckpoints: [],
            startDate: date(2026, 1, 1, hour: 0), endDate: date(2026, 12, 31, hour: 23),
            rate: rates.baseRate, rateSchedule: rates, calendar: calendar,
            vehicleNamesByTripID: [merged.id: "Work car"], csvFormat: .quickBooks
        )
        let january = try generator.makeReport(
            trips: [merged], odometerCheckpoints: [],
            startDate: date(2026, 1, 1, hour: 0), endDate: date(2026, 1, 31, hour: 23),
            rate: rates.baseRate, rateSchedule: rates,
            vehicleNamesByTripID: [merged.id: "Work car"], calendar: calendar, csvFormat: .quickBooks
        )
        XCTAssertEqual(annual.csvText, header + "\n01/01/2026,Business,Client visit,Work car,Office,Client,10.00,0,Manual")
        XCTAssertEqual(january.csvText, annual.csvText)
        XCTAssertEqual(try store.fetchTrip(id: merged.id), merged)
    }

    @MainActor
    private func makeReport(
        _ trips: [TripSummary],
        vehicleNames: [UUID: String]? = nil,
        reportCalendar: Calendar? = nil
    ) throws -> ReportSnapshot {
        try ReportGenerator().makeReport(
            trips: trips, odometerCheckpoints: [],
            startDate: date(2026, 9, 1, hour: 0),
            endDate: date(2026, 10, 1, hour: 0).addingTimeInterval(-1),
            rate: MileageRate(amountPerUnit: 0.50, unit: .kilometers),
            formatting: ReportFormattingContext(locale: Locale(identifier: "de_DE"), distanceUnit: .kilometers, currencyCode: "EUR"),
            vehicleNamesByTripID: vehicleNames,
            calendar: reportCalendar ?? calendar,
            csvFormat: .quickBooks
        )
    }

    private func trip(_ start: Date, miles: Double = 10) -> TripSummary {
        TripSummary(
            id: UUID(), createdAt: start, updatedAt: start, captureSource: "automatic",
            startDate: start, endDate: start.addingTimeInterval(1800),
            startCoordinate: nil, endCoordinate: nil, startAddress: "Office", endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: miles), routePolyline: nil,
            classification: .business, reviewStatus: .readyToExport, businessPurpose: "Client visit",
            notes: nil, tollsAmount: 0, parkingAmount: 0, needsAttention: false, attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
    }
}
