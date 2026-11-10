import AppCore
import Foundation

/// Main-store access point for trip entity queries and intents. In-app intents
/// run in the app's process, so the SwiftUI `App` has already constructed the
/// `MileageAppModel`; this indirection exists so tests can substitute a model
/// and so callers share one before-first-unlock rule.
@MainActor
enum TripIntentDataProvider {
    static var modelProvider: () -> MileageAppModel? = { AppLaunchCoordinator.shared.model }
    static var isReady: (MileageAppModel) -> Bool = { $0.intentCaptureReady }

    /// Registration and capture restoration can race a cold Siri launch. Wait
    /// only for that milestone, never CloudKit, geocoding, or suggestion work.
    static func readyModel(timeout: Duration = .seconds(2)) async throws -> MileageAppModel {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            if let model = modelProvider() {
                guard !model.isAwaitingProtectedData else { throw TripIntentError.storeUnavailable }
                guard model.isCommandSurfaceAvailable else { throw TripIntentError.appLocked }
                if isReady(model) { return model }
            }
            if clock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(25))
        } while true
        throw TripIntentError.startupUnavailable
    }

    /// The live model, or nil while the store is unavailable. Before first
    /// unlock the app runs on an empty in-memory fallback stack; answering
    /// queries from it would look like the user has no trips, so callers must
    /// treat nil as "unavailable", never "empty".
    static func availableModel() -> MileageAppModel? {
        guard let model = modelProvider(), model.isCommandSurfaceAvailable else {
            return nil
        }
        return model
    }

    /// Intent actions should surface a readable failure instead of inheriting
    /// the fail-soft behavior used by entity queries. `TripStore.fetchTrips`
    /// returns canonicalized trips, but "most recently completed" is based on
    /// end date rather than start date because overlapping captures can finish
    /// out of order.
    static func mostRecentTrip(
        in model: MileageAppModel,
        excludingNotADrive: Bool = false
    ) throws -> TripSummary {
        do {
            let trips = try model.tripStore.fetchTrips()
            let eligibleTrips = if excludingNotADrive {
                trips.filter { $0.classification != .notADrive }
            } else {
                trips
            }
            let trip = eligibleTrips.max { lhs, rhs in
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate < rhs.endDate
                }
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                // Prefer the lexicographically smaller UUID when timestamps
                // match so every Siri, Shortcuts, and Spotlight path resolves
                // the same physical trip.
                return lhs.id.uuidString > rhs.id.uuidString
            }
            guard let trip else {
                throw TripIntentError.noCompletedTrips
            }
            return trip
        } catch let error as TripIntentError {
            throw error
        } catch {
            throw TripIntentError.tripReadFailed
        }
    }

    static func resetForTesting() {
        modelProvider = { AppLaunchCoordinator.shared.model }
        isReady = { $0.intentCaptureReady }
    }
}
