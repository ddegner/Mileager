import AppCoreModels
import DriveCaptureEngine
import Foundation

/// The trip rows touched by one successful `TripStore` save. Upserts carry the
/// post-change summary; deletions carry only the stable trip ID because the row
/// no longer exists.
public struct TripChangeSet: Sendable, Equatable {
    public var upserted: [TripSummary]
    public var deletedIDs: [UUID]

    public init(upserted: [TripSummary] = [], deletedIDs: [UUID] = []) {
        self.upserted = upserted
        self.deletedIDs = deletedIDs
    }

    public var isEmpty: Bool { upserted.isEmpty && deletedIDs.isEmpty }
}

/// Receives trip changes after they are durably saved. Fired once per
/// `TripStore` transaction, never on rollback. AppCore stays platform-neutral:
/// the app layer implements this to keep external mirrors (e.g. the Spotlight
/// index) in sync without AppCore linking search frameworks.
public protocol TripStoreChangeObserver: AnyObject {
    func tripStoreDidChange(_ change: TripChangeSet)
}
