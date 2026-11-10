import AppCore
import CoreData
import Foundation

/// Owns the iPhone's iCloud sync policy: container identifier, availability
/// flags, status polling, and the CloudKit purge step used during reset. The
/// history-draining core lives in the shared `PersistentHistoryMonitor`; this
/// wrapper keeps `MileageAppModel` free of CloudKit details and adds the
/// build/preference gating that has no Mac equivalent.
@MainActor
final class SyncCoordinator {
    let containerIdentifier: String
    let isAvailableInThisBuild: Bool
    let isEnabledThisLaunch: Bool

    private let syncStatusService: SyncStatusService?
    private let monitor: PersistentHistoryMonitor
    private let localHistoryPurger = LocalHistoryPurger()
    static let historyTokenKeyPrefix = "SyncRemoteChangeHistoryToken.v2"
    private static let legacyHistoryTokenKey = "SyncRemoteChangeHistoryToken"

    convenience init(isUITesting: Bool, storedSyncEnabled: Bool) {
        let configuration = SyncConfigurationResolver.resolve(
            isUITesting: isUITesting,
            storedSyncEnabled: storedSyncEnabled
        )
        self.init(configuration: configuration)
    }

    init(
        configuration: SyncConfiguration,
        defaults: UserDefaults = .standard,
        remoteMaintenanceRetryDelays: [Duration] = [
            .seconds(1),
            .seconds(3),
            .seconds(10)
        ],
        foreignMaintenance: @escaping @MainActor (PersistenceController) async throws -> Void = { persistence in
            _ = try await RetiredTripMaintenance(persistence: persistence).run()
            _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        }
    ) {
        containerIdentifier = configuration.containerIdentifier
        isAvailableInThisBuild = configuration.isAvailableInThisBuild
        isEnabledThisLaunch = configuration.isEnabledThisLaunch
        syncStatusService = isEnabledThisLaunch ? SyncStatusService(containerIdentifier: containerIdentifier) : nil
        monitor = PersistentHistoryMonitor(
            containerIdentifier: configuration.containerIdentifier,
            tokenKeyPrefix: Self.historyTokenKeyPrefix,
            defaults: defaults,
            maintenanceRetryDelays: remoteMaintenanceRetryDelays,
            loggerCategory: "iPhoneSync",
            foreignMaintenance: foreignMaintenance
        )
        // The legacy token had no store or container identity. Replaying any
        // retained history is safer than guessing which database created it.
        defaults.removeObject(forKey: Self.legacyHistoryTokenKey)
    }

    func persistenceMode() -> PersistenceMode {
        SyncConfiguration(
            containerIdentifier: containerIdentifier,
            isAvailableInThisBuild: isAvailableInThisBuild,
            isEnabledThisLaunch: isEnabledThisLaunch
        ).persistenceMode
    }

    func initialStatus(syncEnabledPreference: Bool) -> SyncStatus? {
        guard !isEnabledThisLaunch else { return nil }
        return SyncStatus(state: syncEnabledPreference ? .unavailable : .disabled, lastError: nil)
    }

    func checkStatus(syncEnabledPreference: Bool, completion: @MainActor @escaping (SyncStatus) -> Void) {
        guard syncEnabledPreference else {
            completion(.init(state: .disabled))
            return
        }
        guard let syncStatusService else {
            completion(SyncStatus(state: .unavailable, lastError: nil))
            return
        }
        syncStatusService.checkStatus { status in
            Task { @MainActor in completion(status) }
        }
    }

    func requiresRelaunch(forNewPreference newValue: Bool) -> Bool {
        isAvailableInThisBuild && newValue != isEnabledThisLaunch
    }

    /// Calls `onChange` on the main actor when the store reports a change that
    /// came from outside the app (a CloudKit import, not one of our own saves).
    func observeRemoteChanges(in persistence: PersistenceController, onChange: @MainActor @escaping () -> Void) {
        // Runs for every user regardless of sync enablement: Local-store
        // history has no consumer and grows by tens of thousands of
        // transactions per driving day if never purged.
        localHistoryPurger.schedulePurgeIfNeeded(on: persistence)
        guard isEnabledThisLaunch else { return }
        monitor.observe(on: persistence, onForeignChange: onChange)
    }

    /// Drains history without waiting for a push. Launch and foreground
    /// activation use this as the missed-silent-push fallback.
    func checkForRemoteChanges() {
        guard isEnabledThisLaunch else { return }
        monitor.checkForRemoteChanges()
    }

    /// Processes remote history for the observer path. Foreign transactions
    /// only advance the saved token after foreign maintenance succeeds, so a
    /// failed maintenance pass can retry the same CloudKit import later.
    @discardableResult
    func processRemoteTransactions(in persistence: PersistenceController) async -> Bool {
        await monitor.processForeignTransactions(in: persistence)
    }

    func purgeCloudKitData(persistence: PersistenceController) async throws {
        guard isAvailableInThisBuild, isEnabledThisLaunch else { return }
        try await persistence.purgeCloudKitData(containerIdentifier: containerIdentifier)
    }

}
