import AppCore
import Foundation

struct SyncConfiguration {
    var containerIdentifier: String
    var isAvailableInThisBuild: Bool
    var isEnabledThisLaunch: Bool

    var persistenceMode: PersistenceMode {
        isEnabledThisLaunch
            ? .cloudKit(containerIdentifier: containerIdentifier)
            : .localOnly
    }
}

enum SyncConfigurationResolver {
    static func resolve(
        bundle: Bundle = .main,
        isUITesting: Bool,
        storedSyncEnabled: Bool
    ) -> SyncConfiguration {
        let bundleID = bundle.bundleIdentifier ?? "com.localfirst.MileageTracker"
        let containerIdentifier = bundle.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String
            ?? "iCloud.\(bundleID)"
        let isAvailableInThisBuild = !isUITesting
            && (bundle.object(forInfoDictionaryKey: "CloudKitSyncAvailable") as? Bool ?? false)
        return SyncConfiguration(
            containerIdentifier: containerIdentifier,
            isAvailableInThisBuild: isAvailableInThisBuild,
            isEnabledThisLaunch: isAvailableInThisBuild && storedSyncEnabled
        )
    }
}
