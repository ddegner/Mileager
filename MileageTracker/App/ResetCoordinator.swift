import AppCore
import Foundation

/// Orchestrates the destructive "Reset App" flow: purges CloudKit if available,
/// wipes the local persistent store, and clears resettable preferences. Returns
/// a structured result so `MileageAppModel` can present the right UI without
/// needing to know about CloudKit.
@MainActor
struct ResetCoordinator {
    let persistence: PersistenceController
    let sync: SyncCoordinator
    let preferences: Preferences
    let derivedArtifactTestSuffix: String?

    init(
        persistence: PersistenceController,
        sync: SyncCoordinator,
        preferences: Preferences,
        derivedArtifactTestSuffix: String? = nil
    ) {
        self.persistence = persistence
        self.sync = sync
        self.preferences = preferences
        self.derivedArtifactTestSuffix = derivedArtifactTestSuffix
    }

    enum ResetResult {
        case success(message: String)
        case failure(message: String)
    }

    func run() async -> ResetResult {
        var cloudKitResetError: Error?
        do {
            try await sync.purgeCloudKitData(persistence: persistence)
        } catch {
            cloudKitResetError = error
        }

        do {
            try persistence.deleteAllData()
            preferences.clearAll()
            try DerivedArtifactCacheRoot.removeAll(testSuffix: derivedArtifactTestSuffix)
            var message = sync.isEnabledThisLaunch
                ? "Reset complete. Relaunch the app to finish switching sync off."
                : "Reset complete."
            if let cloudKitResetError {
                message += " iCloud data could not be fully cleared: \(cloudKitResetError.localizedDescription)"
            }
            return .success(message: message)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// Path used for UI-test runs where we wipe on launch via `--reset-data`.
    static func storeDirectoryForUITesting(suffix: String? = nil) -> URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(storeDirectoryName(suffix: suffix), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func storeDirectoryName(suffix: String?) -> String {
        guard let suffix, !suffix.isEmpty else {
            return "MileageTracker-UITesting"
        }
        let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let sanitized = suffix.map { character in
            allowedCharacters.contains(character) ? character : "-"
        }
        return "MileageTracker-UITesting-\(String(sanitized))"
    }
}
