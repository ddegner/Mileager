import Foundation

/// Records which trips have been donated to Spotlight and the `updatedAt` seen
/// at donation time, so reconciles can diff the store against the index without
/// re-donating everything. Persisted as JSON; a missing or unreadable file is
/// treated as "nothing donated", which only causes an idempotent re-donation.
struct TripIndexManifest {
    private struct Payload: Codable {
        var entries: [UUID: Date]
        var formatStamp: String?
    }

    private(set) var entries: [UUID: Date]
    /// Fingerprint of the donation formatting (display unit + locale). Donated
    /// snippets bake formatted text in, so a stamp change means every entry is
    /// stale even though no trip's `updatedAt` moved.
    private(set) var formatStamp: String?
    private let fileURL: URL

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("MileageTracker", isDirectory: true)
        return directory.appendingPathComponent("spotlight-trip-manifest.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            entries = decoded.entries
            formatStamp = decoded.formatStamp
        } else {
            entries = [:]
            formatStamp = nil
        }
    }

    mutating func recordDonated(_ trips: [(id: UUID, updatedAt: Date)]) {
        for trip in trips {
            entries[trip.id] = trip.updatedAt
        }
        persist()
    }

    mutating func recordDeleted(_ ids: [UUID]) {
        for id in ids {
            entries.removeValue(forKey: id)
        }
        persist()
    }

    mutating func clear() {
        entries = [:]
        formatStamp = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Drops all donation records and adopts `stamp`, so the next reconcile
    /// re-donates everything with the new formatting.
    mutating func resetForFormatChange(_ stamp: String) {
        entries = [:]
        formatStamp = stamp
        persist()
    }

    func isCurrent(id: UUID, updatedAt: Date) -> Bool {
        entries[id] == updatedAt
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Payload(entries: entries, formatStamp: formatStamp)) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
