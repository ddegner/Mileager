import AppCoreModels
import Foundation

/// Review changes are one transaction, including category plus purpose. Never
/// publish an optimistic decision that a later checkpoint could accidentally save.
public enum CurrentDriveEdit: Sendable {
    case classification(TripClassification?, purpose: String? = nil)
    case purpose(String?)
    case note(String?)
    case appendNote(String)
}

public enum CurrentDriveEditError: Error {
    case driveNoLongerCurrent
}

extension DriveCaptureReducer {
    @discardableResult
    public mutating func commitCurrentDriveEdit(
        _ edit: CurrentDriveEdit,
        expectedID: UUID,
        persist: (DriveCaptureState) throws -> Void
    ) throws -> CurrentDriveSummary {
        guard state.currentDriveSummary()?.pendingTripID == expectedID else {
            throw CurrentDriveEditError.driveNoLongerCurrent
        }
        var candidate = self
        switch edit {
        case let .classification(category, purpose):
            _ = candidate.setCurrentDriveClassification(category)
            if category == .business, let purpose {
                _ = candidate.setCurrentDriveBusinessPurpose(purpose)
            }
        case let .purpose(purpose):
            _ = candidate.setCurrentDriveBusinessPurpose(purpose)
        case let .note(note):
            _ = candidate.setCurrentDriveNote(note)
        case let .appendNote(note):
            let existing = state.currentDriveSummary()?.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = candidate.setCurrentDriveNote(
                [existing, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
        guard let updated = candidate.state.currentDriveSummary() else {
            throw CurrentDriveEditError.driveNoLongerCurrent
        }
        try persist(candidate.state)
        self = candidate
        return updated
    }
}
