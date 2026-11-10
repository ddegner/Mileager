import AppCore
import Foundation
import PDFKit
import XCTest
@testable import MileageTracker

private actor IRSRateTestClient: IRSBusinessRateFetching {
    let periods: [IRSBusinessRatePeriod]
    let delay: Duration
    let fails: Bool
    private(set) var calls = 0
    private(set) var requestedDates: [MileageRateEffectiveDate] = []

    init(periods: [IRSBusinessRatePeriod], delay: Duration = .zero, fails: Bool = false) {
        self.periods = periods
        self.delay = delay
        self.fails = fails
    }

    func fetchPeriods(since: MileageRateEffectiveDate, now: Date, force: Bool) async throws -> [IRSBusinessRatePeriod] {
        calls += 1
        requestedDates.append(since)
        // Deliberately return a late response even if cancelled: the app must
        // reject it independently of whether the remote model cooperates.
        await Task.detached { [delay] in try? await Task.sleep(for: delay) }.value
        if fails { throw URLError(.notConnectedToInternet) }
        return periods.filter { $0.effectiveThrough >= since }
    }
}

@MainActor
final class IRSRateUpdateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000) // July 25, 2026
    private var january: MileageRateEffectiveDate { .init(year: 2026, month: 1, day: 1) }
    private var july: MileageRateEffectiveDate { .init(year: 2026, month: 7, day: 1) }

    private func period(_ from: MileageRateEffectiveDate, through: MileageRateEffectiveDate, amount: Double) -> IRSBusinessRatePeriod {
        IRSBusinessRatePeriod(effectiveFrom: from, effectiveThrough: through, amountPerMile: amount,
            sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
            rateEvidence: "Business: \(amount * 100) cents/mile", periodEvidence: "\(from.year)-\(from.month)-\(from.day)")
    }

    private var periods: [IRSBusinessRatePeriod] {
        [period(january, through: .init(year: 2026, month: 6, day: 30), amount: 0.725),
         period(july, through: .init(year: 2026, month: 12, day: 31), amount: 0.76),
         period(.init(year: 2027, month: 1, day: 1), through: .init(year: 2027, month: 12, day: 31), amount: 0.80)]
    }

    private func model(client: IRSRateTestClient, defaults: UserDefaults? = nil, following: Bool = true) throws -> MileageAppModel {
        let value = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: try defaults ?? makeTestDefaults()), irsRateClient: client
        )
        value.setCurrencyCode("USD")
        value.irsRateNow = { [now] in now }
        if following {
            var schedule = MileageRateSchedule(baseRate: .init(amountPerUnit: 0.70, unit: .miles),
                rules: [.init(effectiveFrom: january, rate: periods[0].rate, irsSource: periods[0])])
            schedule.irsFollowingFrom = january
            schedule.sourceSelectionUpdatedAt = now.addingTimeInterval(-86_400)
            XCTAssertTrue(value.saveMileageRateSchedule(schedule))
        } else {
            XCTAssertTrue(value.saveMileageRateSchedule(.default))
        }
        return value
    }

    func testCadenceWindowsAndLateOpeningUseGregorianDates() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .gmt
        func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
            try XCTUnwrap(gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }
        for components in [(2026,12,29), (2027,1,14), (2026,6,28), (2026,7,14)] {
            let today = try date(components.0, components.1, components.2)
            XCTAssertTrue(IRSRateCheckCadence.isDue(lastAttempt: today.addingTimeInterval(-86_400), now: today, calendar: gregorian))
            XCTAssertFalse(IRSRateCheckCadence.isDue(lastAttempt: today.addingTimeInterval(-60), now: today, calendar: gregorian))
            var buddhist = Calendar(identifier: .buddhist)
            buddhist.timeZone = .gmt
            XCTAssertTrue(IRSRateCheckCadence.isDue(lastAttempt: today.addingTimeInterval(-86_400), now: today, calendar: buddhist))
        }
        let outside = try date(2026,10,3)
        XCTAssertFalse(IRSRateCheckCadence.isDue(lastAttempt: outside.addingTimeInterval(-6*86_400), now: outside, calendar: gregorian))
        XCTAssertTrue(IRSRateCheckCadence.isDue(lastAttempt: outside.addingTimeInterval(-90*86_400), now: outside, calendar: gregorian))
        XCTAssertTrue(IRSRateCheckCadence.isDue(lastAttempt: outside.addingTimeInterval(100), now: outside, calendar: gregorian))
    }

    func testSetupRequiresExplicitAdoptionAndPreservesHistoryWhenStopped() async throws {
        let client = IRSRateTestClient(periods: periods)
        let value = try model(client: client, following: false)
        let before = value.mileageRateSchedule
        let preview = await value.prepareIRSRateSetup()
        let verified = try XCTUnwrap(preview)
        XCTAssertEqual(value.mileageRateSchedule, before)
        XCTAssertEqual(verified.map(\.effectiveFrom), [july, .init(year: 2027, month: 1, day: 1)])
        XCTAssertTrue(value.startFollowingIRSRate(periods: verified, replaceManual: false))
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, july)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
        let accepted = value.mileageRateSchedule.rules
        value.stopFollowingIRSRate()
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(value.mileageRateSchedule.rules, accepted)
    }

    func testConcurrentExportJoinsCheckAndUsesCaughtUpRate() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(40))
        let value = try model(client: client)
        XCTAssertNotNil(value.createManualTrip(startDate: now, endDate: now.addingTimeInterval(600), distanceMiles: 10,
            origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0))
        let exportDate = now
        async let check = value.refreshIRSRateIfDue()
        async let export = value.prepareMonthlyReportExport(forMonthContaining: exportDate)
        let (success, files) = try await (check, export)
        defer { for url in [files.pdfURL, files.csvURL] { try? FileManager.default.removeItem(at: url) } }
        XCTAssertTrue(success)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(files.report.businessValue, 7.60, accuracy: 0.001)
        XCTAssertNil(files.rateFreshnessMessage)
        XCTAssertEqual(value.mileageRateSchedule.rules.count, 3)
        let accepted = value.mileageRateSchedule
        await value.checkIRSRateNow()
        XCTAssertEqual(value.mileageRateSchedule, accepted)
    }

    func testOfflineExportUsesSavedRatesAndIdentifiesFreshness() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, fails: true))
        XCTAssertNotNil(value.createManualTrip(startDate: now, endDate: now.addingTimeInterval(600), distanceMiles: 10,
            origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0))
        let files = try await value.prepareMonthlyReportExport(forMonthContaining: now)
        defer { for url in [files.pdfURL, files.csvURL] { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(files.report.businessValue, 7.25, accuracy: 0.001)
        let message = try XCTUnwrap(files.rateFreshnessMessage)
        let share = ActivityShareItem(url: files.pdfURL, notice: message)
        XCTAssertEqual(share.notice, message)
        XCTAssertFalse(files.report.csvText.contains(message))
    }

    func testManualConflictWaitsForReview() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods))
        var schedule = value.mileageRateSchedule
        schedule.rules.append(.init(effectiveFrom: july, rate: .init(amountPerUnit: 0.50, unit: .miles)))
        XCTAssertTrue(value.saveMileageRateSchedule(schedule))
        await value.checkIRSRateNow()
        XCTAssertTrue(value.irsRateHasConflicts)
        XCTAssertEqual(value.mileageRateSchedule, schedule)
        value.resolveIRSRateConflicts(replaceManual: true)
        XCTAssertFalse(value.irsRateHasConflicts)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
    }

    func testCurrencyChangeCancelsPendingCommit() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(80))
        let value = try model(client: client)
        let accepted = value.mileageRateSchedule.rules
        let pending = Task { await value.checkIRSRateNow() }
        while !value.irsRateIsChecking { await Task.yield() }
        value.setCurrencyCode("EUR")
        await pending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(value.mileageRateSchedule.rules, accepted)
        XCTAssertFalse(value.irsRateIsChecking)
    }

    func testBackgroundCancellationAllowsRetryAndRejectsLateResponse() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(80))
        let value = try model(client: client)
        let saved = value.mileageRateSchedule
        let previousCheck = now.addingTimeInterval(-60)
        value.preferences.irsRateLastAttempt = previousCheck
        value.preferences.irsRateLastSuccessfulCheck = previousCheck
        let pending = Task { await value.checkIRSRateNow() }
        while !value.irsRateIsChecking { await Task.yield() }
        value.appEnteredBackground()
        await pending.value
        XCTAssertEqual(value.preferences.irsRateLastAttempt, previousCheck)
        XCTAssertTrue(value.preferences.irsRateCheckNeedsRetry)
        XCTAssertEqual(value.mileageRateSchedule, saved)
        let retried = await value.refreshIRSRateIfDue()
        XCTAssertTrue(retried)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
    }

    func testTimeoutBoundsExportAndKeepsSavedRates() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, delay: .seconds(2)))
        value.irsRateCheckTimeout = .milliseconds(20)
        let before = value.mileageRateSchedule
        let start = ContinuousClock.now
        let message = await value.prepareIRSRateForExport()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertNotNil(message)
        XCTAssertEqual(value.mileageRateSchedule, before)
        XCTAssertFalse(value.irsRateIsChecking)
    }

    func testFailedAttemptRemainsUnverifiedAfterRelaunch() async throws {
        let defaults = try makeTestDefaults()
        let client = IRSRateTestClient(periods: periods, fails: true)
        let value = try model(client: client, defaults: defaults)
        value.preferences.irsRateLastSuccessfulCheck = now.addingTimeInterval(-8*86_400)
        await value.checkIRSRateNow()
        let message = await value.prepareIRSRateForExport()
        XCTAssertNotNil(message)
        let relaunched = try model(client: client, defaults: defaults)
        XCTAssertNil(relaunched.irsRateStatusMessage)
        let relaunchedMessage = await relaunched.prepareIRSRateForExport()
        XCTAssertNotNil(relaunchedMessage)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testStopFollowingPreservesNewlyImportedScheduledRates() throws {
        let value = try model(client: IRSRateTestClient(periods: periods))
        var imported = value.mileageRateSchedule
        let future = MileageRateRule(effectiveFrom: .init(year: 2028, month: 1, day: 1),
            rate: .init(amountPerUnit: 0.90, unit: .miles))
        imported.rules.append(future)
        _ = try value.mileageRateScheduleStore.saveSchedule(imported)
        XCTAssertFalse(value.mileageRateSchedule.rules.contains { $0.id == future.id })
        XCTAssertTrue(value.stopFollowingIRSRate())
        XCTAssertTrue(value.mileageRateSchedule.rules.contains { $0.id == future.id })
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
    }

    func testAdoptionReplacesNewlyImportedCustomRulesBeyondVerifiedCoverage() throws {
        let value = try model(client: IRSRateTestClient(periods: periods), following: false)
        var imported = value.mileageRateSchedule
        let future = MileageRateRule(effectiveFrom: .init(year: 2028, month: 1, day: 1),
            rate: .init(amountPerUnit: 0.90, unit: .miles))
        imported.rules.append(future)
        _ = try value.mileageRateScheduleStore.saveSchedule(imported)
        XCTAssertTrue(value.startFollowingIRSRate(periods: periods, replaceManual: false))
        XCTAssertFalse(value.mileageRateSchedule.rules.contains { $0.id == future.id })
        XCTAssertNotNil(value.mileageRateSchedule.deletedRuleIDs[future.id])
        XCTAssertTrue(value.mileageRateSchedule.rules.allSatisfy { $0.irsSource != nil })
    }

    func testAnnualCatchUpUsesEffectiveDatesAndLeavesEarlierExportedFilesUnchanged() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods))
        let calendar = Calendar(identifier: .gregorian)
        let june30 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 12)))
        let july1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12)))
        for date in [june30, july1] {
            XCTAssertNotNil(value.createManualTrip(startDate: date, endDate: date.addingTimeInterval(600), distanceMiles: 10,
                origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0))
        }
        let oldSnapshot = try XCTUnwrap(value.generateMonthlyReport(forMonthContaining: july1))
        let saved = try MileageReportFileWriter.write(report: oldSnapshot)
        let savedPDF = try Data(contentsOf: saved.pdfURL)
        let savedCSV = try Data(contentsOf: saved.csvURL)
        let annual = try await value.prepareAnnualReportExport(forYearContaining: now)
        defer {
            for url in [saved.pdfURL, saved.csvURL, annual.pdfURL, annual.csvURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        XCTAssertEqual(oldSnapshot.businessValue, 7.25, accuracy: 0.001)
        XCTAssertEqual(annual.report.businessValue, 14.85, accuracy: 0.001)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: june30).amountPerUnit, 0.725)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: july1).amountPerUnit, 0.76)
        XCTAssertEqual(try Data(contentsOf: saved.pdfURL), savedPDF)
        XCTAssertEqual(try Data(contentsOf: saved.csvURL), savedCSV)
        XCTAssertNil(annual.rateFreshnessMessage)
    }

    func testSingleTripPDFJoinsPendingCheckAndUsesUpdatedAmount() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(80))
        let value = try model(client: client)
        let trip = try XCTUnwrap(value.createManualTrip(startDate: now, endDate: now.addingTimeInterval(600), distanceMiles: 10,
            origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0))
        let check = Task { await value.refreshIRSRateIfDue() }
        while !value.irsRateIsChecking { await Task.yield() }
        let exportedURL = await value.exportTripPDF(trip)
        let url = try XCTUnwrap(exportedURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let success = await check.value
        XCTAssertTrue(success)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue((pdf.string ?? "").contains("$7.60"), pdf.string ?? "Missing PDF text")
        XCTAssertNil(value.irsRateExportStatusMessage)
    }

    func testSyncedCustomSelectionDuringCheckRejectsStaleIRSResponse() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(80))
        let value = try model(client: client)
        let pending = Task { await value.checkIRSRateNow() }
        while !value.irsRateIsChecking { await Task.yield() }
        var synced = IRSBusinessRateScheduleUpdater.stopFollowing(value.mileageRateSchedule, now: now.addingTimeInterval(1))
        synced.rules.append(.init(effectiveFrom: july, rate: .init(amountPerUnit: 0.99, unit: .miles)))
        synced = try value.mileageRateScheduleStore.saveSchedule(synced)
        await pending.value
        XCTAssertEqual(value.mileageRateSchedule, synced)
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.99)
        XCTAssertNil(value.preferences.irsRateLastSuccessfulCheck)
        XCTAssertFalse(value.irsRateIsChecking)
    }

    func testSyncedCurrencyChangeDuringCheckStopsFollowingWithoutApplyingResponse() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, delay: .milliseconds(80)))
        let accepted = value.mileageRateSchedule.rules
        let pending = Task { await value.checkIRSRateNow() }
        while !value.irsRateIsChecking { await Task.yield() }
        try value.unitsCurrencyStore.saveCurrencyCode("EUR")
        await pending.value
        XCTAssertEqual(value.currencyCode, "EUR")
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(value.mileageRateSchedule.rules, accepted)
        XCTAssertFalse(value.irsRateIsChecking)
    }

    func testNonCooperativeLateResultCannotCommitAfterDeadline() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, delay: .milliseconds(150)))
        XCTAssertEqual(value.irsRateCheckTimeout, .seconds(15))
        value.irsRateCheckTimeout = .milliseconds(20)
        let saved = value.mileageRateSchedule
        let message = await value.prepareIRSRateForExport()
        XCTAssertNotNil(message)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertNil(value.preferences.irsRateLastSuccessfulCheck)
        XCTAssertFalse(value.irsRateIsChecking)
    }

    func testSyntheticUIRatesRequireExplicitIsolatedTestingFlag() {
        XCTAssertNil(IRSRateUITestFixture.configuration(arguments: ["MileageTracker", "--irs-rate-fixture=following"]))
        XCTAssertNil(IRSRateUITestFixture.configuration(arguments: ["MileageTracker", "--uitesting", "--irs-rate-fixture=unknown"]))
        XCTAssertNotNil(IRSRateUITestFixture.configuration(arguments: ["MileageTracker", "--uitesting", "--irs-rate-fixture=following"]))
    }

    func testLiveSelfTestRequiresIsolatedTestingAndExplicitStoreSuffix() {
        XCTAssertNil(IRSRateLiveSelfTest.clientOverride(arguments: ["MileageTracker", "--irs-live-self-test"]))
        XCTAssertNil(IRSRateLiveSelfTest.clientOverride(arguments: ["MileageTracker", "--irs-live-self-test", "--test-store-suffix=qa"]))
        XCTAssertNil(IRSRateLiveSelfTest.clientOverride(arguments: ["MileageTracker", "--uitesting", "--irs-live-self-test"]))
        XCTAssertNil(IRSRateLiveSelfTest.clientOverride(arguments: ["MileageTracker", "--uitesting", "--irs-live-self-test", "--test-store-suffix="]))
    }

    private func addBusinessTrip(to value: MileageAppModel, on day: MileageRateEffectiveDate) throws {
        let start = try XCTUnwrap(day.date()).addingTimeInterval(12 * 60 * 60)
        XCTAssertNotNil(value.createManualTrip(startDate: start, endDate: start.addingTimeInterval(600), distanceMiles: 10,
            origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0))
    }

    func testSetupCoversFirstDriveAndReplacesAllCustomAmountsAfterExplicitAdoption() async throws {
        let prior = period(.init(year: 2025, month: 1, day: 1), through: .init(year: 2025, month: 12, day: 31), amount: 0.70)
        let client = IRSRateTestClient(periods: [prior] + periods)
        let value = try model(client: client, following: false)
        let firstDrive = MileageRateEffectiveDate(year: 2025, month: 11, day: 10)
        try addBusinessTrip(to: value, on: firstDrive)
        let custom = [MileageRateRule(effectiveFrom: .init(year: 2024, month: 1, day: 1), rate: .init(amountPerUnit: 0.50, unit: .miles)),
                      MileageRateRule(effectiveFrom: .init(year: 2028, month: 1, day: 1), rate: .init(amountPerUnit: 0.90, unit: .miles))]
        let saved = MileageRateSchedule(baseRate: .init(amountPerUnit: 0.40, unit: .miles), rules: custom)
        XCTAssertTrue(value.saveMileageRateSchedule(saved))
        let result = await value.prepareIRSRateSetup()
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(value.mileageRateHistoryStartDate, firstDrive)
        XCTAssertEqual(value.irsRateSetupFollowingFrom, prior.effectiveFrom)
        XCTAssertEqual(preview.map(\.effectiveFrom), [prior.effectiveFrom] + periods.map(\.effectiveFrom))
        XCTAssertEqual(value.mileageRateSchedule, saved, "Preview alone must preserve custom rates")
        let requested = await client.requestedDates
        XCTAssertEqual(requested, [firstDrive])
        XCTAssertTrue(value.startFollowingIRSRate(periods: preview, replaceManual: true))
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, prior.effectiveFrom)
        XCTAssertEqual(value.mileageRateSchedule.baseRate, prior.rate)
        XCTAssertTrue(value.mileageRateSchedule.rules.allSatisfy { $0.irsSource != nil })
        for rule in custom { XCTAssertNotNil(value.mileageRateSchedule.deletedRuleIDs[rule.id]) }
        XCTAssertEqual(value.mileageRateSchedule.rate(on: try XCTUnwrap(firstDrive.date())).amountPerUnit, 0.70)
        let accepted = value.mileageRateSchedule.rules
        XCTAssertTrue(value.stopFollowingIRSRate())
        XCTAssertEqual(value.mileageRateSchedule.rules, accepted)
    }

    func testSetupCannotAdoptWhenFirstDriveHistoryIsMissing() async throws {
        let value = try model(client: IRSRateTestClient(periods: Array(periods.dropFirst())), following: false)
        try addBusinessTrip(to: value, on: .init(year: 2026, month: 6, day: 30))
        let saved = value.mileageRateSchedule
        let preview = await value.prepareIRSRateSetup()
        XCTAssertNil(preview)
        XCTAssertNil(value.irsRateSetupFollowingFrom)
        XCTAssertFalse(value.startFollowingIRSRate(periods: Array(periods.dropFirst()), replaceManual: true))
        XCTAssertEqual(value.mileageRateSchedule, saved)
    }

    func testImportingEarlierDriveBackfillsBeforeNormalCadenceIsDue() async throws {
        let client = IRSRateTestClient(periods: periods)
        let value = try model(client: client, following: false)
        XCTAssertTrue(value.startFollowingIRSRate(periods: periods, replaceManual: true))
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, july)
        value.preferences.irsRateLastAttempt = now
        value.preferences.irsRateLastSuccessfulCheck = now
        let firstDrive = MileageRateEffectiveDate(year: 2026, month: 6, day: 30)
        try addBusinessTrip(to: value, on: firstDrive)
        let success = await value.refreshIRSRateIfDue()
        XCTAssertTrue(success)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, january)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: try XCTUnwrap(firstDrive.date())).amountPerUnit, 0.725)
        let requested = await client.requestedDates
        XCTAssertEqual(requested, [firstDrive])
    }

    func testOlderDriveImportedDuringCheckRejectsIncompleteHistoryAndRetries() async throws {
        let prior = period(.init(year: 2025, month: 1, day: 1), through: .init(year: 2025, month: 12, day: 31), amount: 0.70)
        let client = IRSRateTestClient(periods: [prior] + periods, delay: .milliseconds(40))
        let value = try model(client: client)
        let saved = value.mileageRateSchedule
        let pending = Task { await value.refreshIRSRateIfDue() }
        while !value.irsRateIsChecking { await Task.yield() }
        try addBusinessTrip(to: value, on: .init(year: 2025, month: 11, day: 10))
        let firstResult = await pending.value
        XCTAssertFalse(firstResult)
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertTrue(value.preferences.irsRateCheckNeedsRetry)
        let retry = await value.refreshIRSRateIfDue()
        XCTAssertTrue(retry)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, prior.effectiveFrom)
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
    }

    func testFutureDatedDriveStillRequiresCurrentRateOnSetup() async throws {
        let client = IRSRateTestClient(periods: periods)
        let value = try model(client: client, following: false)
        try addBusinessTrip(to: value, on: .init(year: 2030, month: 1, day: 1))
        let result = await value.prepareIRSRateSetup()
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(value.irsRateSetupFollowingFrom, july)
        XCTAssertTrue(value.startFollowingIRSRate(periods: preview, replaceManual: true))
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
    }

    func testChoosingIRSChecksAndAdoptsRecordedHistoryWithoutSecondConfirmation() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(40))
        let value = try model(client: client, following: false)
        try addBusinessTrip(to: value, on: .init(year: 2026, month: 6, day: 30))
        let custom = MileageRateRule(effectiveFrom: .init(year: 2028, month: 1, day: 1), rate: .init(amountPerUnit: 0.90, unit: .miles))
        XCTAssertTrue(value.saveMileageRateSchedule(.init(baseRate: .init(amountPerUnit: 0.50, unit: .miles), rules: [custom])))
        let selection = Task { await value.chooseIRSBusinessRate() }
        while !value.irsRateIsChecking { await Task.yield() }
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom, "Saved rates remain custom while verification runs")
        let success = await selection.value
        XCTAssertTrue(success)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, january)
        XCTAssertEqual(value.mileageRateSchedule.baseRate, periods[0].rate)
        XCTAssertEqual(value.mileageRateSchedule.rules.map(\.effectiveFrom), periods.map(\.effectiveFrom))
        XCTAssertNotNil(value.mileageRateSchedule.deletedRuleIDs[custom.id])
        XCTAssertTrue(value.irsRatePendingPeriods.isEmpty)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testChoosingIRSFailureKeepsCustomAndCanRetry() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, fails: true), following: false)
        let saved = value.mileageRateSchedule
        let success = await value.chooseIRSBusinessRate()
        XCTAssertFalse(success)
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertNotNil(value.irsRateStatusMessage)
        XCTAssertNil(value.preferences.irsRateLastSuccessfulCheck)
    }

    func testCancelledSettingsWrapperDoesNotDiscardChosenSourceAfterVerification() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, delay: .milliseconds(40)), following: false)
        let wrapper = Task { await value.chooseIRSBusinessRate() }
        while !value.irsRateIsChecking { await Task.yield() }
        wrapper.cancel() // Leaving Settings cancels UI work, not the selected source.
        let success = await wrapper.value
        XCTAssertTrue(success)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, july)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
    }

    func testExplicitCustomChoiceCancelsInitialIRSAdoptionAndRejectsLateReply() async throws {
        let value = try model(client: IRSRateTestClient(periods: periods, delay: .milliseconds(80)), following: false)
        let saved = value.mileageRateSchedule
        let selection = Task { await value.chooseIRSBusinessRate() }
        while !value.irsRateIsChecking { await Task.yield() }
        value.cancelIRSRateCheck()
        let success = await selection.value
        XCTAssertFalse(success)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
    }

    func testImmediateExportJoinsInitialIRSChoiceBeforeTakingRateSnapshot() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(80))
        let value = try model(client: client, following: false)
        try addBusinessTrip(to: value, on: MileageRateEffectiveDate(now))
        let selection = Task { await value.chooseIRSBusinessRate() }
        while !value.irsRateIsChecking { await Task.yield() }
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        let exported = try await value.prepareMonthlyReportExport(forMonthContaining: now)
        defer { for url in [exported.pdfURL, exported.csvURL] { try? FileManager.default.removeItem(at: url) } }
        let success = await selection.value
        XCTAssertTrue(success)
        XCTAssertEqual(exported.report.businessValue, 7.60, accuracy: 0.001)
        XCTAssertNil(exported.rateFreshnessMessage)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testChoosingIRSAdoptsSharedCheckOnlyRequestWithoutSecondFetch() async throws {
        let client = IRSRateTestClient(periods: periods, delay: .milliseconds(80))
        let value = try model(client: client, following: false)
        let preview = Task { await value.prepareIRSRateSetup() }
        while !value.irsRateIsChecking { await Task.yield() }
        let success = await value.chooseIRSBusinessRate()
        _ = await preview.value
        XCTAssertTrue(success)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, july)
        XCTAssertFalse(value.irsRateRefreshAdopts)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testCustomExportNeverStartsIRSCheck() async throws {
        let client = IRSRateTestClient(periods: periods)
        let value = try model(client: client, following: false)
        let message = await value.prepareIRSRateForExport()
        XCTAssertNil(message)
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }
}
