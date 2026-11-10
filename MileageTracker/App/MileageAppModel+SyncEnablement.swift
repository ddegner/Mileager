import AppCore
import Foundation

struct SyncEnablePreflight: Identifiable, Equatable {
    let id = "sync-enable-preflight"
    let tripCount: Int
    let earliestTripDate: Date?
    let latestTripDate: Date?
    let rawSampleCount: Int
    let vehicleCount: Int

    init(rows: [TripRowProjection], rawSampleCount: Int, vehicleCount: Int) {
        tripCount = rows.count
        earliestTripDate = rows.map(\.startDate).min()
        latestTripDate = rows.map(\.endDate).max()
        self.rawSampleCount = rawSampleCount
        self.vehicleCount = vehicleCount
    }
}

enum SyncPreferenceChangeResult: Equatable {
    case applied
    case confirmationRequired(SyncEnablePreflight)
}

enum SyncEnablementError: LocalizedError, Equatable {
    case unavailable
    case activeDrive

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "iCloud Sync is unavailable in this build.")
        case .activeDrive:
            String(localized: "Finish the current drive before changing iCloud Sync.")
        }
    }
}

@MainActor
extension MileageAppModel {
    /// Settings boundary for sync changes. Enabling a previously local-only
    /// launch is deliberately two-step so the toggle cannot silently commit a
    /// library merge. Disabling, or cancelling a pending disable before the
    /// process has relaunched, is safe to apply immediately.
    func requestSyncPreferenceChange(to enabled: Bool) throws -> SyncPreferenceChangeResult {
        guard enabled != syncEnabled else { return .applied }

        if !enabled || syncRunningThisLaunch {
            syncEnabled = enabled
            return .applied
        }

        guard syncToggleAvailable else {
            throw SyncEnablementError.unavailable
        }
        guard currentDrive == nil else {
            throw SyncEnablementError.activeDrive
        }

        let rows = try tripStore.fetchTripRows()
        let rawSampleCount = try tripStore.rawSampleCount()
        let vehicleCount = try vehicleStore.fetchVehicles(includeArchived: true).count
        return .confirmationRequired(SyncEnablePreflight(
            rows: rows,
            rawSampleCount: rawSampleCount,
            vehicleCount: vehicleCount
        ))
    }

    func confirmSyncEnablement() async throws {
        guard !syncEnabled, !syncRunningThisLaunch else { return }
        guard currentDrive == nil else {
            throw SyncEnablementError.activeDrive
        }
        _ = try await FirstSyncRecoverySnapshotExporter.makeSnapshot(
            from: persistence.container,
            destinationRootURL: firstSyncRecoveryRootURL
        )
        // The copy runs on a background context. Capture may have started while
        // it was being prepared, so recheck before changing the next-launch
        // preference and leave the current persistence stack untouched.
        guard currentDrive == nil else {
            throw SyncEnablementError.activeDrive
        }
        syncEnabled = true
    }

    var firstSyncRecoveryRootURL: URL {
        let baseDirectory = persistenceStoreDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MileageTracker", isDirectory: true)
        return baseDirectory.appendingPathComponent(
            "FirstSyncRecoverySnapshots",
            isDirectory: true
        )
    }
}
