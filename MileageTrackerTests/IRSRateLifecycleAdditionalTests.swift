import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

private actor IRSRateLifecycleClient: IRSBusinessRateFetching {
    enum Behavior: Sendable {
        case success
        case delayedSuccess
        case unavailable
    }

    let periods: [IRSBusinessRatePeriod]
    let behavior: Behavior
    private(set) var calls = 0

    init(periods: [IRSBusinessRatePeriod], behavior: Behavior = .success) {
        self.periods = periods
        self.behavior = behavior
    }

    func fetchPeriods(since: MileageRateEffectiveDate, now: Date, force: Bool) async throws -> [IRSBusinessRatePeriod] {
        calls += 1
        if case .unavailable = behavior {
            throw IRSBusinessRateClientError.invalidResponse
        }
        if case .delayedSuccess = behavior {
            // Detached work keeps running when the caller cancels, matching a
            // transport/model implementation that returns an eventual result.
            await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value
        }
        return periods.filter { $0.effectiveThrough >= since }
    }
}

@MainActor
final class IRSRateLifecycleAdditionalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)
    private let january = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
    private let july = MileageRateEffectiveDate(year: 2026, month: 7, day: 1)

    func testInterruptedCheckIsRetriedAfterModelRelaunchWithinNormalCadence() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.irsRateLastAttempt = now
        preferences.irsRateLastSuccessfulCheck = now.addingTimeInterval(-60)
        preferences.irsRateCheckNeedsRetry = true
        let client = IRSRateLifecycleClient(periods: periods)
        let relaunched = try model(client: client, defaults: defaults)

        let verified = await relaunched.refreshIRSRateIfDue()

        XCTAssertTrue(verified)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(preferences.irsRateCheckNeedsRetry)
        XCTAssertEqual(relaunched.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
    }

    func testStopFollowingRejectsNonCooperativePendingResponse() async throws {
        let client = IRSRateLifecycleClient(periods: periods, behavior: .delayedSuccess)
        let value = try model(client: client)
        let savedRules = value.mileageRateSchedule.rules
        let check = Task { await value.checkIRSRateNow() }
        while !value.irsRateIsChecking { await Task.yield() }
        while await client.calls == 0 { await Task.yield() }

        XCTAssertTrue(value.stopFollowingIRSRate())
        await check.value
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(value.mileageRateSchedule.rules, savedRules)
        XCTAssertFalse(value.irsRateIsChecking)
        XCTAssertFalse(value.preferences.irsRateCheckNeedsRetry)
        XCTAssertFalse(value.irsRateHasConflicts)
        XCTAssertTrue(value.irsRatePendingPeriods.isEmpty)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), value.mileageRateSchedule)
    }

    func testUnavailablePCCCannotAdoptRatesAndFollowingExportRetainsSavedRates() async throws {
        let client = IRSRateLifecycleClient(periods: periods, behavior: .unavailable)
        let custom = try model(client: client, following: false)
        let beforeSetup = custom.mileageRateSchedule
        let preview = await custom.prepareIRSRateSetup()
        XCTAssertNil(preview)
        XCTAssertNil(custom.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(custom.mileageRateSchedule, beforeSetup)
        XCTAssertNotNil(custom.irsRateStatusMessage)

        let following = try model(client: client)
        let saved = following.mileageRateSchedule
        let message = await following.prepareIRSRateForExport()
        XCTAssertNotNil(message)
        XCTAssertEqual(following.mileageRateSchedule, saved)
        XCTAssertEqual(try following.mileageRateScheduleStore.fetchSchedule(), saved)
    }

    func testInvalidPersistedScheduleFailsPreflightWithoutReplacingData() async throws {
        let value = try model(client: IRSRateLifecycleClient(periods: periods))
        let inMemory = value.mileageRateSchedule
        var invalid = inMemory
        invalid.irsFollowingFrom = MileageRateEffectiveDate(year: 2026, month: 2, day: 30)
        let invalidData = try JSONEncoder().encode(invalid)
        let context = value.persistence.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "PreferenceEntity")
        request.predicate = NSPredicate(format: "key == %@", MileageRateScheduleStore.preferenceKey)
        let row = try XCTUnwrap(context.fetch(request).first)
        row.setValue(invalidData, forKey: "valueData")
        try context.save()

        await value.checkIRSRateNow()

        XCTAssertEqual(value.mileageRateSchedule, inMemory)
        XCTAssertEqual(row.value(forKey: "valueData") as? Data, invalidData)
        XCTAssertNotNil(value.irsRateStatusMessage)
        XCTAssertThrowsError(try value.mileageRateScheduleStore.fetchSchedule())
    }

    private var periods: [IRSBusinessRatePeriod] {
        [period(from: january, through: .init(year: 2026, month: 6, day: 30), amount: 0.725),
         period(from: july, through: .init(year: 2026, month: 12, day: 31), amount: 0.76)]
    }

    private func period(from: MileageRateEffectiveDate, through: MileageRateEffectiveDate, amount: Double) -> IRSBusinessRatePeriod {
        .init(effectiveFrom: from, effectiveThrough: through, amountPerMile: amount,
              sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
              rateEvidence: "Synthetic test business rate \(amount)", periodEvidence: "Synthetic test period")
    }

    private func model(client: IRSRateLifecycleClient, defaults: UserDefaults? = nil, following: Bool = true) throws -> MileageAppModel {
        let value = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: try defaults ?? makeTestDefaults()),
            irsRateClient: client
        )
        value.setCurrencyCode("USD")
        value.irsRateNow = { [now] in now }
        if following {
            let schedule = MileageRateSchedule(
                baseRate: .init(amountPerUnit: 0.70, unit: .miles),
                rules: [.init(effectiveFrom: january, rate: periods[0].rate, irsSource: periods[0])],
                irsFollowingFrom: january,
                sourceSelectionUpdatedAt: now.addingTimeInterval(-86_400)
            )
            XCTAssertTrue(value.saveMileageRateSchedule(schedule))
        } else {
            XCTAssertTrue(value.saveMileageRateSchedule(.default))
        }
        return value
    }
}
