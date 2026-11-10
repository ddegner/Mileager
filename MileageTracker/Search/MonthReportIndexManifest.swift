import Foundation

/// Records the content digest each donated month-report entity carried, so
/// reconciles re-donate only months whose donated text actually changed.
/// Modeled on `TripIndexManifest`, but digest-based: the digest already
/// fingerprints formatting (unit, rate, currency, locale), so no separate
/// format stamp is needed. A missing or unreadable file reads as "nothing
/// donated", which only causes an idempotent re-donation.
struct MonthReportIndexManifest {
    private struct Payload: Codable {
        var digests: [String: String]
    }

    private(set) var digests: [String: String]
    private let fileURL: URL

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("MileageTracker", isDirectory: true)
        return directory.appendingPathComponent("spotlight-month-manifest.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            digests = decoded.digests
        } else {
            digests = [:]
        }
    }

    mutating func recordDonated(_ reports: [(id: String, digest: String)]) {
        for report in reports {
            digests[report.id] = report.digest
        }
        persist()
    }

    mutating func recordDeleted(_ ids: [String]) {
        for id in ids {
            digests.removeValue(forKey: id)
        }
        persist()
    }

    mutating func clear() {
        digests = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    func isCurrent(id: String, digest: String) -> Bool {
        digests[id] == digest
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Payload(digests: digests)) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
