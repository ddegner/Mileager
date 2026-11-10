import CoreLocation
import Foundation

/// A single parked-anchor coordinate persisted *outside* the app's encrypted
/// Core Data stores so the parked-anchor geofence can be re-armed on a cold
/// background relaunch while the device is locked — including before the first
/// unlock after a reboot, when the Class C capture stores cannot be opened.
///
/// Privacy: this holds exactly one coordinate (the current parking spot), never
/// a history. It is overwritten on each park and erased the moment the geofence
/// exit fires or monitoring stops (see `CoreLocationRegionDriveIdleWakeProvider`). The
/// file is written with `FileProtectionType.none` and excluded from backup.
/// CoreLocation's `locationd` already persists the same geofence center
/// unencrypted, so this adds no new categorical exposure.
public struct StoredParkingAnchor: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        radius: Double,
        horizontalAccuracy: Double,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    /// Rebuilds a `LocationSample` anchor (only the fields the idle-wake monitor
    /// needs: coordinate, accuracy, timestamp).
    public var anchorSample: LocationSample {
        LocationSample(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy
        )
    }
}

public protocol ParkingAnchorBeaconStoring: AnyObject {
    func save(anchor: LocationSample, radius: CLLocationDistance)
    func load() -> StoredParkingAnchor?
    func clear()
}

/// File-backed `ParkingAnchorBeaconStoring` that writes a single JSON record
/// with `FileProtectionType.none` so it is readable on any background relaunch.
public final class ParkingAnchorBeacon: ParkingAnchorBeaconStoring {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let baseDirectory = directory ?? Self.defaultDirectory()
        fileURL = baseDirectory.appendingPathComponent("parking-anchor-beacon.json", isDirectory: false)
    }

    public func save(anchor: LocationSample, radius: CLLocationDistance) {
        let record = StoredParkingAnchor(
            latitude: anchor.latitude,
            longitude: anchor.longitude,
            radius: radius,
            horizontalAccuracy: anchor.horizontalAccuracy,
            timestamp: anchor.timestamp
        )
        do {
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
            // Non-iOS exists only so the shared package compiles and unit tests
            // run under `swift test` (macOS). Drive capture — the only writer of
            // this beacon — is iOS-only, so this path is never hit in production;
            // a future macOS app is organize/export-only and does no tracking.
            try data.write(to: fileURL, options: [.atomic])
            #endif
            excludeFromBackup()
        } catch {
            // Best-effort: a missing beacon only costs a slower (motion-based)
            // re-arm, never correctness, so failures are intentionally swallowed.
        }
    }

    public func load() -> StoredParkingAnchor? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredParkingAnchor.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
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
