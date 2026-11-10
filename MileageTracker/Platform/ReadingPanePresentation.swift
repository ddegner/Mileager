import Foundation

/// The root content of the expanded split view's reading pane.
///
/// This is deliberately a value, not navigation state. Peer trips replace the
/// reading pane's root in place; they are never pushed onto a detail stack.
enum ReadingPanePresentation: Equatable {
    case empty
    case trip(UUID)
    case multiple([UUID])
}

enum ReadingPanePresentationResolver {
    /// Resolves the platform-specific reading-pane contract from root-owned
    /// state. On Mac the selection is the presentation. On iPad, selection is
    /// only a batch-operation concern and the most recent primary action owns
    /// the reading pane.
    static func resolve(
        isMac: Bool,
        selection: Set<UUID>,
        orderedTripIDs: [UUID],
        presentedTripID: UUID?,
        availableTripIDs: Set<UUID>
    ) -> ReadingPanePresentation {
        if isMac {
            let orderedSelection = orderedValidSelection(
                selection,
                orderedTripIDs: orderedTripIDs,
                availableTripIDs: availableTripIDs
            )
            switch orderedSelection.count {
            case 0:
                return .empty
            case 1:
                return .trip(orderedSelection[0])
            default:
                return .multiple(orderedSelection)
            }
        }

        guard let presentedTripID, availableTripIDs.contains(presentedTripID) else {
            return .empty
        }
        return .trip(presentedTripID)
    }

    /// Keeps the list's visible order for batch summaries. A deterministic
    /// fallback also lets a deep-linked singleton render before its list has
    /// reported an order, without allowing deleted IDs into the pane.
    private static func orderedValidSelection(
        _ selection: Set<UUID>,
        orderedTripIDs: [UUID],
        availableTripIDs: Set<UUID>
    ) -> [UUID] {
        let validSelection = selection.intersection(availableTripIDs)
        var seen = Set<UUID>()
        var result = orderedTripIDs.filter {
            validSelection.contains($0) && seen.insert($0).inserted
        }
        result.append(contentsOf: validSelection.subtracting(seen).sorted {
            $0.uuidString < $1.uuidString
        })
        return result
    }
}
