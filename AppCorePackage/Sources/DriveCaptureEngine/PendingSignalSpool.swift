import AppCoreModels
import Foundation

/// Unprotected single-slot fallback for a drive-start signal that could not be
/// written to the encrypted store — the App-Intent path before first unlock
/// after a reboot (`PersistenceController` init throws while the Class C
/// stores are sealed). Mirrors `ParkingAnchorBeacon`: one JSON record,
/// `FileProtectionType.none`, excluded from backup, latest write wins.
///
/// Privacy: holds only a trigger kind, a timestamp, and an opaque vehicle UUID
/// (never a name) — no location, nothing readable before first unlock.
public struct SpooledDriveStartSignal: Codable, Equatable, Sendable {
    public var triggerRaw: String
    public var createdAt: Date
    public var vehicleID: UUID?

    public init(trigger: DriveStartExternalTrigger, createdAt: Date, vehicleID: UUID? = nil) {
        triggerRaw = trigger.rawValue
        self.createdAt = createdAt
        self.vehicleID = vehicleID
    }

    public var trigger: DriveStartExternalTrigger? {
        DriveStartExternalTrigger(rawValue: triggerRaw)
    }
}

public final class PendingSignalSpool {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let baseDirectory = directory ?? Self.defaultDirectory()
        fileURL = baseDirectory.appendingPathComponent("pending-drive-start-spool.json", isDirectory: false)
    }

    public func save(trigger: DriveStartExternalTrigger, at date: Date, vehicleID: UUID? = nil) throws {
        let record = SpooledDriveStartSignal(trigger: trigger, createdAt: date, vehicleID: vehicleID)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .noFileProtection])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: fileURL.path
        )
        #else
        // Non-iOS exists only so the shared package compiles and `swift test`
        // runs on macOS; the intent — the only writer — is iOS-only.
        try data.write(to: fileURL, options: [.atomic])
        #endif
        excludeFromBackup()
    }

    /// Read-and-delete. Entries older than the pending-signal grace are
    /// discarded — a stale spooled connect must not open a watch window hours
    /// later.
    public func drain(now: Date = Date(), maxAge: TimeInterval = 30 * 60) -> SpooledDriveStartSignal? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(SpooledDriveStartSignal.self, from: data) else { return nil }
        guard now.timeIntervalSince(record.createdAt) <= maxAge, record.trigger != nil else { return nil }
        return record
    }

    private func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DriveCapture", isDirectory: true)
    }
}
