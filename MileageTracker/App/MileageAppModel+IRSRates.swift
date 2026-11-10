import AppCore
import Foundation
import UIKit

/// A foreground check is shared by Settings and exports. No timers wake the app.
enum IRSRateCheckCadence {
    static func isDue(lastAttempt: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastAttempt, lastAttempt <= now else { return true }
        var logicalCalendar = Calendar(identifier: .gregorian)
        logicalCalendar.timeZone = calendar.timeZone
        let parts = logicalCalendar.dateComponents([.month, .day], from: now)
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        let inWindow = (month == 12 && day >= 29) || (month == 1 && day <= 14)
            || (month == 6 && day >= 28) || (month == 7 && day <= 14)
        if inWindow { return !logicalCalendar.isDate(lastAttempt, inSameDayAs: now) }
        return now.timeIntervalSince(lastAttempt) >= 7 * 24 * 60 * 60
    }
}

@MainActor
extension MileageAppModel {
    /// Rate history begins with the earliest recorded drive. With no drives,
    /// setup previews the current period instead of inventing older history.
    var mileageRateHistoryStartDate: MileageRateEffectiveDate {
        MileageRateEffectiveDate(trips.map(\.startDate).min() ?? irsRateNow())
    }

    private var irsRateRequiredHistoryDate: MileageRateEffectiveDate {
        min(mileageRateHistoryStartDate, MileageRateEffectiveDate(irsRateNow()))
    }

    var irsRateSetupFollowingFrom: MileageRateEffectiveDate? {
        let required = irsRateRequiredHistoryDate
        return irsRatePendingPeriods.first {
            $0.effectiveFrom <= required && $0.effectiveThrough >= required
        }?.effectiveFrom
    }

    func scheduleIRSRateCheckOnForeground() {
        let isForeground = sceneIsActive || UIApplication.shared.applicationState == .active
        guard isForeground, !isUITesting, hasCompletedStartupDataLoad,
              currencyCode == "USD", mileageRateSchedule.irsFollowingFrom != nil else { return }
        Task { @MainActor [weak self] in
            _ = await self?.refreshIRSRateIfDue()
        }
    }

    func prepareIRSRateSetup() async -> [IRSBusinessRatePeriod]? {
        guard currencyCode == "USD" else { return nil }
        let success = await runIRSRateCheck(setup: true, force: true)
        return success ? irsRatePendingPeriods : nil
    }

    /// Choosing the source authorizes adoption after verification. The shared
    /// model operation outlives Settings navigation, but explicit cancellation,
    /// backgrounding, and a changed persisted schedule still invalidate it.
    @discardableResult
    func chooseIRSBusinessRate() async -> Bool {
        guard currencyCode == "USD" else { return false }
        if mileageRateSchedule.irsFollowingFrom != nil { return true }
        return await runIRSRateCheck(setup: true, force: true, adoptOnSuccess: true)
    }

    func checkIRSRateNow() async {
        guard mileageRateSchedule.irsFollowingFrom != nil else {
            _ = await prepareIRSRateSetup()
            return
        }
        _ = await runIRSRateCheck(setup: false, force: true)
    }

    @discardableResult
    func startFollowingIRSRate(periods: [IRSBusinessRatePeriod], replaceManual _: Bool) -> Bool {
        guard currencyCode == "USD" else {
            irsRateStatusMessage = String(localized: "IRS rate updates require USD.")
            return false
        }
        let now = irsRateNow()
        let required = irsRateRequiredHistoryDate
        guard let first = periods.first(where: { $0.effectiveFrom <= required && $0.effectiveThrough >= required }) else {
            irsRateStatusMessage = String(localized: "No current IRS business rate could be verified.")
            return false
        }
        // Choosing IRS is the explicit replacement decision. The accepted
        // schedule contains only verified IRS history, including future rates.
        return applyIRSPeriods(periods, followingFrom: first.effectiveFrom, replaceManual: true, now: now, adopting: true)
    }

    @discardableResult
    func stopFollowingIRSRate() -> Bool {
        cancelIRSRateCheck()
        do {
            let saved = try mileageRateScheduleStore.fetchSchedule()
            let schedule = IRSBusinessRateScheduleUpdater.stopFollowing(saved, now: irsRateNow())
            guard saveMileageRateSchedule(schedule, presentErrors: false) else {
                irsRateStatusMessage = String(localized: "IRS rates could not be saved. Your saved rates are unchanged.")
                return false
            }
            preferences.irsRateCheckNeedsRetry = false
            irsRatePendingPeriods = []
            irsRateHasConflicts = false
            irsRateStatusMessage = nil
            return true
        } catch {
            irsRateStatusMessage = String(localized: "IRS rates could not be saved. Your saved rates are unchanged.")
            return false
        }
    }

