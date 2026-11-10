import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

private actor IRSDefaultRateClient: IRSBusinessRateFetching {
    let fails: Bool
    private(set) var calls = 0
    private(set) var requestedDates: [MileageRateEffectiveDate] = []

    init(fails: Bool = false) { self.fails = fails }

    func fetchPeriods(since: MileageRateEffectiveDate, now: Date, force: Bool) async throws -> [IRSBusinessRatePeriod] {
        calls += 1
        requestedDates.append(since)
        if fails { throw URLError(.notConnectedToInternet) }
        let january = IRSBusinessRatePeriod(effectiveFrom: .init(year: 2026, month: 1, day: 1),
            effectiveThrough: .init(year: 2026, month: 6, day: 30), amountPerMile: 0.725,
            sourceURL: IRSBusinessRatePeriod.bundledCurrent.sourceURL,
            rateEvidence: "72.5", periodEvidence: "2026 (Jan. 1 – June 30)")
        return [january, .bundledCurrent].filter { $0.effectiveThrough >= since }
    }
}

@MainActor
final class IRSRateDefaultTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testModelFirstLoadUsesIRSDefaultBeforeInitializationMetadataIsWritten() async throws {
        let client = IRSDefaultRateClient()
        let value = try model(client: client)

        XCTAssertEqual(value.currencyCode, "USD", "This US-hosted first-load test must exercise USD")
        XCTAssertTrue(value.mileageRateSchedule.isAutomaticIRSDefault)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, .init(year: 2026, month: 7, day: 1))
        XCTAssertEqual(value.mileageRate.amountPerUnit, 0.76)
        XCTAssertNil(value.preferences.irsRateLastSuccessfulCheck)
        XCTAssertNil(value.mileageRateSchedule.sourceSelectionUpdatedAt)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), value.mileageRateSchedule)
        let calls = await client.calls
        XCTAssertEqual(calls, 0, "An isolated preview must not trigger a live foreground check")
    }

    func testUnavailableCheckRetainsFreshIRSSelectionAndBundledRate() async throws {
        let value = try model(client: IRSDefaultRateClient(fails: true))
        let saved = value.mileageRateSchedule
        let verified = await value.refreshIRSRateIfDue()

        XCTAssertFalse(verified)
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
        XCTAssertTrue(value.mileageRateSchedule.isAutomaticIRSDefault)
        XCTAssertNil(value.preferences.irsRateLastSuccessfulCheck)
        XCTAssertNil(value.mileageRateSchedule.sourceSelectionUpdatedAt)
        XCTAssertNotNil(value.irsRateStatusMessage)
    }

    func testEarlierImportedDriveBackfillsOfficialHistoryEvenWithinCadence() async throws {
        let client = IRSDefaultRateClient()
        let value = try model(client: client)
        let may = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 5, day: 23, hour: 12)))
        XCTAssertNotNil(value.createManualTrip(startDate: may, endDate: may.addingTimeInterval(600), distanceMiles: 10,
            origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0))
        value.preferences.irsRateLastAttempt = now
        value.preferences.irsRateLastSuccessfulCheck = now

        let verified = await value.refreshIRSRateIfDue()

        XCTAssertTrue(verified)
        XCTAssertEqual(value.mileageRateSchedule.irsFollowingFrom, .init(year: 2026, month: 1, day: 1))
        XCTAssertEqual(value.mileageRateSchedule.rate(on: may).amountPerUnit, 0.725)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
        XCTAssertTrue(value.mileageRateSchedule.isAutomaticIRSDefault)
        XCTAssertNil(value.mileageRateSchedule.sourceSelectionUpdatedAt)
        let requests = await client.requestedDates
        XCTAssertEqual(requests, [.init(year: 2026, month: 5, day: 23)])
        let files = try await value.prepareMonthlyReportExport(forMonthContaining: may)
        defer { for url in [files.pdfURL, files.csvURL] { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(files.report.businessValue, 7.25, accuracy: 0.0001)
        XCTAssertEqual(try preferenceCount(MileageRateStore.preferenceKey, in: value), 0)
    }

    func testChoosingCustomPersistsAndDefaultInitializationDoesNotRestoreIRS() async throws {
        let value = try model(client: IRSDefaultRateClient())
        XCTAssertTrue(value.stopFollowingIRSRate())
        let saved = value.mileageRateSchedule
        XCTAssertNil(saved.irsFollowingFrom)
        XCTAssertFalse(saved.isAutomaticIRSDefault)
        XCTAssertEqual(saved.sourceSelectionUpdatedAt, now)
        XCTAssertEqual(try value.mileageRateScheduleStore.initializeDefaultScheduleIfNeeded(currencyCode: "USD"), saved)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), saved)
    }

    func testKilometerDisplayDoesNotPromoteAutomaticDefaultToCustom() throws {
        let value = try model(client: IRSDefaultRateClient())
        let saved = value.mileageRateSchedule
        value.setDistanceUnitPreference(.kilometers)

        XCTAssertEqual(value.distanceUnit, .kilometers)
        XCTAssertEqual(value.mileageRate.amountPerUnit, 0.76 / 1.609344, accuracy: 0.000001)
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), saved)
        XCTAssertEqual(try preferenceCount(MileageRateStore.preferenceKey, in: value), 0)
    }

    func testLockedLaunchPlaceholderDoesNotPersistIRSDefault() throws {
        let suffix = "irs-bfu-\(UUID().uuidString)"
        let value = MileageAppModel(
            arguments: ["MileageTracker", "--uitesting", "--skip-onboarding", "--test-store-suffix=\(suffix)"],
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false, irsRateClient: IRSDefaultRateClient())
        XCTAssertTrue(value.isAwaitingProtectedData)
        XCTAssertFalse(value.mileageRateSchedule.isAutomaticIRSDefault)
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(try preferenceCount(MileageRateScheduleStore.preferenceKey, in: value), 0)
    }

    private func model(client: IRSDefaultRateClient) throws -> MileageAppModel {
        let value = MileageAppModel(previewMode: true, preferences: Preferences(defaults: try makeTestDefaults()), irsRateClient: client)
        value.irsRateNow = { [now] in now }
        return value
    }

    private func preferenceCount(_ key: String, in value: MileageAppModel) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PreferenceEntity")
        request.predicate = NSPredicate(format: "key == %@", key)
        return try value.persistence.container.viewContext.count(for: request)
    }
}
