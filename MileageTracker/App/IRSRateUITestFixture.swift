#if DEBUG
import AppCore
import Foundation

/// Synthetic public-rate evidence, restricted to explicitly isolated UI runs.
/// It never fetches live IRS content.
enum IRSRateUITestFixture {
    enum Scenario: String, Sendable {
        case setup, following, conflict, failure, failureSetup, delayedSetup
    }

    struct Configuration: Sendable {
        let client: any IRSBusinessRateFetching
        let now: Date
        let scenario: Scenario
        let periods: [IRSBusinessRatePeriod]
    }

    static func configuration(arguments: [String]) -> Configuration? {
        guard arguments.contains("--uitesting"),
              let argument = arguments.first(where: { $0.hasPrefix("--irs-rate-fixture=") }),
              let scenario = Scenario(rawValue: String(argument.dropFirst("--irs-rate-fixture=".count))) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        let periods = [
            period(amount: 0.725, from: .init(year: 2026, month: 1, day: 1), through: .init(year: 2026, month: 6, day: 30)),
            period(amount: 0.76, from: .init(year: 2026, month: 7, day: 1), through: .init(year: 2026, month: 12, day: 31)),
            period(amount: 0.78, from: .init(year: 2027, month: 1, day: 1), through: .init(year: 2027, month: 12, day: 31))
        ]
        return Configuration(
            client: FixtureClient(
                periods: periods,
                fails: scenario == .failure || scenario == .failureSetup,
                delays: scenario == .delayedSetup
            ),
            now: now,
            scenario: scenario,
            periods: periods
        )
    }

    private static func period(
        amount: Double, from: MileageRateEffectiveDate, through: MileageRateEffectiveDate
    ) -> IRSBusinessRatePeriod {
        IRSBusinessRatePeriod(
            effectiveFrom: from,
            effectiveThrough: through,
            amountPerMile: amount,
            sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
            rateEvidence: "Synthetic UI test business rate: \(amount) USD per mile.",
            periodEvidence: "Synthetic UI test effective period."
        )
    }

    private struct FixtureClient: IRSBusinessRateFetching {
        let periods: [IRSBusinessRatePeriod]
        let fails: Bool
        let delays: Bool

        func fetchPeriods(since: MileageRateEffectiveDate, now: Date, force: Bool) async throws -> [IRSBusinessRatePeriod] {
            try Task.checkCancellation()
            if delays { try await Task.sleep(for: .seconds(5)) }
            if fails { throw FixtureFailure.unavailable }
            return periods
        }
    }

    private enum FixtureFailure: Error {
        case unavailable
    }
}

@MainActor
extension MileageAppModel {
    /// Startup calls this after ordinary fixture seeding. A relaunch keeps the
    /// user's UI-test edits instead of restoring the scenario's initial state.
    func configureIRSRateUITestScenarioIfNeeded(arguments: [String]) {
        guard isUITesting, arguments.contains("--reset-data"),
              let configuration = IRSRateUITestFixture.configuration(arguments: arguments) else { return }
        // Startup seeds Core Data before publishing its first trip snapshot.
        // Fixture adoption must use that same seeded history as real setup.
        do { trips = try tripStore.fetchTrips() } catch { return }
        switch configuration.scenario {
        case .setup, .failureSetup, .delayedSetup:
            _ = saveMileageRateSchedule(MileageRateSchedule(
                baseRate: MileageRate(amountPerUnit: 0.725, unit: .miles)
            ))
        case .following, .failure:
            _ = startFollowingIRSRate(periods: configuration.periods, replaceManual: true)
        case .conflict:
            _ = startFollowingIRSRate(periods: configuration.periods, replaceManual: true)
            var schedule = mileageRateSchedule
            schedule.rules.append(MileageRateRule(
                effectiveFrom: .init(year: 2026, month: 8, day: 1),
                rate: MileageRate(amountPerUnit: 0.90, unit: .miles),
                updatedAt: configuration.now
            ))
            _ = saveMileageRateSchedule(schedule)
        }
    }
}
#endif
