import Foundation

/// Shared location and lifecycle policy for disposable, locally derived app
/// artifacts. Production content lives under the versioned Library/Caches
/// root; UI and hosted-unit tests get an isolated suffix below that root.
enum DerivedArtifactCacheRoot {
    static let version = "v1"

    /// Creates and returns one artifact-kind directory, applying the common
    /// no-backup and Class-C data-protection policy to that subtree root.
    static func prepareSubdirectory(
        _ name: String,
        testSuffix: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = scopedRootURL(testSuffix: testSuffix, fileManager: fileManager)
            .appendingPathComponent(sanitizedPathComponent(name), isDirectory: true)
        try prepareDirectory(directory, fileManager: fileManager)
        return directory
    }

    /// Removes every derived artifact in the caller's production or isolated
    /// test scope. A missing directory is already a successful cleanup.
    static func removeAll(
        testSuffix: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = scopedRootURL(testSuffix: testSuffix, fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    static func scopedRootURL(
        testSuffix: String? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        var root = productionRootURL(fileManager: fileManager)
        if let testSuffix = effectiveTestSuffix(testSuffix) {
            root.appendPathComponent("testing", isDirectory: true)
            root.appendPathComponent(sanitizedPathComponent(testSuffix), isDirectory: true)
        }
        return root
    }

    static func productionRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mileager", isDirectory: true)
            .appendingPathComponent("DerivedArtifacts", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    private static func effectiveTestSuffix(_ explicitSuffix: String?) -> String? {
        if let explicitSuffix, !explicitSuffix.isEmpty {
            return explicitSuffix
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--test-store-suffix=")
        }) {
            return String(argument.dropFirst("--test-store-suffix=".count))
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            return "ui-testing"
        }
        // Directly constructed coordinators and stores in hosted unit tests do
        // not always receive app launch arguments. Keep them away from the
        // production cache even in that case.
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            return "hosted-unit-tests"
        }
        return nil
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let sanitized = value.map { allowed.contains($0) ? $0 : "-" }
        let result = String(sanitized)
        return result.isEmpty ? "default" : result
    }
}
