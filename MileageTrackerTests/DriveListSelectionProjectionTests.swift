import Foundation
import XCTest
@testable import MileageTracker

final class DriveListInteractionPolicyTests: XCTestCase {
    func testPlatformAndShellPolicyMatrix() {
        let matrix: [(isMac: Bool, showsSelection: Bool, expected: DriveListInteractionPolicy)] = [
            (false, false, .primaryActionDriven),
            (false, true, .primaryActionDriven),
            (true, false, .primaryActionDriven),
            (true, true, .selectionDriven)
        ]

        for entry in matrix {
            let policy = DriveListInteractionPolicy.resolve(
                isMac: entry.isMac,
                showsSelection: entry.showsSelection
            )
            XCTAssertEqual(
                policy,
                entry.expected,
                "Unexpected policy for isMac=\(entry.isMac), showsSelection=\(entry.showsSelection)"
            )
            XCTAssertEqual(
                policy.attachesPrimaryAction,
                (policy == .primaryActionDriven),
                "Only the expanded Mac list may omit primaryAction"
            )
        }
    }
}

final class CompactMacSelectionGenerationPolicyTests: XCTestCase {
    func testOnlyCurrentUncancelledGenerationMayCommit() {
        let first = CompactMacSelectionGenerationPolicy.advanced(from: 0)
        let replacement = CompactMacSelectionGenerationPolicy.advanced(from: first)
        XCTAssertGreaterThan(replacement, first)

        XCTAssertTrue(
            CompactMacSelectionGenerationPolicy.canCommit(
                captured: replacement,
                current: replacement,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            CompactMacSelectionGenerationPolicy.canCommit(
                captured: first,
                current: replacement,
                isCancelled: false
            ),
            "A stale task must not clear newer shared state"
        )
        XCTAssertFalse(
            CompactMacSelectionGenerationPolicy.canCommit(
                captured: replacement,
                current: replacement,
                isCancelled: true
            )
        )
        XCTAssertFalse(
            CompactMacSelectionGenerationPolicy.canCommit(
                captured: replacement,
                current: replacement,
                isCancelled: false,
                selectionUnchanged: false
            )
        )
    }
}

/// Visible-order targeting and pruning over SwiftUI's native Set selection.
final class DriveListSelectionProjectionTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()
    private let hidden = UUID()

    private var visibleOrder: [UUID] { [first, second, third] }

    func testOrderedSelectionUsesVisibleRowOrder() {
        XCTAssertEqual(
            DriveListSelectionProjection.ordered(
                [third, first, second], visibleOrder: visibleOrder
            ),
            [first, second, third]
        )
    }

    func testOrderedSelectionOmitsIDsOutsideThisList() {
        XCTAssertEqual(
            DriveListSelectionProjection.ordered(
                [hidden, second], visibleOrder: visibleOrder
            ),
            [second]
        )
    }

    func testReorderingRowsReordersBulkTargetsWithoutChangingSelection() {
        let selected: Set<UUID> = [first, third]
        XCTAssertEqual(
            DriveListSelectionProjection.ordered(
                selected, visibleOrder: [third, second, first]
            ),
            [third, first]
        )
        XCTAssertEqual(selected, [first, third])
    }

    func testPruningKeepsOnlyVisibleIDs() {
        XCTAssertEqual(
            DriveListSelectionProjection.pruned(
                [first, hidden, third], visibleOrder: visibleOrder
            ),
            [first, third]
        )
    }

    func testEmptyVisibleOrderPrunesEverything() {
        XCTAssertTrue(
            DriveListSelectionProjection.pruned(
                [first, second], visibleOrder: []
            ).isEmpty
        )
    }
}

/// The two keyboard moves the Mac list resolves itself, because bare arrows
/// never reach a Designed-for-iPad list and the chords arrive as menu commands.
final class DriveListKeyboardSelectionTests: XCTestCase {
    private let rows = (0..<5).map { _ in UUID() }

    func testStepEntersAnEmptyListFromTheEndNearestTheKey() {
        XCTAssertEqual(DriveListSelectionProjection.stepped([], by: 1, visibleOrder: rows), rows[0])
        XCTAssertEqual(DriveListSelectionProjection.stepped([], by: -1, visibleOrder: rows), rows[4])
        XCTAssertNil(DriveListSelectionProjection.stepped([], by: 1, visibleOrder: []))
    }

    func testStepMovesASingletonAndStopsAtTheEdges() {
        XCTAssertEqual(DriveListSelectionProjection.stepped([rows[2]], by: 1, visibleOrder: rows), rows[3])
        XCTAssertEqual(DriveListSelectionProjection.stepped([rows[2]], by: -1, visibleOrder: rows), rows[1])
        XCTAssertNil(DriveListSelectionProjection.stepped([rows[4]], by: 1, visibleOrder: rows))
        XCTAssertNil(DriveListSelectionProjection.stepped([rows[0]], by: -1, visibleOrder: rows))
    }

    func testStepCollapsesAMultiSelectionPastItsEdge() {
        let selection: Set<UUID> = [rows[1], rows[3]]
        XCTAssertEqual(DriveListSelectionProjection.stepped(selection, by: 1, visibleOrder: rows), rows[4])
        XCTAssertEqual(DriveListSelectionProjection.stepped(selection, by: -1, visibleOrder: rows), rows[0])
    }

    func testExtendGrowsFromTheAnchorThenShrinksBackTowardIt() {
        var selection: Set<UUID> = [rows[2]]
        let anchor = rows[2]

        var move = DriveListSelectionProjection.extended(selection, anchor: anchor, by: 1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[2], rows[3]])
        XCTAssertEqual(move.focus, rows[3])
        selection = move.selection

        move = DriveListSelectionProjection.extended(selection, anchor: anchor, by: 1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[2], rows[3], rows[4]])
        selection = move.selection

        // Reversing direction shrinks the far end, not the anchor's side.
        move = DriveListSelectionProjection.extended(selection, anchor: anchor, by: -1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[2], rows[3]])
        XCTAssertEqual(move.focus, rows[3])
        selection = move.selection

        move = DriveListSelectionProjection.extended(selection, anchor: anchor, by: -1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[2]])
        move = DriveListSelectionProjection.extended(move.selection, anchor: anchor, by: -1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[1], rows[2]], "Past the anchor the range grows the other way")
        XCTAssertEqual(move.focus, rows[1])
    }

    func testExtendAtTheEdgeChangesNothing() {
        let move = DriveListSelectionProjection.extended([rows[4]], anchor: rows[4], by: 1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[4]])
        XCTAssertNil(move.focus)
    }

    func testExtendWithoutAUsableAnchorUsesTheEdgeNearestTheKey() {
        let selection: Set<UUID> = [rows[1], rows[2]]
        let down = DriveListSelectionProjection.extended(selection, anchor: nil, by: 1, visibleOrder: rows)
        XCTAssertEqual(down.selection, [rows[1], rows[2], rows[3]])
        let stale = DriveListSelectionProjection.extended(selection, anchor: rows[4], by: -1, visibleOrder: rows)
        XCTAssertEqual(stale.selection, [rows[0], rows[1], rows[2]], "An anchor outside the selection is ignored")
    }

    func testExtendFromNothingStepsIn() {
        let move = DriveListSelectionProjection.extended([], anchor: nil, by: 1, visibleOrder: rows)
        XCTAssertEqual(move.selection, [rows[0]])
        XCTAssertEqual(move.focus, rows[0])
    }
}
