import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// The ⌘-menu plumbing: which period the export commands resolve to, and the
/// closure-excluding equality contract every focused value must keep (a value
/// whose == never holds re-publishes every body pass and trips SwiftUI's
/// "FocusedValue update tried to update multiple times per frame" loop).
final class DriveCommandFocusedValueTests: XCTestCase {
    private let june = DriveMonthSummary.monthInterval(containing: DateComponents(
        calendar: .current, year: 2026, month: 6, day: 15
    ).date!).start
    private let year2026 = AnnualReportBreakdown.yearInterval(containing: DateComponents(
        calendar: .current, year: 2026, month: 6, day: 15
    ).date!).start

    func testExportScopeResolution() {
        XCTAssertNil(ExportScopeResolution.exportPeriodScope(in: []))
        XCTAssertNil(ExportScopeResolution.exportPeriodScope(in: [.needsReview]))
        XCTAssertNil(ExportScopeResolution.exportPeriodScope(in: [.allTrips, .trip(UUID())]))
        XCTAssertEqual(
            ExportScopeResolution.exportPeriodScope(in: [.month(june)]),
            .month(june)
        )
        XCTAssertEqual(
            ExportScopeResolution.exportPeriodScope(in: [.month(june), .trip(UUID())]),
            .month(june),
            "A trip pushed from June still exports June"
        )
        XCTAssertEqual(
            ExportScopeResolution.exportPeriodScope(in: [.year(year2026)]),
            .year(year2026)
        )
        XCTAssertEqual(
            ExportScopeResolution.exportPeriodScope(in: [.year(year2026), .month(june)]),
            .month(june),
            "The innermost period wins"
        )
    }

    func testDefaultNewTripDateResolution() {
        XCTAssertNil(ExportScopeResolution.defaultNewTripDate(in: []))
        XCTAssertNil(
            ExportScopeResolution.defaultNewTripDate(in: [.needsReview]),
            "Cross-period scopes have no date opinion"
        )
        XCTAssertEqual(
            ExportScopeResolution.defaultNewTripDate(in: [.month(june), .trip(UUID())]),
            DriveListScope.month(june).defaultNewTripDate
        )
    }

    func testDriveCommandActionsEqualityIgnoresClosures() {
        func make(
            ids: [UUID],
            sort: DriveSortOption = .newestFirst,
            selecting: Bool = true,
            presets: [String] = ["Client Visit"],
            supportsKeyboardSelection: Bool = false,
            vehicles: [DriveCommandVehicle] = [],
            calls: @escaping () -> Void
        ) -> DriveCommandActions {
            DriveCommandActions(
                sortOption: sort,
                selectionModeActive: selecting,
                canMergeSelection: false,
                selectedTripIDs: ids,
                businessPurposePresets: presets,
                supportsKeyboardSelection: supportsKeyboardSelection,
                setSortOption: { _ in calls() },
                cycleSortOption: calls,
                toggleSelectionMode: calls,
                deselectAll: calls,
                stepSelection: { _ in calls() },
                extendSelection: { _ in calls() },
                mergeSelected: calls,
                classifySelection: { _, _ in calls() },
                deleteSelection: calls,
                vehicles: vehicles,
                customPurpose: calls,
                clearPurpose: calls,
                assignVehicle: { _ in calls() }
            )
        }
        let ids = [UUID()]
        XCTAssertEqual(make(ids: ids, calls: {}), make(ids: ids, calls: { print("different closure") }))
        XCTAssertNotEqual(make(ids: ids, calls: {}), make(ids: [UUID()], calls: {}))
        // Every remaining compared field, in the != direction. Without these,
        // dropping one from `==` leaves the suite green and the menu stale:
        // the sort marker freezes on the old option, the item stays on
        // "Select Trips" after Select mode is entered, and the Classify menu
        // goes on listing purposes the user has already changed.
        XCTAssertNotEqual(
            make(ids: ids, sort: .newestFirst, calls: {}),
            make(ids: ids, sort: .oldestFirst, calls: {})
        )
        XCTAssertNotEqual(
            make(ids: ids, selecting: true, calls: {}),
            make(ids: ids, selecting: false, calls: {})
        )
        XCTAssertNotEqual(
            make(ids: ids, presets: ["Client Visit"], calls: {}),
            make(ids: ids, presets: ["Client Visit", "Site"], calls: {})
        )
        XCTAssertNotEqual(
            make(ids: ids, supportsKeyboardSelection: true, calls: {}),
            make(ids: ids, supportsKeyboardSelection: false, calls: {})
        )
        let vehicleID = UUID()
        XCTAssertNotEqual(
            make(ids: ids, vehicles: [DriveCommandVehicle(id: vehicleID, name: "Van")], calls: {}),
            make(ids: ids, vehicles: [], calls: {}),
            "The Assign Vehicle submenu renders from this list"
        )
    }

    func testTripDetailCommandActionsEqualityIgnoresClosures() {
        func make(id: UUID, canExport: Bool, calls: @escaping () -> Void) -> TripDetailCommandActions {
            TripDetailCommandActions(
                tripID: id,
                canNavigatePrevious: false,
                canNavigateNext: true,
                canExport: canExport,
                navigatePrevious: calls,
                navigateNext: calls,
                exportPDF: calls,
                classify: { _ in calls() },
                confirmDelete: calls
            )
        }
        let id = UUID()
        XCTAssertEqual(make(id: id, canExport: true, calls: {}), make(id: id, canExport: true, calls: { print("x") }))
        XCTAssertNotEqual(make(id: id, canExport: true, calls: {}), make(id: id, canExport: false, calls: {}))
    }

    func testClassifyTargetPrefersSelectionOverDetail() {
        // David's call (08-31): checking rows is the more deliberate gesture,
        // so a non-empty Select-mode selection wins over the reading-pane trip.
        let ids = [UUID(), UUID()]
        XCTAssertEqual(
            DriveCommandTargetResolution.classifyTarget(selectedTripIDs: ids, hasDetail: true),
            .selection
        )
        XCTAssertEqual(
            DriveCommandTargetResolution.classifyTarget(selectedTripIDs: ids, hasDetail: false),
            .selection
        )
        XCTAssertEqual(
            DriveCommandTargetResolution.classifyTarget(selectedTripIDs: [], hasDetail: true),
            .detail
        )
        XCTAssertEqual(
            DriveCommandTargetResolution.classifyTarget(selectedTripIDs: [], hasDetail: false),
            .none
        )
    }

    func testDriveSceneCommandActionsEqualityIgnoresClosures() {
        func make(canGoBack: Bool, calls: @escaping () -> Void) -> DriveSceneCommandActions {
            DriveSceneCommandActions(
                canGoBack: canGoBack,
                openNeedsReview: calls,
                openAllTrips: calls,
                openCurrentMonth: calls,
                goBack: calls,
                addTrip: calls,
                openSettings: calls
            )
        }
        XCTAssertEqual(make(canGoBack: true, calls: {}), make(canGoBack: true, calls: { print("x") }))
        XCTAssertNotEqual(make(canGoBack: true, calls: {}), make(canGoBack: false, calls: {}))
    }
}
