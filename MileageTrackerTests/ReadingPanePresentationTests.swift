import XCTest

@testable import MileageTracker

final class ReadingPanePresentationTests: XCTestCase {
    private let tripA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let tripB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let tripC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private var available: Set<UUID> { [tripA, tripB, tripC] }

    private func resolve(
        isMac: Bool,
        selection: Set<UUID> = [],
        order: [UUID] = [],
        presentedTripID: UUID? = nil,
        availableTripIDs: Set<UUID>? = nil
    ) -> ReadingPanePresentation {
        ReadingPanePresentationResolver.resolve(
            isMac: isMac,
            selection: selection,
            orderedTripIDs: order,
            presentedTripID: presentedTripID,
            availableTripIDs: availableTripIDs ?? available
        )
    }

    func testMacZeroOneAndManyFollowSelection() {
        XCTAssertEqual(resolve(isMac: true), .empty)
        XCTAssertEqual(
            resolve(isMac: true, selection: [tripB], order: [tripA, tripB, tripC]),
            .trip(tripB)
        )
        XCTAssertEqual(
            resolve(isMac: true, selection: [tripA, tripC], order: [tripC, tripB, tripA]),
            .multiple([tripC, tripA])
        )
    }

    func testMacDirectReplacementNeverResolvesAnIntermediateEmptyPane() {
        let presentations = [Set([tripA]), Set([tripB])].map {
            resolve(isMac: true, selection: $0, order: [tripA, tripB])
        }

        XCTAssertEqual(presentations, [.trip(tripA), .trip(tripB)])
        XCTAssertFalse(presentations.contains(.empty))
    }

    func testIPadPrimaryActionOwnsThePaneAndSelectionDoesNotNavigate() {
        XCTAssertEqual(
            resolve(
                isMac: false,
                selection: [tripB, tripC],
                order: [tripB, tripC],
                presentedTripID: tripA
            ),
            .trip(tripA)
        )
        XCTAssertEqual(
            resolve(isMac: false, selection: [tripB], order: [tripB]),
            .empty
        )
    }

    func testDeletedTripsCannotRemainPresented() {
        XCTAssertEqual(
            resolve(
                isMac: true,
                selection: [tripA, tripB],
                order: [tripA, tripB],
                availableTripIDs: [tripB]
            ),
            .trip(tripB)
        )
        XCTAssertEqual(
            resolve(
                isMac: false,
                presentedTripID: tripA,
                availableTripIDs: [tripB]
            ),
            .empty
        )
    }

    func testMacDeepLinkCanPresentBeforeVisibleOrderArrives() {
        XCTAssertEqual(
            resolve(isMac: true, selection: [tripC]),
            .trip(tripC)
        )
    }

    func testMacMultipleSelectionUsesDeterministicFallbackForUnreportedRows() {
        XCTAssertEqual(
            resolve(isMac: true, selection: [tripC, tripA], order: []),
            .multiple([tripA, tripC])
        )
    }
}
