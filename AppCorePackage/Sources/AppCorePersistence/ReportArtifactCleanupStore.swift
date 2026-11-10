import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public enum ReportArtifactCleanupDecision: Codable, Equatable, Sendable {
    case deleteConfirmed(Date)
    case keepForNow(Date)

    public var deletesArtifacts: Bool {
        if case .deleteConfirmed = self { return true }
        return false
    }
}

public final class ReportArtifactCleanupStore {
    public static let decisionPreferenceKey = "reportArtifactCleanup.v1"

    /// PreferenceEntity key prefix legacy development builds used for
    /// canonical report metadata. The persist path is gone (ADR 0005), but
    /// CloudKit can resurrect these rows from other devices, so cleanup and
    /// duplicate resolution must keep recognizing the prefix.
    static let legacyMetadataKeyPrefix = "reportMetadata.v1"

    private let context: NSManagedObjectContext
    private let decisionPreferences: PreferenceStore

    public init(context: NSManagedObjectContext) {
        self.context = context
        decisionPreferences = PreferenceStore(
            context: context,
            key: Self.decisionPreferenceKey
        )
    }

    public func fetchDecision() throws -> ReportArtifactCleanupDecision? {
        try decisionPreferences.read()
    }

    public func legacyArtifactCount() throws -> Int {
        let reportRequest = ReportSnapshotEntity.fetchRequest()
        let metadataRequest = PreferenceEntity.fetchRequest()
        metadataRequest.predicate = NSPredicate(
            format: "key BEGINSWITH %@",
            Self.legacyMetadataKeyPrefix + "."
        )
        return try context.count(for: reportRequest) + context.count(for: metadataRequest)
    }

    public func keepForNow(at date: Date = Date()) throws {
        try decisionPreferences.write(ReportArtifactCleanupDecision.keepForNow(date))
    }

    @discardableResult
    public func confirmAndDelete(at date: Date = Date()) throws -> Int {
        try deleteArtifacts(recording: .deleteConfirmed(date))
    }

    @discardableResult
    public func deleteAgainIfConfirmed() throws -> Int {
        guard try fetchDecision()?.deletesArtifacts == true else { return 0 }
        return try deleteArtifacts(recording: nil)
    }

    private func deleteArtifacts(
        recording decision: ReportArtifactCleanupDecision?
    ) throws -> Int {
        try context.saveTransaction {
            let reportRequest = ReportSnapshotEntity.fetchRequest()
            let reports = try context.fetch(reportRequest)
            let metadataRequest = PreferenceEntity.fetchRequest()
            metadataRequest.predicate = NSPredicate(
                format: "key BEGINSWITH %@",
                Self.legacyMetadataKeyPrefix + "."
            )
            let metadata = try context.fetch(metadataRequest)
            reports.forEach(context.delete)
            metadata.forEach(context.delete)
            if let decision {
                try decisionPreferences.writeWithoutSaving(decision, updatedAt: Date())
            }
            return reports.count + metadata.count
        }
    }
}
