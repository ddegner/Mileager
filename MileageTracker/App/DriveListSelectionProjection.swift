import Foundation

/// Chooses which interaction SwiftUI owns for a trip list.
///
/// The expanded Mac list is selection-driven: attaching a context-menu
/// `primaryAction` changes how a Designed-for-iPad host delivers clicks and
/// reintroduces the empty-selection race. Touch lists still need that primary
/// action to open a trip, and the compact Mac keeps it as a narrow-window
/// fallback because there is no adjacent reading pane for a selection to
/// drive. Click selection itself remains SwiftUI's responsibility through the
/// direct `List(selection:)` binding.
enum DriveListInteractionPolicy: Equatable {
    case primaryActionDriven
    case selectionDriven

    static func resolve(isMac: Bool, showsSelection: Bool) -> Self {
        isMac && showsSelection ? .selectionDriven : .primaryActionDriven
    }

    var attachesPrimaryAction: Bool {
        self == .primaryActionDriven
    }
}

/// Pure commit gate for the compact-Mac tasks that coalesce the host's
/// primary-action selection writes. Cancellation alone is insufficient
/// because `Task.yield()` is nonthrowing; a newer generation must also own the
/// shared state before an older task can clear it.
enum CompactMacSelectionGenerationPolicy {
    static func advanced(from current: UInt64) -> UInt64 {
        current + 1
    }

    static func canCommit(
        captured: UInt64,
        current: UInt64,
        isCancelled: Bool,
        selectionUnchanged: Bool = true
    ) -> Bool {
        !isCancelled && captured == current && selectionUnchanged
    }
}

/// Pure projections over SwiftUI's authoritative `Set` selection.
///
/// These helpers provide a deterministic order for bulk actions, discard IDs
/// that filtering/deletion/synchronization removed, and resolve keyboard moves
/// a Designed-for-iPad list cannot receive natively: bare arrows never reach
/// it (FB13644182), so ⌘↑/⌘↓ and ⇧⌘↑/⇧⌘↓ arrive as Trips-menu commands here.
enum DriveListSelectionProjection {
    static func ordered(_ selection: Set<UUID>, visibleOrder: [UUID]) -> [UUID] {
        visibleOrder.filter(selection.contains)
    }

    static func pruned(_ selection: Set<UUID>, visibleOrder: [UUID]) -> Set<UUID> {
        selection.intersection(visibleOrder)
    }

    /// The row ⌘↑/⌘↓ should land on: one step from the selection's edge in
    /// the direction of travel, clamped to the list. An empty selection enters
    /// the list from the end nearest the key (⌘↓ = first row, ⌘↑ = last), and
    /// a multi-selection collapses onto the row past its bottom (or top)
    /// member, which is what Finder does. `nil` when there is nowhere to go.
    static func stepped(_ selection: Set<UUID>, by offset: Int, visibleOrder: [UUID]) -> UUID? {
        guard !visibleOrder.isEmpty, offset != 0 else { return nil }
        let selectedIndices = visibleOrder.indices.filter { selection.contains(visibleOrder[$0]) }
        let target: Int
        if let edge = offset > 0 ? selectedIndices.max() : selectedIndices.min() {
            target = edge + offset
        } else {
            target = offset > 0 ? 0 : visibleOrder.count - 1
        }
        guard visibleOrder.indices.contains(target) else { return nil }
        return visibleOrder[target]
    }

    /// The selection ⇧⌘↑/⇧⌘↓ should produce, and the row that moved (for the
    /// list to scroll to). `nil` focus means nothing changed.
    ///
    /// The anchor is the row a plain click made the singleton selection; the
    /// moving end is whichever edge lies on the far side of it, so growing
    /// past that edge and shrinking back toward the anchor are the same move —
    /// exactly how a Mac list treats ⇧↓ after ⇧↑. Without a usable anchor
    /// (none recorded, or its row left the selection) the edge nearest the
    /// key becomes the anchor, and an empty selection simply steps in.
    static func extended(
        _ selection: Set<UUID>,
        anchor: UUID?,
        by offset: Int,
        visibleOrder: [UUID]
    ) -> (selection: Set<UUID>, focus: UUID?) {
        guard !visibleOrder.isEmpty, offset != 0 else { return (selection, nil) }
        let selectedIndices = visibleOrder.indices.filter { selection.contains(visibleOrder[$0]) }
        guard let lowest = selectedIndices.min(), let highest = selectedIndices.max() else {
            guard let id = stepped(selection, by: offset, visibleOrder: visibleOrder) else {
                return (selection, nil)
            }
            return ([id], id)
        }
        let anchorIndex = anchor
            .flatMap { visibleOrder.firstIndex(of: $0) }
            .flatMap { selectedIndices.contains($0) ? $0 : nil }
            ?? (offset > 0 ? lowest : highest)
        let movingEnd: Int
        if highest > anchorIndex {
            movingEnd = highest
        } else if lowest < anchorIndex {
            movingEnd = lowest
        } else {
            movingEnd = anchorIndex
        }
        let newEnd = movingEnd + offset
        guard visibleOrder.indices.contains(newEnd) else { return (selection, nil) }
        let range = min(anchorIndex, newEnd)...max(anchorIndex, newEnd)
        return (Set(visibleOrder[range]), visibleOrder[newEnd])
    }
}
