import XCTest
@testable import AppCore

/// Characterization tests: pin the FULL CSV output of the monthly and annual
/// report paths byte-for-byte, so refactors inside ReportGenerator (formatter
/// extraction, row-pipeline changes) are provably behavior-preserving.
/// Existing report tests assert individual lines via `contains`; these lock
/// the stable flat schema, column order, row values, and CSV escaping too.
///
/// If one of these fails after an intentional output change, regenerate the
/// goldens by running with GOLDEN_DUMP_DIR=<dir> in the environment and
/// re-embedding the dumped files (escape U+202F as \u{202F}).
final class ReportGeneratorCharacterizationTests: XCTestCase {
    @MainActor
    func testMonthlyCSVGolden() throws {
        let report = try ReportGenerator().makeReport(
            trips: fixtureTrips(),
            odometerCheckpoints: fixtureCheckpoints(),
            startDate: nyDate(2026, 2, 1, 0, 0),
            endDate: nyDate(2026, 2, 28, 23, 59),
            rate: MileageRate(amountPerUnit: 0.725, unit: .miles),
            formatting: .enUS,
            vehicleNamesByTripID: fixtureVehicleNames(),
            calendar: newYorkCalendar
        )
        assertGolden(report.csvText, Self.monthlyGolden, dumpLabel: "MONTHLY")
    }

    @MainActor
    func testAnnualCSVGolden() throws {
        let report = try ReportGenerator().makeAnnualReport(
            trips: fixtureTrips(),
            odometerCheckpoints: fixtureCheckpoints(),
            startDate: nyDate(2026, 1, 1, 0, 0),
            endDate: nyDate(2026, 12, 31, 23, 59),
            rate: MileageRate(amountPerUnit: 0.725, unit: .miles),
            formatting: .enUS,
            calendar: newYorkCalendar,
            vehicleNamesByTripID: fixtureVehicleNames()
        )
        assertGolden(report.csvText, Self.annualGolden, dumpLabel: "ANNUAL")
    }

    @MainActor
    func testCanonicalCSVPreservesOvernightEndDate() throws {
        let overnight = trip(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            purpose: "Overnight delivery",
            miles: 4,
            captureSource: "manual",
            legs: [leg(
                from: "Warehouse",
                nyDate(2026, 2, 3, 23, 45),
                to: "Client",
                nyDate(2026, 2, 4, 0, 15),
                miles: 4
            )]
        )

        let report = try ReportGenerator().makeReport(
            trips: [overnight],
            odometerCheckpoints: [],
            startDate: nyDate(2026, 2, 1, 0, 0),
            endDate: nyDate(2026, 2, 28, 23, 59),
            rate: .default,
            formatting: .enUS,
            calendar: newYorkCalendar
        )

        XCTAssertTrue(
            report.csvText.contains(",2026-02-03,23:45:00,2026-02-04,00:15:00,America/New_York,30.00,"),
            report.csvText
        )
        XCTAssertTrue(report.csvText.contains(",Business,,Manual,Overnight delivery,"), report.csvText)
    }

    @MainActor
    func testCSVNeutralizesSpreadsheetFormulaPrefixesInUserText() throws {
        let prefixes = ["=2+2", "+2+2", "-2+2", "@SUM(A1:A2)", "\t=2+2", "\r=2+2"]
        let trips = prefixes.enumerated().map { index, purpose in
            trip(
                id: UUID(),
                purpose: purpose,
                notes: index == 0 ? " =3+3" : nil,
                miles: 1,
                legs: [leg(
                    from: index == 0 ? "@START" : "Start",
                    nyDate(2026, 2, 20, 9, index),
                    to: "End",
                    nyDate(2026, 2, 20, 9, index + 1),
                    miles: 1
                )]
            )
        }

        let report = try ReportGenerator().makeReport(
            trips: trips,
            odometerCheckpoints: [],
            startDate: nyDate(2026, 2, 1, 0, 0),
            endDate: nyDate(2026, 2, 28, 23, 59),
            rate: .default,
            formatting: .enUS,
            calendar: newYorkCalendar
        )

        for prefix in prefixes {
            let protected = prefix.contains("\r") ? "\"'\(prefix)\"" : "'\(prefix)"
            XCTAssertTrue(report.csvText.contains(protected), "Missing protected value \(prefix.debugDescription): \(report.csvText)")
        }
        XCTAssertTrue(report.csvText.contains("'@START"), report.csvText)
        XCTAssertTrue(report.csvText.contains("' =3+3"), report.csvText)
    }

