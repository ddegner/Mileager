import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public enum ActiveDriveStoreError: Error, LocalizedError {
    case corruptState

    public var errorDescription: String? {
        switch self {
        case .corruptState:
            String(
                localized: "The active drive checkpoint could not be decoded.",
                bundle: .appCoreStrings
            )
        }
    }
}

public final class ActiveDriveStore {
    private static let singletonID = "current"

    private let context: NSManagedObjectContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(context: NSManagedObjectContext) {
        self.context = context
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> DriveCaptureState? {
        guard let entity = try fetchEntity() else { return nil }
        do {
            var state = try decoder.decode(DriveCaptureState.self, from: entity.stateData)
            var repaired = try repairStaleIdlePendingTripIDIfNeeded(&state)
            if repairInvalidRecentCandidateTimingIfNeeded(&state) {
                repaired = true
            }
            if repaired {
                try save(state)
            }
            return state
        } catch is DecodingError {
            throw ActiveDriveStoreError.corruptState
        } catch {
            throw error
        }
    }

    @discardableResult
    public func save(_ state: DriveCaptureState) throws -> DriveCaptureState {
        try context.saveTransaction {
            let entity = try fetchEntity() ?? ActiveDriveEntity.insert(into: context)
            entity.id = Self.singletonID
            entity.captureID = state.captureID
            entity.pendingTripID = state.pendingTripID
            entity.phaseRaw = state.phase.rawValue
            entity.candidateStartedAt = state.candidateStartedAt
            entity.startedAt = state.startedAt
            entity.lastMovingAt = state.lastMovingAt
            entity.firstStationaryAt = state.firstStationaryAt
            entity.stopDueAt = state.stopDueAt
            entity.lastProcessedLocationTimestamp = state.lastProcessedLocationTimestamp
            entity.sampleCount = Int64(state.samples.count + state.candidateSamples.count)
            entity.stateData = try encoder.encode(state)
            entity.updatedAt = Date()
            try deleteDuplicateEntities(keeping: entity)
            return state
        }
    }

    public func clear() throws {
        try context.saveTransaction {
            let request = ActiveDriveEntity.fetchRequest()
            for entity in try context.fetch(request) {
                context.delete(entity)
            }
        }
    }

    public func describeForDiagnostics() throws -> String {
        guard let state = try load() else {
            return "No active drive checkpoint"
        }
        let pending = state.pendingCompletionDraft.map { " pendingCompletion=\($0.id)" } ?? ""
        let stopDue = state.stopDueAt.map { " stopDueAt=\($0)" } ?? ""
        let parking = state.parkingEvidence.map {
            " parking=\($0.signal.rawValue) inferredEndAt=\($0.inferredEndAt)"
        } ?? ""
        return "Active drive phase=\(state.phase.rawValue) captureID=\(state.captureID) samples=\(state.samples.count) candidateSamples=\(state.candidateSamples.count)\(stopDue)\(parking)\(pending)"
    }

    private func fetchEntity() throws -> ActiveDriveEntity? {
        try ActiveDriveEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "id == %@", Self.singletonID)
        )
    }

    private func repairStaleIdlePendingTripIDIfNeeded(_ state: inout DriveCaptureState) throws -> Bool {
        guard state.phase == .idle,
              state.samples.isEmpty,
              state.candidateSamples.isEmpty,
              state.pendingCompletionDraft == nil,
              let pendingTripID = state.pendingTripID,
              try TripEntity.fetchOne(in: context, where: NSPredicate(format: "id == %@", pendingTripID as CVarArg)) != nil else {
            return false
        }
        state.pendingTripID = nil
        return true
    }

    private func repairInvalidRecentCandidateTimingIfNeeded(_ state: inout DriveCaptureState) -> Bool {
        guard var recentCandidate = state.recentCandidate,
              let candidateStartedAt = recentCandidate.candidateStartedAt,
              recentCandidate.killedAt < candidateStartedAt else {
            return false
        }
        // Older builds sometimes persisted the timestamp of stale GPS evidence
        // as the rejection time. The actual receipt time is unknowable after
        // relaunch, so clamp the legacy value to the candidate start.
        recentCandidate.killedAt = candidateStartedAt
        state.recentCandidate = recentCandidate
        return true
    }

    private func deleteDuplicateEntities(keeping kept: ActiveDriveEntity) throws {
        let request = ActiveDriveEntity.fetchRequest()
        for entity in try context.fetch(request) where entity !== kept {
            context.delete(entity)
        }
    }

}
