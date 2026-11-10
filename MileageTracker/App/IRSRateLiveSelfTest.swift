#if DEBUG
import AppCore
import Foundation
import PDFKit

/// Explicit, isolated runtime verification. It never runs in a normal launch.
@MainActor
enum IRSRateLiveSelfTest {
    private static var started = false

    static func clientOverride(arguments: [String] = ProcessInfo.processInfo.arguments) -> (any IRSBusinessRateFetching)? {
        guard isRequested(arguments), let suffix = testSuffix(arguments) else { return nil }
        guard let directory = try? DerivedArtifactCacheRoot.prepareSubdirectory("irs-live-self-test", testSuffix: suffix) else { return nil }
        // A fresh cache proves this process actually invokes the production HTTP/parser pipeline.
        return IRSBusinessRateClient(cacheURL: directory.appendingPathComponent("irs-live-\(UUID().uuidString).json"))
    }

    static func run(model: MileageAppModel, arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard !started, isRequested(arguments), model.isUITesting,
              let suffix = testSuffix(arguments), model.derivedArtifactTestSuffix == suffix else { return }
        started = true
        let start = Date()
        var result = ResultRecord(runtime: runtime, storeSuffix: suffix)
        do {
            let directory = try DerivedArtifactCacheRoot.prepareSubdirectory("irs-live-self-test", testSuffix: suffix)
            let output = directory.appendingPathComponent("result.json")
            try write(result, to: output)
            NSLog("[irs-live-self-test] started output=%@", output.path)
            try require(!model.syncRunningThisLaunch, "CloudKit disabled", result: &result)
            try require(model.irsRateClientIsInjected, "Production client explicitly injected", result: &result)
            try require(model.hasCompletedStartupDataLoad, "App startup completed", result: &result)
            try require(model.currencyCode == "USD", "USD fixture currency", result: &result)

            if arguments.contains("--irs-live-self-test-verify-persistence") {
                // This branch must be relaunched without reset-data/reset-preferences.
                let previousURL = directory.appendingPathComponent("completed-result.json")
                let previous = try decoder().decode(ResultRecord.self, from: Data(contentsOf: previousURL))
                guard let expected = previous.schedule else { throw Failure("Prior completed schedule missing") }
                let saved = try model.mileageRateScheduleStore.fetchSchedule()
                try require(saved == expected && model.mileageRateSchedule == expected, "Schedule persisted across app relaunch", result: &result)
                for id in previous.tripIDs {
                    let trip = try model.tripStore.fetchTrip(id: id)
                    try require(trip.classification == .business && abs(trip.reportableDistanceMeters / DistanceUnit.miles.metersPerUnit - 10) < 0.0001, "Synthetic trip persisted: \(id)", result: &result)
                }
                for path in previous.artifactPaths {
                    try require(FileManager.default.fileExists(atPath: path), "Saved export persisted: \(URL(fileURLWithPath: path).lastPathComponent)", result: &result)
                }
                result.periods = previous.periods
                result.schedule = saved
                result.tripIDs = previous.tripIDs
                result.artifactPaths = previous.artifactPaths
                result.totals = previous.totals
            } else {
                let baseline = MileageRateSchedule(baseRate: MileageRate(amountPerUnit: 0.725, unit: .miles))
                try require(model.saveMileageRateSchedule(baseline, presentErrors: false), "Synthetic baseline saved", result: &result)
                guard let preview = await model.prepareIRSRateSetup() else {
                    throw Failure(model.irsRateStatusMessage ?? "Live IRS setup failed")
                }
                try require(model.mileageRateSchedule.irsFollowingFrom == nil, "Live setup requires explicit adoption", result: &result)
                let since = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
                let all = try await model.irsRateClient.fetchPeriods(since: since, now: model.irsRateNow(), force: false)
                result.periods = all
                let jan = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
                let jun = MileageRateEffectiveDate(year: 2026, month: 6, day: 30)
                let jul = MileageRateEffectiveDate(year: 2026, month: 7, day: 1)
                let dec = MileageRateEffectiveDate(year: 2026, month: 12, day: 31)
                try require(all.contains { $0.effectiveFrom == jan && $0.effectiveThrough == jun && abs($0.amountPerMile - 0.725) < 0.000001 }, "Live IRS January-June 2026 = USD 0.725/mile", result: &result)
                try require(all.contains { $0.effectiveFrom == jul && $0.effectiveThrough == dec && abs($0.amountPerMile - 0.76) < 0.000001 }, "Live IRS July-December 2026 = USD 0.76/mile", result: &result)
                try require(model.startFollowingIRSRate(periods: preview, replaceManual: false), "Explicit IRS adoption succeeded", result: &result)
                var schedule = try model.mileageRateScheduleStore.fetchSchedule()
                try require(schedule == model.mileageRateSchedule && schedule.irsFollowingFrom == jul, "Persisted opt-in starts July 1", result: &result)
                result.schedule = schedule

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
                    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
                }
                var trips: [TripSummary] = []
                for (month, day) in [(6, 30), (7, 1)] {
                    let startDate = date(month, day)
                    guard let trip = model.createManualTrip(
                        startDate: startDate, endDate: startDate.addingTimeInterval(1800), distanceMiles: 10,
                        origin: "Synthetic IRS QA origin", destination: "Synthetic IRS QA destination",
                        classification: .business, purpose: "IRS rate live self-test", notes: "Synthetic isolated QA data",
                        tolls: 0, parking: 0
                    ) else { throw Failure("Synthetic trip creation failed") }
                    trips.append(try model.tripStore.fetchTrip(id: trip.id))
                }
                result.tripIDs = trips.map(\.id)
                let freshnessWarning = await model.prepareIRSRateForExport()
                try require(freshnessWarning == nil, "Exports see verified fresh IRS schedule", result: &result)
                // Backfill may have expanded the schedule after importing the
                // June drive. Export the refreshed snapshot, as production does.
                schedule = try model.mileageRateScheduleStore.fetchSchedule()
                try require(schedule.irsFollowingFrom == jan, "Imported June drive backfills January history", result: &result)
                result.schedule = schedule
                let formatting = ReportFormattingContext(locale: Locale(identifier: "en_US"), distanceUnit: .miles, currencyCode: "USD", timeZone: calendar.timeZone)
                let annual = try model.reportGenerator.makeAnnualReport(
                    trips: trips, odometerCheckpoints: [], startDate: date(1, 1, hour: 0), endDate: date(12, 31, hour: 23),
                    rate: schedule.baseRate, rateSchedule: schedule, formatting: formatting, calendar: calendar
                )
                let june = try model.reportGenerator.makeReport(
                    trips: trips, odometerCheckpoints: [], startDate: date(6, 1, hour: 0), endDate: date(6, 30, hour: 23),
                    rate: schedule.baseRate, rateSchedule: schedule, formatting: formatting, calendar: calendar
                )
                let july = try model.reportGenerator.makeReport(
                    trips: trips, odometerCheckpoints: [], startDate: date(7, 1, hour: 0), endDate: date(7, 31, hour: 23),
                    rate: schedule.baseRate, rateSchedule: schedule, formatting: formatting, calendar: calendar
                )
                result.totals = ["juneMileageUSD": june.businessValue, "julyMileageUSD": july.businessValue, "annualMileageUSD": annual.businessValue]
                try require(abs(june.businessValue - 7.25) < 0.000001 && abs(july.businessValue - 7.60) < 0.000001, "Monthly values honor June/July rate boundary", result: &result)
                try require(abs(annual.businessValue - 14.85) < 0.000001 && abs(annual.businessValue - june.businessValue - july.businessValue) < 0.000001, "Annual value = monthly sum = USD 14.85", result: &result)
                try require(Set(annual.includedTripIDs) == Set(result.tripIDs), "Annual export includes both synthetic trips", result: &result)
                for (name, report, period) in [("annual", annual, MileageReportPeriod.year), ("june", june, .month), ("july", july, .month)] {
                    try ReportPDFValidator.validate(report.pdfData)
                    let files = try MileageReportFileWriter.write(report: report, period: period, logicalPeriodID: "irs-live-self-test-\(name)")
                    try require(try Data(contentsOf: files.pdfURL) == report.pdfData && String(contentsOf: files.csvURL, encoding: .utf8) == report.csvText, "\(name) PDF/CSV file write and readback", result: &result)
                    result.artifactPaths += [files.pdfURL.path, files.csvURL.path]
                }
                let annualText = PDFDocument(data: annual.pdfData)?.string ?? ""
                try require(annualText.contains("14.85") && annualText.contains("7.25") && annualText.contains("7.60"), "Annual PDF text contains correct totals", result: &result)
                try require(annual.csvText.contains("0.725") && annual.csvText.contains("0.760") && annual.csvText.contains("7.25") && annual.csvText.contains("7.60"), "Canonical CSV records both applied rates and amounts", result: &result)
                guard let tripURL = await model.exportTripPDF(trips[1]) else { throw Failure("App single-trip PDF export failed") }
                let tripData = try Data(contentsOf: tripURL)
                try ReportPDFValidator.validate(tripData)
                try require((PDFDocument(data: tripData)?.string ?? "").contains("7.60"), "App single-trip PDF uses July IRS rate", result: &result)
                result.artifactPaths.append(tripURL.path)
                let metric = try model.reportGenerator.makeReport(
                    trips: trips, odometerCheckpoints: [], startDate: date(1, 1, hour: 0), endDate: date(12, 31, hour: 23),
                    rate: schedule.baseRate, rateSchedule: schedule,
                    formatting: ReportFormattingContext(locale: Locale(identifier: "en_US"), distanceUnit: .kilometers, currencyCode: "USD", timeZone: calendar.timeZone), calendar: calendar
                )
                try require(abs(metric.businessValue - annual.businessValue) < 0.000001, "Kilometer display preserves reimbursement amount", result: &result)
            }
            result.status = "passed"
            result.elapsedSeconds = Date().timeIntervalSince(start)
            try write(result, to: output)
            if !arguments.contains("--irs-live-self-test-verify-persistence") {
                try write(result, to: directory.appendingPathComponent("completed-result.json"))
            }
            NSLog("[irs-live-self-test] passed checks=%ld output=%@", result.checks.count, output.path)
        } catch {
            result.status = "failed"
            result.error = String(describing: error)
            result.elapsedSeconds = Date().timeIntervalSince(start)
            if let directory = try? DerivedArtifactCacheRoot.prepareSubdirectory("irs-live-self-test", testSuffix: suffix) {
                try? write(result, to: directory.appendingPathComponent("result.json"))
            }
            NSLog("[irs-live-self-test] failed %@", String(describing: error))
        }
    }

    private static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--uitesting") && arguments.contains("--irs-live-self-test") && testSuffix(arguments) != nil
    }

    private static func testSuffix(_ arguments: [String]) -> String? {
        guard let argument = arguments.first(where: { $0.hasPrefix("--test-store-suffix=") }) else { return nil }
        let suffix = String(argument.dropFirst("--test-store-suffix=".count))
        return suffix.isEmpty ? nil : suffix
    }

    private static var runtime: String {
        #if targetEnvironment(simulator)
        "iOS simulator"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "Designed for iPad on Mac" : "Physical iOS device"
        #endif
    }

    private static func require(_ condition: Bool, _ name: String, result: inout ResultRecord) throws {
        result.checks.append(Check(name: name, passed: condition))
        guard condition else { throw Failure(name) }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }

    private static func write(_ result: ResultRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: url, options: .atomic)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Check: Codable {
        var name: String
        var passed: Bool
    }

    private struct ResultRecord: Codable {
        var status = "running"
        var runtime: String
        var storeSuffix: String
        var checks: [Check] = []
        var sourceURL = IRSBusinessRateClient.sourceURL.absoluteString
        var periods: [IRSBusinessRatePeriod] = []
        var schedule: MileageRateSchedule?
        var tripIDs: [UUID] = []
        var totals: [String: Double] = [:]
        var artifactPaths: [String] = []
        var error: String?
        var elapsedSeconds: Double?
    }
}
#endif