    func resolveIRSRateConflicts(replaceManual: Bool) {
        guard replaceManual else {
            stopFollowingIRSRate()
            return
        }
        guard !irsRatePendingPeriods.isEmpty else { return }
        if let from = mileageRateSchedule.irsFollowingFrom {
            _ = applyIRSPeriods(irsRatePendingPeriods, followingFrom: from, replaceManual: true, now: irsRateNow())
        } else {
            _ = startFollowingIRSRate(periods: irsRatePendingPeriods, replaceManual: true)
        }
    }

    /// Exports join an already-running check, or start a due one, before they
    /// capture the schedule. The operation itself has one 15-second deadline.
    func prepareIRSRateForExport() async -> String? {
        if mileageRateSchedule.requiresCustomRate {
            return String(localized: "Mileage rate not set. This export uses a zero mileage value.")
        }
        guard currencyCode == "USD",
              mileageRateSchedule.irsFollowingFrom != nil || irsRateRefreshAdopts else { return nil }
        let verified = await refreshIRSRateIfDue()
        if irsRateHasConflicts {
            return String(localized: "An IRS rate update needs review. This export uses your saved rates.")
        }
        return verified ? nil : String(localized: "IRS rate freshness could not be verified. This export uses your saved rates.")
    }

    @discardableResult
    func refreshIRSRateIfDue() async -> Bool {
        guard !resetInProgress else { return false }
        guard currencyCode == "USD" else { return true }
        if irsRateRefreshID != nil,
           mileageRateSchedule.irsFollowingFrom != nil || irsRateRefreshAdopts {
            return await awaitIRSRateCheck()
        }
        guard mileageRateSchedule.irsFollowingFrom != nil else { return true }
        guard preferences.irsRateCheckNeedsRetry
            || irsRateRequiredHistoryDate < mileageRateSchedule.irsFollowingFrom!
            || IRSRateCheckCadence.isDue(lastAttempt: preferences.irsRateLastAttempt, now: irsRateNow()) else {
            return irsRateStatusMessage == nil && !irsRateHasConflicts
                && (preferences.irsRateLastSuccessfulCheck ?? .distantPast)
                    >= (preferences.irsRateLastAttempt ?? .distantFuture)
        }
        return await runIRSRateCheck(setup: false, force: false)
    }

    func cancelIRSRateCheck(clearStatus: Bool = false) {
        if clearStatus {
            irsRateStatusMessage = nil
            irsRatePendingPeriods = []
            irsRateHasConflicts = false
        }
        guard let id = irsRateRefreshID else { return }
        // A cancelled check must be eligible again on the next activation.
        preferences.irsRateLastAttempt = irsRatePreviousAttempt
        finishIRSRateCheck(id: id, success: false)
        preferences.irsRateCheckNeedsRetry = true
    }

    private func awaitIRSRateCheck() async -> Bool {
        await withCheckedContinuation { continuation in
            irsRateRefreshWaiters.append(continuation)
        }
    }

