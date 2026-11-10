import AppCore
import CryptoKit
import Foundation

/// Compact, disposable persistence for the suggestion band. The actor owns
/// all disk access, and every read failure degrades to a cache miss.
actor TripSuggestionCacheStore: SuggestionPersisting {
    static let freshnessInterval: TimeInterval = 24 * 60 * 60
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let maximumEntryCount = 200

    private let testSuffix: String?
    private let now: @Sendable () -> Date
    private let afterLoad: (@Sendable () async -> Void)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        testSuffix: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        afterLoad: (@Sendable () async -> Void)? = nil
    ) {
        self.testSuffix = testSuffix
        self.now = now
        self.afterLoad = afterLoad
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    /// Returns exact-fingerprint entries only. Unknown trips, changed inputs,
    /// expired files, and malformed files are removed during the same sweep.
    func load(matching expectedFingerprints: [UUID: String]) async -> [UUID: SuggestionCacheHit] {
        guard !expectedFingerprints.isEmpty,
              let directory = try? suggestionDirectory() else {
            if expectedFingerprints.isEmpty {
                try? removeAll()
            }
            return [:]
        }

        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let currentDate = now()
        var validRecords: [(url: URL, record: TripSuggestionCacheRecord)] = []

        for fileURL in fileURLs {
            guard fileURL.pathExtension == "json" else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            guard let record = decodeRecord(at: fileURL),
                  record.schemaVersion == TripSuggestionCacheRecord.schemaVersion,
                  record.tripID.uuidString.lowercased() == fileURL.deletingPathExtension().lastPathComponent,
                  record.storedAt <= currentDate.addingTimeInterval(Self.freshnessInterval),
                  currentDate.timeIntervalSince(record.storedAt) <= Self.retentionInterval,
                  expectedFingerprints[record.tripID] == record.fingerprint,
                  record.makeSuggestion() != nil else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            validRecords.append((fileURL, record))
        }

        validRecords.sort { $0.record.storedAt > $1.record.storedAt }
        for expiredByCount in validRecords.dropFirst(Self.maximumEntryCount) {
            try? FileManager.default.removeItem(at: expiredByCount.url)
        }

        var hits: [UUID: SuggestionCacheHit] = [:]
        for (_, record) in validRecords.prefix(Self.maximumEntryCount) {
            guard let suggestion = record.makeSuggestion() else { continue }
            let age = max(0, currentDate.timeIntervalSince(record.storedAt))
            hits[record.tripID] = SuggestionCacheHit(
                suggestion: suggestion,
                fingerprint: record.fingerprint,
                freshness: age <= Self.freshnessInterval ? .fresh : .stale
            )
        }
        await afterLoad?()
        return hits
    }

    func save(
        _ suggestion: TripClassificationSuggestion,
        fingerprint: String,
        tripUpdatedAt: Date
    ) {
        guard let record = TripSuggestionCacheRecord(
            suggestion: suggestion,
            fingerprint: fingerprint,
            tripUpdatedAt: tripUpdatedAt,
            storedAt: now()
        ), let directory = try? suggestionDirectory(),
           let data = try? encoder.encode(record) else {
            return
        }

        let fileURL = Self.fileURL(for: suggestion.tripID, in: directory)
        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFileURL = fileURL
            try mutableFileURL.setResourceValues(values)
            pruneIfNeeded(in: directory)
        } catch {
            // Cache persistence is best-effort. The in-memory suggestion stays
            // visible and the next launch simply regenerates it.
        }
    }

    func remove(tripIDs: Set<UUID>) {
        guard !tripIDs.isEmpty,
              let directory = try? suggestionDirectory() else { return }
        for tripID in tripIDs {
            try? FileManager.default.removeItem(at: Self.fileURL(for: tripID, in: directory))
        }
    }

    /// Removes only the exact records a caller previously read. A newer
    /// suggestion may have replaced one of those files while the caller was
    /// deciding whether to publish its hit, so fingerprint mismatches are
    /// deliberately preserved.
    func remove(entriesMatching fingerprints: [UUID: String]) {
        guard !fingerprints.isEmpty else { return }
        let directory = DerivedArtifactCacheRoot.scopedRootURL(testSuffix: testSuffix)
            .appendingPathComponent("suggestions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        for (tripID, fingerprint) in fingerprints {
            let fileURL = Self.fileURL(for: tripID, in: directory)
            guard let record = decodeRecord(at: fileURL),
                  record.tripID == tripID,
                  record.fingerprint == fingerprint else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func removeAll() throws {
        let directory = DerivedArtifactCacheRoot.scopedRootURL(testSuffix: testSuffix)
            .appendingPathComponent("suggestions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func cachedEntryCount() -> Int {
        guard let directory = try? suggestionDirectory() else { return 0 }
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }.count
    }

    private func suggestionDirectory() throws -> URL {
        try DerivedArtifactCacheRoot.prepareSubdirectory("suggestions", testSuffix: testSuffix)
    }

    private func decodeRecord(at fileURL: URL) -> TripSuggestionCacheRecord? {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(TripSuggestionCacheRecord.self, from: data) else {
            return nil
        }
        return record
    }

    private func pruneIfNeeded(in directory: URL) {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let currentDate = now()
        var datedFiles: [(url: URL, date: Date)] = []
        for fileURL in fileURLs {
            guard fileURL.pathExtension == "json" else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            guard let record = decodeRecord(at: fileURL),
                  record.schemaVersion == TripSuggestionCacheRecord.schemaVersion,
                  currentDate.timeIntervalSince(record.storedAt) <= Self.retentionInterval else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            datedFiles.append((fileURL, record.storedAt))
        }
        datedFiles.sort { $0.date > $1.date }
        for overflow in datedFiles.dropFirst(Self.maximumEntryCount) {
            try? FileManager.default.removeItem(at: overflow.url)
        }
    }

    private static func fileURL(for tripID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(tripID.uuidString.lowercased()).appendingPathExtension("json")
    }
}

private struct TripSuggestionCacheRecord: Codable {
    static let schemaVersion = 1

    enum Classification: String, Codable {
        case business
        case personal
    }

    struct Evidence: Codable {
        enum Kind: String, Codable {
            case calendarEvent
        }

        var kind: Kind
        var title: String
    }

    var schemaVersion: Int
    var fingerprint: String
    var tripID: UUID
    var tripUpdatedAt: Date
    var classification: Classification
    var businessPurpose: String?
    var rationale: String?
    var evidence: [Evidence]
    var generatedAt: Date
    var storedAt: Date

    init?(
        suggestion: TripClassificationSuggestion,
        fingerprint: String,
        tripUpdatedAt: Date,
        storedAt: Date
    ) {
        let classification: Classification
        switch suggestion.classification {
        case .business: classification = .business
        case .personal: classification = .personal
        case .notADrive: return nil
        }
        self.schemaVersion = Self.schemaVersion
        self.fingerprint = fingerprint
        tripID = suggestion.tripID
        self.tripUpdatedAt = tripUpdatedAt
        self.classification = classification
        businessPurpose = suggestion.businessPurpose
        rationale = suggestion.rationale
        evidence = suggestion.evidence.map {
            switch $0 {
            case .calendarEvent(let title):
                Evidence(kind: .calendarEvent, title: title)
            }
        }
        generatedAt = suggestion.generatedAt
        self.storedAt = storedAt
    }

    func makeSuggestion() -> TripClassificationSuggestion? {
        let domainClassification: TripClassification = switch classification {
        case .business: .business
        case .personal: .personal
        }
        return TripClassificationSuggestion(
            tripID: tripID,
            classification: domainClassification,
            businessPurpose: businessPurpose,
            rationale: rationale,
            evidence: evidence.map { .calendarEvent(title: $0.title) },
            generatedAt: generatedAt
        )
    }
}
