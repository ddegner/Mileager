import Foundation

/// What a ⌘-menu classify/delete verb should act on. The rule (David's call,
/// 08-31): a non-empty Select-mode selection wins over the trip open in the
/// reading pane, because checking rows is the more deliberate gesture — the
/// reading pane merely shows the first checked trip while selecting.
enum DriveCommandTarget: Equatable {
    case selection
    case detail
    case none
}

enum DriveCommandTargetResolution {
    static func classifyTarget(selectedTripIDs: [UUID], hasDetail: Bool) -> DriveCommandTarget {
        if !selectedTripIDs.isEmpty { return .selection }
        return hasDetail ? .detail : .none
    }
}
