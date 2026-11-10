import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// A manually released response proves ordering without networking or sleeps.
private actor CustomMileageRateClient: IRSBusinessRateFetching {
    private var response: CheckedContinuation<[IRSBusinessRatePeriod], Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func fetchPeriods(since: MileageRateEffectiveDate, now: Date, force: Bool) async throws -> [IRSBusinessRatePeriod] {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            response = continuation
            let waiters = requestWaiters
            requestWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitForRequest() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func complete(with periods: [IRSBusinessRatePeriod]) {
        let continuation = response
        response = nil
        // Deliberately ignore cancellation, like a late transport response.
        continuation?.resume(returning: periods)
    }
}

@MainActor
final class CustomMileageRateTests: XCTestCase {
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private var now: Date { date(2026, 10, 4) }

    func testCustomSaveCommitsSourceCurrencyUnitAndRateTogether() throws {
        let value = try model()
        let before = value.mileageRateSchedule
        let oldValue = before.rate(on: date(2026, 10, 3))

        XCTAssertTrue(value.saveCustomMileageRate(amount: 0.45, currency: "EUR", unit: .kilometers, effectiveFrom: now))

        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertFalse(value.mileageRateSchedule.isAutomaticIRSDefault)
        XCTAssertFalse(value.mileageRateSchedule.requiresCustomRate)
        XCTAssertEqual(value.currencyCode, "EUR")
        XCTAssertEqual(value.distanceUnit, .kilometers)
        XCTAssertEqual(value.preferences.displayDistanceUnitRaw, DistanceUnit.kilometers.rawValue)
        XCTAssertEqual(value.mileageRate, MileageRate(amountPerUnit: 0.45, unit: .kilometers))
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2026, 10, 3)), oldValue)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2027, 1, 1)), value.mileageRate)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), value.mileageRateSchedule)
        XCTAssertEqual(try value.unitsCurrencyStore.fetchCurrencyCode(), "EUR")
        XCTAssertEqual(try value.unitsCurrencyStore.fetchDistanceUnitPreference(), value.distanceUnitPreference)
        XCTAssertFalse(value.preferences.irsRateCheckNeedsRetry)
    }

    func testInvalidCurrencySaveLeavesPersistedAndInMemorySettingsUnchanged() throws {
        let value = try model()
        let schedule = value.mileageRateSchedule
        let rate = value.mileageRate
        let currency = value.currencyCode
        let preference = value.distanceUnitPreference
        let displayedUnit = value.preferences.displayDistanceUnitRaw
        let persistedCurrency = try value.unitsCurrencyStore.fetchCurrencyCode()
        let persistedUnit = try value.unitsCurrencyStore.fetchDistanceUnitPreference()

        XCTAssertFalse(value.saveCustomMileageRate(amount: 0.45, currency: "ZZZ", unit: .kilometers, effectiveFrom: now))

        XCTAssertEqual(value.mileageRateSchedule, schedule)
        XCTAssertEqual(value.mileageRate, rate)
        XCTAssertEqual(value.currencyCode, currency)
        XCTAssertEqual(value.distanceUnitPreference, preference)
        XCTAssertEqual(value.preferences.displayDistanceUnitRaw, displayedUnit)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), schedule)
        XCTAssertEqual(try value.unitsCurrencyStore.fetchCurrencyCode(), persistedCurrency)
        XCTAssertEqual(try value.unitsCurrencyStore.fetchDistanceUnitPreference(), persistedUnit)
        XCTAssertNotNil(value.errorAlert)
    }

    func testFailedCustomSaveDoesNotCancelPendingIRSSelection() async throws {
        let client = CustomMileageRateClient()
        let value = try model(client: client, following: false)
        let saved = value.mileageRateSchedule
        let selection = Task { await value.chooseIRSBusinessRate() }
        await client.waitForRequest()
        let operationID = try XCTUnwrap(value.irsRateRefreshID)

        XCTAssertFalse(value.saveCustomMileageRate(amount: 0.45, currency: "ZZZ", unit: .kilometers, effectiveFrom: now))
        XCTAssertEqual(value.irsRateRefreshID, operationID)
        XCTAssertTrue(value.irsRateIsChecking)
        XCTAssertTrue(value.irsRateRefreshAdopts)
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), saved)

        await client.complete(with: periods)
        let selected = await selection.value
        XCTAssertTrue(selected)
        XCTAssertNotNil(value.mileageRateSchedule.irsFollowingFrom)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now).amountPerUnit, 0.76)
    }

    func testLateIRSResponseCannotUndoSuccessfulCustomSave() async throws {
        let client = CustomMileageRateClient()
        let value = try model(client: client)
        let check = Task { await value.refreshIRSRateIfDue() }
        await client.waitForRequest()
        let operation = try XCTUnwrap(value.irsRateRefreshTask)

        XCTAssertTrue(value.saveCustomMileageRate(amount: 0.83, currency: "USD", unit: .miles, effectiveFrom: now))
        let custom = value.mileageRateSchedule
        XCTAssertFalse(value.irsRateIsChecking)
        XCTAssertNil(value.irsRateRefreshID)
        await client.complete(with: periods)
        await operation.value
        let checkSucceeded = await check.value

        XCTAssertFalse(checkSucceeded)
        XCTAssertEqual(value.mileageRateSchedule, custom)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), custom)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2027, 1, 1)).amountPerUnit, 0.83)
        XCTAssertNil(value.mileageRateSchedule.irsFollowingFrom)
    }

    func testMovingHistoricalRuleChangesOnlyItsIntendedBoundary() throws {
        let value = try model(following: false)
        let january = MileageRateRule(effectiveFrom: logical(2026, 1, 1), rate: .init(amountPerUnit: 0.6, unit: .miles),
            updatedAt: now.addingTimeInterval(3_600))
        let later = MileageRateRule(effectiveFrom: logical(2026, 7, 1), rate: .init(amountPerUnit: 0.8, unit: .miles))
        XCTAssertTrue(value.saveMileageRateSchedule(.init(baseRate: .init(amountPerUnit: 0.4, unit: .miles), rules: [january, later])))

        XCTAssertTrue(value.saveCustomMileageRate(amount: 0.65, currency: "USD", unit: .miles,
            effectiveFrom: date(2026, 2, 1), editingRuleID: january.id, expectedEditingRule: january))

        let result = value.mileageRateSchedule
        XCTAssertFalse(result.rules.contains { $0.effectiveFrom == january.effectiveFrom })
        XCTAssertEqual(result.deletedRuleIDs[january.id], january.updatedAt, "Moving a clock-ahead rule must not allow sync to restore its old date")
        XCTAssertEqual(result.rate(on: date(2026, 1, 15)).amountPerUnit, 0.4)
        XCTAssertEqual(result.rate(on: date(2026, 2, 1)).amountPerUnit, 0.65)
        XCTAssertEqual(result.rate(on: date(2026, 7, 1)), later.rate)
        XCTAssertTrue(result.rules.contains(later))
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), result)
    }

    func testMovingHistoricalRuleOntoAnotherCustomDateIsRejected() throws {
        let value = try model(following: false)
        let january = MileageRateRule(effectiveFrom: logical(2026, 1, 1), rate: .init(amountPerUnit: 0.6, unit: .miles))
        let july = MileageRateRule(effectiveFrom: logical(2026, 7, 1), rate: .init(amountPerUnit: 0.8, unit: .miles))
        XCTAssertTrue(value.saveMileageRateSchedule(.init(baseRate: .init(amountPerUnit: 0.4, unit: .miles), rules: [january, july])))
        let saved = value.mileageRateSchedule

        XCTAssertFalse(value.saveCustomMileageRate(amount: 0.65, currency: "USD", unit: .miles,
            effectiveFrom: date(2026, 7, 1), editingRuleID: january.id))
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), saved)
    }

    func testHistoricalDraftRejectsSameIDChangedAmountOrDate() throws {
        for changesDate in [false, true] {
            let value = try model(following: false)
            let original = MileageRateRule(effectiveFrom: logical(2026, 1, 1),
                rate: .init(amountPerUnit: 0.6, unit: .miles), updatedAt: now.addingTimeInterval(-60))
            var synced = original
            if changesDate {
                synced.effectiveFrom = logical(2026, 3, 1)
            } else {
                synced.rate = .init(amountPerUnit: 0.9, unit: .miles)
            }
            synced.updatedAt = now
            XCTAssertTrue(value.saveMileageRateSchedule(.init(baseRate: .init(amountPerUnit: 0.4, unit: .miles), rules: [synced])))
            let saved = value.mileageRateSchedule

            XCTAssertFalse(value.saveCustomMileageRate(amount: 0.65, currency: "USD", unit: .miles,
                effectiveFrom: date(2026, 1, 1), editingRuleID: original.id, expectedEditingRule: original))
            XCTAssertEqual(value.mileageRateSchedule, saved)
            XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), saved)
            XCTAssertNotNil(value.errorAlert)
        }
    }

    func testEditingDeletedHistoricalRuleDoesNotCreateNewRate() throws {
        let value = try model(following: false)
        let saved = value.mileageRateSchedule
        XCTAssertFalse(value.saveCustomMileageRate(amount: 0.65, currency: "USD", unit: .miles,
            effectiveFrom: date(2026, 2, 1), editingRuleID: UUID()))
        XCTAssertEqual(value.mileageRateSchedule, saved)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), saved)
    }

    func testExplicitBaseEditPreservesDatedCustomHistory() throws {
        let value = try model(following: false)
        let later = MileageRateRule(effectiveFrom: logical(2026, 7, 1), rate: .init(amountPerUnit: 0.8, unit: .miles))
        XCTAssertTrue(value.saveMileageRateSchedule(.init(baseRate: .init(amountPerUnit: 0.4, unit: .miles), rules: [later])))

        XCTAssertTrue(value.saveCustomMileageRate(amount: 0.5, currency: "USD", unit: .miles,
            effectiveFrom: date(2026, 1, 1), editingBase: true))
        XCTAssertEqual(value.mileageRateSchedule.baseRate.amountPerUnit, 0.5)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2025, 12, 31)).amountPerUnit, 0.5)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2026, 1, 1)).amountPerUnit, 0.5)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2026, 7, 1)), later.rate)
    }

    func testUnsetRateExportWarnsAndCustomSaveClearsWarning() async throws {
        let value = try unsetModel()
        let trip = value.createManualTrip(startDate: now, endDate: now.addingTimeInterval(600), distanceMiles: 10,
            origin: "Office", destination: "Client", classification: .business, purpose: "Work", notes: "", tolls: 0, parking: 0)
        XCTAssertNotNil(trip)
        let files = try await value.prepareMonthlyReportExport(forMonthContaining: now)
        defer { for url in [files.pdfURL, files.csvURL] { try? FileManager.default.removeItem(at: url) } }
        XCTAssertNotNil(files.rateFreshnessMessage)
        XCTAssertEqual(files.rateFreshnessMessage, value.irsRateExportStatusMessage)
        XCTAssertEqual(files.report.businessValue, 0)
        XCTAssertEqual(MileageRateSettingsView.rowSummary(for: value), String(localized: "Set Rate"))

        XCTAssertTrue(value.saveCustomMileageRate(amount: 0, currency: "EUR", unit: .kilometers, effectiveFrom: now))
        XCTAssertFalse(value.mileageRateSchedule.requiresCustomRate, "Explicit zero is a configured rate")
        let warning = await value.prepareIRSRateForExport()
        XCTAssertNil(warning)
    }

    func testFirstCustomSetupCoversPastAndCurrentTripsEvenWithFutureDraftDate() async throws {
        let value = try unsetModel()
        let selected = MileageRate(amountPerUnit: 0.45, unit: .kilometers)

        XCTAssertTrue(value.saveCustomMileageRate(amount: selected.amountPerUnit, currency: "EUR", unit: selected.unit,
            effectiveFrom: date(2027, 1, 1)))

        XCTAssertFalse(value.mileageRateSchedule.requiresCustomRate)
        XCTAssertEqual(value.mileageRateSchedule.baseRate, selected)
        XCTAssertTrue(value.mileageRateSchedule.rules.isEmpty, "First setup does not need a redundant dated rule")
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2026, 5, 1)), selected)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: now), selected)
        XCTAssertEqual(value.mileageRateSchedule.rate(on: date(2027, 1, 1)), selected)
        XCTAssertEqual(try value.mileageRateScheduleStore.fetchSchedule(), value.mileageRateSchedule)
        let warning = await value.prepareIRSRateForExport()
        XCTAssertNil(warning)
    }

    func testChangingUnsetDisplayUnitDoesNotConfigureZeroRate() async throws {
        let value = try unsetModel()
        value.setDistanceUnitPreference(.miles)
        XCTAssertTrue(value.mileageRateSchedule.requiresCustomRate)
        XCTAssertTrue(try value.mileageRateScheduleStore.fetchSchedule().requiresCustomRate)
        XCTAssertNil(try MileageRateStore(context: value.persistence.container.viewContext).fetchPersistedRate())
        let warning = await value.prepareIRSRateForExport()
        XCTAssertNotNil(warning)
    }

    private func model(client: CustomMileageRateClient = CustomMileageRateClient(), following: Bool = true) throws -> MileageAppModel {
        let value = MileageAppModel(previewMode: true, preferences: Preferences(defaults: try makeTestDefaults()), irsRateClient: client)
        value.irsRateNow = { [now] in now }
        value.setCurrencyCode("USD")
        value.setDistanceUnitPreference(.miles)
        if following {
            let schedule = try IRSBusinessRateScheduleUpdater.adoptHistory(periods: periods,
                to: .init(baseRate: .init(amountPerUnit: 0.6, unit: .miles)),
                followingFrom: logical(2026, 1, 1), now: now, calendar: calendar)
            XCTAssertTrue(value.saveMileageRateSchedule(schedule))
        } else {
            XCTAssertTrue(value.saveMileageRateSchedule(.init(baseRate: .init(amountPerUnit: 0.7, unit: .miles))))
        }
        return value
    }

    private func unsetModel() throws -> MileageAppModel {
        let value = MileageAppModel(previewMode: true, preferences: Preferences(defaults: try makeTestDefaults()), irsRateClient: CustomMileageRateClient())
        value.irsRateNow = { [now] in now }
        let unset = IRSBusinessRateScheduleUpdater.initialSchedule(currencyCode: "EUR", now: now)
        value.mileageRateSchedule = try value.mileageRateScheduleStore.saveSchedule(unset,
            currencyCode: "EUR", distanceUnitPreference: .kilometers, now: now)
        value.currencyCode = "EUR"
        value.distanceUnitPreference = .kilometers
        value.mileageRate = value.mileageRateSchedule.rate(on: now).converted(to: .kilometers)
        return value
    }

    private var periods: [IRSBusinessRatePeriod] {
        [IRSBusinessRatePeriod(effectiveFrom: logical(2026, 1, 1), effectiveThrough: logical(2026, 6, 30), amountPerMile: 0.725,
            sourceURL: IRSBusinessRatePeriod.bundledCurrent.sourceURL, rateEvidence: "72.5", periodEvidence: "2026 (Jan. 1 – June 30)"),
         .bundledCurrent,
         IRSBusinessRatePeriod(effectiveFrom: logical(2027, 1, 1), effectiveThrough: logical(2027, 12, 31), amountPerMile: 0.80,
            sourceURL: IRSBusinessRatePeriod.bundledCurrent.sourceURL, rateEvidence: "80", periodEvidence: "2027")]
    }

    private func logical(_ year: Int, _ month: Int, _ day: Int) -> MileageRateEffectiveDate {
        .init(year: year, month: month, day: day)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