    private func runIRSRateCheck(setup: Bool, force: Bool, adoptOnSuccess: Bool = false) async -> Bool {
        guard !resetInProgress, currencyCode == "USD", !isUITesting || irsRateClientIsInjected else { return false }
        // A queued source/check action must not start a fetch after backgrounding
        // happened before there was an active operation to cancel.
        guard isUITesting || UIApplication.shared.applicationState != .background else { return false }
        if irsRateRefreshID != nil {
            // An explicit source choice can adopt the result of a check-only
            // request already in flight without a second HTTP operation.
            if adoptOnSuccess { irsRateRefreshAdopts = true }
            return await awaitIRSRateCheck()
        }
        guard setup || mileageRateSchedule.irsFollowingFrom != nil else { return false }
        let now = irsRateNow()
        let capturedHistoryDate = irsRateRequiredHistoryDate
        let since = min(mileageRateSchedule.irsFollowingFrom ?? capturedHistoryDate, capturedHistoryDate)
        let capturedSchedule = mileageRateSchedule
        let id = UUID()
        irsRateRefreshID = id
        irsRateRefreshAdopts = adoptOnSuccess
        irsRateIsChecking = true
        irsRateStatusMessage = nil
        irsRatePreviousAttempt = preferences.irsRateLastAttempt
        preferences.irsRateLastAttempt = now
        preferences.irsRateCheckNeedsRetry = true
        let client = irsRateClient
        irsRateRefreshTask = Task { @MainActor [weak self] in
            do {
                let periods = try await client.fetchPeriods(since: since, now: now, force: force)
                try Task.checkCancellation()
                guard let self, irsRateRefreshID == id else { return }
                // Import fresh CloudKit preferences before deciding whether an
                // async response still has authority to write this schedule.
                let savedCurrency = try unitsCurrencyStore.fetchCurrencyCode()
                if savedCurrency != "USD" {
                    currencyCode = savedCurrency
                    stopFollowingIRSRate()
                    return
                }
                let saved = try mileageRateScheduleStore.fetchSchedule()
                guard currencyCode == "USD", mileageRateSchedule == capturedSchedule,
                      saved == capturedSchedule else {
                    mileageRateSchedule = saved
                    mileageRate = saved.rate(on: now)
                    finishIRSRateCheck(id: id, success: false)
                    return
                }
                guard irsRateRequiredHistoryDate == capturedHistoryDate else {
                    finishIRSRateCheck(id: id, success: false)
                    preferences.irsRateCheckNeedsRetry = true
                    return
                }
                let validated = try IRSBusinessRateScheduleUpdater.validatedPeriods(periods)
                guard let first = validated.first(where: {
                    $0.effectiveFrom <= since && $0.effectiveThrough >= since
                }) else { throw IRSBusinessRateScheduleError.missingCoverage }
                let success: Bool
                if setup {
                    // Validate the entire interval through today before showing
                    // a preview that promises to recalculate recorded drives.
                    _ = try IRSBusinessRateScheduleUpdater.adoptHistory(
                        periods: validated, to: capturedSchedule,
                        followingFrom: first.effectiveFrom, now: now
                    )
                    if irsRateRefreshAdopts {
                        success = applyIRSPeriods(validated, followingFrom: first.effectiveFrom,
                            replaceManual: true, now: now, adopting: true)
                    } else {
                        irsRatePendingPeriods = validated.filter { $0.effectiveThrough >= first.effectiveFrom }
                        irsRateHasConflicts = false
                        success = true
                    }
                } else {
                    let from = min(capturedSchedule.irsFollowingFrom!, first.effectiveFrom)
                    success = applyIRSPeriods(validated, followingFrom: from, replaceManual: false, now: now)
                }
                if success {
                    preferences.irsRateLastSuccessfulCheck = now
                    irsRateLastSuccessfulCheck = now
                }
                finishIRSRateCheck(id: id, success: success)
            } catch {
                guard let self, irsRateRefreshID == id else { return }
                if !(error is CancellationError) {
                    irsRateStatusMessage = String(localized: "IRS business rates could not be verified. Your saved rates are unchanged.")
                }
                finishIRSRateCheck(id: id, success: false)
            }
        }
        let timeout = irsRateCheckTimeout
        irsRateDeadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, irsRateRefreshID == id else { return }
            irsRateStatusMessage = String(localized: "IRS rate check timed out. Your saved rates are unchanged.")
            finishIRSRateCheck(id: id, success: false)
        }
        return await awaitIRSRateCheck()
    }

    @discardableResult
    private func applyIRSPeriods(
        _ periods: [IRSBusinessRatePeriod], followingFrom: MileageRateEffectiveDate,
        replaceManual: Bool, now: Date, adopting: Bool = false
    ) -> Bool {
        do {
            let savedCurrency = try unitsCurrencyStore.fetchCurrencyCode()
            guard savedCurrency == "USD" else {
                currencyCode = savedCurrency
                stopFollowingIRSRate()
                irsRateStatusMessage = String(localized: "IRS rate updates require USD.")
                return false
            }
            let saved = try mileageRateScheduleStore.fetchSchedule()
            mileageRateSchedule = saved
            mileageRate = saved.rate(on: now)
            let updated: MileageRateSchedule
            if adopting {
                updated = try IRSBusinessRateScheduleUpdater.adoptHistory(
                    periods: periods, to: saved, followingFrom: followingFrom, now: now
                )
            } else {
                updated = try IRSBusinessRateScheduleUpdater.apply(
                    periods: periods, to: saved, followingFrom: followingFrom,
                    replaceManual: replaceManual, now: now
                )
            }
            guard updated == mileageRateSchedule || saveMileageRateSchedule(updated, presentErrors: false) else {
                irsRateStatusMessage = String(localized: "IRS rates could not be saved. Your saved rates are unchanged.")
                return false
            }
            mileageRate = mileageRateSchedule.rate(on: now)
            irsRatePendingPeriods = []
            irsRateHasConflicts = false
            irsRateStatusMessage = nil
            return true
        } catch IRSBusinessRateScheduleError.overlappingManualRules {
            irsRatePendingPeriods = periods
            irsRateHasConflicts = true
            irsRateStatusMessage = String(localized: "IRS rates overlap your custom rates. Review the update before applying it.")
            return false
        } catch {
            irsRateStatusMessage = String(localized: "IRS business rates could not be verified. Your saved rates are unchanged.")
            return false
        }
    }

    private func finishIRSRateCheck(id: UUID, success: Bool) {
        guard irsRateRefreshID == id else { return }
        irsRateRefreshID = nil
        irsRateRefreshAdopts = false
        preferences.irsRateCheckNeedsRetry = false
        irsRateIsChecking = false
        irsRateRefreshTask?.cancel()
        irsRateDeadlineTask?.cancel()
        irsRateRefreshTask = nil
        irsRateDeadlineTask = nil
        let waiters = irsRateRefreshWaiters
        irsRateRefreshWaiters = []
        for waiter in waiters { waiter.resume(returning: success) }
    }
}