    @MainActor
    func testMonthlyReportAppliesEffectiveRateToEachTrip() throws {
        let schedule = MileageRateSchedule(
            baseRate: MileageRate(amountPerUnit: 0.50, unit: .miles),
            rules: [MileageRateRule(
                effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 2, day: 5),
                rate: MileageRate(amountPerUnit: 1.00, unit: .miles)
            )]
        )
        let report = try ReportGenerator().makeReport(
            trips: fixtureTrips(),
            odometerCheckpoints: [],
            startDate: nyDate(2026, 2, 1, 0, 0),
            endDate: nyDate(2026, 2, 28, 23, 59),
            rate: schedule.baseRate,
            rateSchedule: schedule,
            formatting: .enUS,
            calendar: newYorkCalendar
        )

        XCTAssertEqual(report.businessValue, 25.00)
        XCTAssertTrue(report.csvText.contains("Client visit,\"Parked in \"\"Lot B\"\", met Sam\",0.500,USD,5.00"))
        XCTAssertTrue(report.csvText.contains("Gallery delivery,,1.000,USD,20.00"))
    }

    // MARK: - Golden output

    // Canonical times deliberately use locale-independent 24-hour formatting.
    private static let monthlyGolden = """
Trip ID,Report Month,Start Date,Start Time,End Date,End Time,Time Zone,Duration Minutes,Origin,Destination,Reported Distance,Distance Unit,Original Recorded Distance,Distance Adjusted,Classification,Vehicle,Entry Method,Business Purpose,Notes,Mileage Rate,Currency,Mileage Amount,Tolls,Parking,Total Amount,Leg Count,Stop Count,Leg Details
11111111-1111-1111-1111-111111111111,2026-02,2026-02-03,09:00:00,2026-02-03,09:45:00,America/New_York,45.00,"22 Brindle St, Cambridge, MA 02139","10 Lunaris St, Dorchester, MA 02122",10.00,mi,9.50,Yes,Business,Honda Fit,Automatic,Client visit,"Parked in ""Lot B"", met Sam",0.725,USD,7.25,2.50,8.00,17.75,1,0,
22222222-2222-2222-2222-222222222222,2026-02,2026-02-10,10:00:00,2026-02-10,12:30:00,America/New_York,150.00,"22 Brindle St, Cambridge, MA 02139","22 Brindle St, Cambridge, MA 02139",20.00,mi,20.00,No,Business,Honda Fit,Merged,Gallery delivery,,0.725,USD,14.50,0.00,0.00,14.50,2,1,"Leg 1: 2026-02-10 10:00:00 to 2026-02-10 10:30:00 | 22 Brindle St, Cambridge, MA 02139 to Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143 | 12.50 mi stop 90 min
Leg 2: 2026-02-10 12:00:00 to 2026-02-10 12:30:00 | Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143 to 22 Brindle St, Cambridge, MA 02139 | 7.50 mi"
"""

    private static let annualGolden = """
Trip ID,Report Month,Start Date,Start Time,End Date,End Time,Time Zone,Duration Minutes,Origin,Destination,Reported Distance,Distance Unit,Original Recorded Distance,Distance Adjusted,Classification,Vehicle,Entry Method,Business Purpose,Notes,Mileage Rate,Currency,Mileage Amount,Tolls,Parking,Total Amount,Leg Count,Stop Count,Leg Details
11111111-1111-1111-1111-111111111111,2026-02,2026-02-03,09:00:00,2026-02-03,09:45:00,America/New_York,45.00,"22 Brindle St, Cambridge, MA 02139","10 Lunaris St, Dorchester, MA 02122",10.00,mi,9.50,Yes,Business,Honda Fit,Automatic,Client visit,"Parked in ""Lot B"", met Sam",0.725,USD,7.25,2.50,8.00,17.75,1,0,
22222222-2222-2222-2222-222222222222,2026-02,2026-02-10,10:00:00,2026-02-10,12:30:00,America/New_York,150.00,"22 Brindle St, Cambridge, MA 02139","22 Brindle St, Cambridge, MA 02139",20.00,mi,20.00,No,Business,Honda Fit,Merged,Gallery delivery,,0.725,USD,14.50,0.00,0.00,14.50,2,1,"Leg 1: 2026-02-10 10:00:00 to 2026-02-10 10:30:00 | 22 Brindle St, Cambridge, MA 02139 to Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143 | 12.50 mi stop 90 min
Leg 2: 2026-02-10 12:00:00 to 2026-02-10 12:30:00 | Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143 to 22 Brindle St, Cambridge, MA 02139 | 7.50 mi"
33333333-3333-3333-3333-333333333333,2026-03,2026-03-05,14:00:00,2026-03-05,14:30:00,America/New_York,30.00,"12.48362, -41.14783","12.41235, -41.09651",5.50,mi,5.50,No,Business,Sprinter Van,Manual,Location scout,,0.725,USD,3.99,0.00,0.00,3.99,1,0,
"""

    private func assertGolden(_ actual: String, _ expected: String, dumpLabel: String) {
        if let dumpDirectory = ProcessInfo.processInfo.environment["GOLDEN_DUMP_DIR"] {
            try? actual.write(
                to: URL(fileURLWithPath: dumpDirectory).appendingPathComponent("golden-\(dumpLabel).csv"),
                atomically: true,
                encoding: .utf8
            )
        }
        XCTAssertEqual(actual, expected)
    }

    // MARK: - Fixture
    // Stable IDs so vehicleNamesByTripID is deterministic. Trip 1: fees +
    // notes containing a comma AND a quote (pins escapeCSV). Trip 2:
    // multi-leg (pins legDetails). Trip 3: coordinate-only endpoints (pins
    // endpointText fallback). Personal trip must stay excluded.

    private let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let id3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let idPersonal = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func fixtureVehicleNames() -> [UUID: String] {
        [id1: "Honda Fit", id2: "Honda Fit", id3: "Sprinter Van"]
    }

    private func fixtureCheckpoints() -> [OdometerCheckpoint] {
        [
            OdometerCheckpoint(id: UUID(), date: nyDate(2026, 1, 1, 9, 0), odometerMiles: 42000),
            OdometerCheckpoint(id: UUID(), date: nyDate(2026, 12, 31, 9, 0), odometerMiles: 54000)
        ]
    }

    private func fixtureTrips() -> [TripSummary] {
        let brindle = "22 Brindle St, Cambridge, MA 02139"
        let lunaris = "10 Lunaris St, Dorchester, MA 02122"
        let moonspire = "Moonspire Labs, 444 Silvermist Ave, Somerville, MA 02143"
        return [
            trip(
                id: id1,
                purpose: "Client visit",
                notes: "Parked in \"Lot B\", met Sam",
                miles: 10.0, recordedMiles: 9.5, tolls: 2.50, parking: 8.00,
                captureSource: "automatic",
                legs: [leg(from: brindle, nyDate(2026, 2, 3, 9, 0), to: lunaris, nyDate(2026, 2, 3, 9, 45), miles: 10.0)]
            ),
            trip(
                id: id2,
                purpose: "Gallery delivery",
                miles: 20.0,
                legs: [
                    leg(from: brindle, nyDate(2026, 2, 10, 10, 0), to: moonspire, nyDate(2026, 2, 10, 10, 30), miles: 12.5),
                    leg(from: moonspire, nyDate(2026, 2, 10, 12, 0), to: brindle, nyDate(2026, 2, 10, 12, 30), miles: 7.5)
                ]
            ),
            trip(
                id: id3,
                purpose: "Location scout",
                miles: 5.5,
                captureSource: "manual",
                coordinateOnly: true,
                legs: [leg(from: nil, nyDate(2026, 3, 5, 14, 0), to: nil, nyDate(2026, 3, 5, 14, 30), miles: 5.5, coordinateOnly: true)]
            ),
            trip(
                id: idPersonal,
                purpose: "",
                miles: 12.0,
                classification: .personal,
                legs: [leg(from: lunaris, nyDate(2026, 2, 14, 9, 0), to: brindle, nyDate(2026, 2, 14, 9, 40), miles: 12.0)]
            )
        ]
    }

    private var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func nyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        newYorkCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date(timeIntervalSince1970: 0)
    }

    /// The route filler raises `lowConfidenceAttentionReason` on the branch
    /// where it *declines* to change anything — the trip keeps the raw GPS
    /// distance it was captured with. Withholding that mileage under-claimed
    /// silently, and on a real device this flag was the only one produced, so
    /// this is the regression that guards the leak.
    @MainActor
    func testFlaggedBusinessTripStillEntersMonthlyAndAnnualReports() throws {
        var flagged = trip(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            purpose: "Flagged client visit",
            miles: 12,
            legs: [leg(
                from: "1 Astraea Sq, Cambridge, MA",
                nyDate(2026, 2, 12, 9, 0),
                to: "24 Brindle St, Cambridge, MA",
                nyDate(2026, 2, 12, 10, 0),
                miles: 12
            )]
        )
        flagged.needsAttention = true
        flagged.attentionReasons = [AutomaticRouteFiller.lowConfidenceAttentionReason]
        flagged.reviewStatus = .needsAttention

        let monthly = try ReportGenerator().makeReport(
            trips: [flagged],
            odometerCheckpoints: [],
            startDate: nyDate(2026, 2, 1, 0, 0),
            endDate: nyDate(2026, 2, 28, 23, 59),
            rate: .default,
            formatting: .enUS,
            calendar: newYorkCalendar
        )
        let annual = try ReportGenerator().makeAnnualReport(
            trips: [flagged],
            odometerCheckpoints: [],
            startDate: nyDate(2026, 1, 1, 0, 0),
            endDate: nyDate(2026, 12, 31, 23, 59),
            rate: .default,
            formatting: .enUS,
            calendar: newYorkCalendar
        )

        for report in [monthly, annual] {
            XCTAssertEqual(report.includedTripIDs, [flagged.id])
            XCTAssertEqual(report.businessMiles, 12, accuracy: 0.001)
            XCTAssertGreaterThan(report.businessValue, 0)
            XCTAssertTrue(report.csvText.contains("Flagged client visit"))
        }
    }

    private func leg(
        from origin: String?,
        _ start: Date,
        to destination: String?,
        _ end: Date,
        miles: Double,
        coordinateOnly: Bool = false
    ) -> TripLeg {
        TripLeg(
            captureSource: "test",
            startDate: start,
            endDate: end,
            startCoordinate: coordinateOnly ? Coordinate(latitude: 12.48362, longitude: -41.14783) : nil,
            endCoordinate: coordinateOnly ? Coordinate(latitude: 12.41235, longitude: -41.09651) : nil,
            startAddress: origin,
            endAddress: destination,
            distanceMeters: DistanceConversion.meters(fromMiles: miles),
            routePolyline: nil
        )
    }

    private func trip(
        id: UUID,
        purpose: String,
        notes: String? = nil,
        miles: Double,
        recordedMiles: Double? = nil,
        tolls: Double = 0,
        parking: Double = 0,
        captureSource: String = "test",
        classification: TripClassification? = .business,
        coordinateOnly: Bool = false,
        legs: [TripLeg]
    ) -> TripSummary {
        let start = legs.first?.startDate ?? Date(timeIntervalSince1970: 0)
        let end = legs.last?.endDate ?? start
        return TripSummary(
            id: id,
            createdAt: start,
            updatedAt: end,
            captureSource: captureSource,
            startDate: start,
            endDate: end,
            startCoordinate: coordinateOnly ? Coordinate(latitude: 12.48362, longitude: -41.14783) : nil,
            endCoordinate: coordinateOnly ? Coordinate(latitude: 12.41235, longitude: -41.09651) : nil,
            startAddress: legs.first?.startAddress,
            endAddress: legs.last?.endAddress,
            distanceMeters: DistanceConversion.meters(fromMiles: recordedMiles ?? miles),
            routePolyline: nil,
            classification: classification,
            reviewStatus: .readyToExport,
            businessPurpose: purpose.isEmpty ? nil : purpose,
            notes: notes,
            tollsAmount: tolls,
            parkingAmount: parking,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: recordedMiles == nil ? nil : DistanceConversion.meters(fromMiles: miles),
            legs: legs
        )
    }
}

private extension ReportFormattingContext {
    static let enUS = ReportFormattingContext(
        locale: Locale(identifier: "en_US"),
        distanceUnit: .miles,
        currencyCode: "USD"
    )
}
