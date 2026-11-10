import AppCore
import XCTest
@testable import MileageTracker

/// The fee-preset editor never writes its draft list directly: user
/// operations are replayed onto the current (possibly remotely updated)
/// list. These tests pin the two review findings — an invalid row must not
/// discard the session's edits, and a sync import while the page is open
/// must never be clobbered or tombstoned by the pop save.
final class FeePresetMergeTests: XCTestCase {
    private func preset(
        _ label: String,
        category: TripFeeCategory = .toll,
        amount: Double = 5,
        sortOrder: Int = 0
    ) -> TripFeePreset {
        TripFeePreset(category: category, label: label, amount: amount, sortOrder: sortOrder)
    }

    private func drafts(from presets: [TripFeePreset]) -> [FeePresetDraft] {
        presets.map(FeePresetDraft.init)
    }

    func testNoLocalEditsProducesNoSaveEvenAfterRemoteImport() {
        let baseline = [preset("GW Bridge", sortOrder: 0)]
        let remoteAdded = baseline + [preset("Airport", category: .parking, amount: 18, sortOrder: 1)]
        XCTAssertNil(FeePresetMergePlan.merge(
            drafts: drafts(from: baseline),
            baseline: baseline,
            current: remoteAdded
        ))
    }

    func testInvalidRowFallsBackToBaselineInsteadOfDiscardingEverything() {
        let bridge = preset("GW Bridge", sortOrder: 0)
        let airport = preset("Airport", category: .parking, amount: 18, sortOrder: 1)
        let baseline = [bridge, airport]
        var edited = drafts(from: baseline)
        edited[0].label = "GWB Upper"
        edited[1].amountText = ""

        let merged = FeePresetMergePlan.merge(drafts: edited, baseline: baseline, current: baseline)
        XCTAssertEqual(merged?.map(\.label), ["GWB Upper", "Airport"])
        XCTAssertEqual(merged?.map(\.amount), [5, 18])
    }

    func testAbandonedAddRowIsDroppedAndOtherEditsSurvive() {
        let baseline = [preset("GW Bridge", sortOrder: 0)]
        var edited = drafts(from: baseline)
        edited[0].amountText = "7.25"
        edited.append(FeePresetDraft())

        let merged = FeePresetMergePlan.merge(drafts: edited, baseline: baseline, current: baseline)
        XCTAssertEqual(merged?.map(\.label), ["GW Bridge"])
        XCTAssertEqual(merged?.map(\.amount), [7.25])
    }

    func testRemoteAdditionSurvivesSaveWithLocalEdits() {
        let bridge = preset("GW Bridge", sortOrder: 0)
        let baseline = [bridge]
        let remote = preset("Garage", category: .parking, amount: 32, sortOrder: 1)
        var edited = drafts(from: baseline)
        edited[0].amountText = "8.00"

        let merged = FeePresetMergePlan.merge(
            drafts: edited,
            baseline: baseline,
            current: [bridge, remote]
        )
        XCTAssertEqual(merged?.map(\.label), ["GW Bridge", "Garage"])
        XCTAssertEqual(merged?.map(\.amount), [8.00, 32])
    }

    func testRemoteEditToUntouchedRowWinsAndLocalEditWinsOverRemote() {
        let bridge = preset("GW Bridge", sortOrder: 0)
        let airport = preset("Airport", category: .parking, amount: 18, sortOrder: 1)
        let baseline = [bridge, airport]
        var remoteBridge = bridge
        remoteBridge.amount = 9.50
        var remoteAirport = airport
        remoteAirport.amount = 20
        var edited = drafts(from: baseline)
        edited[1].amountText = "25.00"

        let merged = FeePresetMergePlan.merge(
            drafts: edited,
            baseline: baseline,
            current: [remoteBridge, remoteAirport]
        )
        XCTAssertEqual(merged?.map(\.amount), [9.50, 25.00])
    }

    func testUserDeletionRemovesOnlyThatKeyAndRemoteDeletionOfUntouchedRowIsHonored() {
        let bridge = preset("GW Bridge", sortOrder: 0)
        let airport = preset("Airport", category: .parking, amount: 18, sortOrder: 1)
        let garage = preset("Garage", category: .parking, amount: 32, sortOrder: 2)
        let baseline = [bridge, airport, garage]
        var edited = drafts(from: baseline)
        edited.remove(at: 1) // user deletes Airport
        edited[0].amountText = "7.00"

        // Garage was remotely deleted while the page was open and the user
        // never touched it — the deletion is honored.
        let merged = FeePresetMergePlan.merge(
            drafts: edited,
            baseline: baseline,
            current: [bridge]
        )
        XCTAssertEqual(merged?.map(\.label), ["GW Bridge"])
        XCTAssertEqual(merged?.map(\.amount), [7.00])
    }

    func testReorderOnlyIsSaved() {
        let bridge = preset("GW Bridge", sortOrder: 0)
        let airport = preset("Airport", category: .parking, amount: 18, sortOrder: 1)
        let baseline = [bridge, airport]
        var edited = drafts(from: baseline)
        edited.swapAt(0, 1)

        let merged = FeePresetMergePlan.merge(drafts: edited, baseline: baseline, current: baseline)
        XCTAssertEqual(merged?.map(\.label), ["Airport", "GW Bridge"])
        XCTAssertEqual(merged?.map(\.sortOrder), [0, 1])
    }

    func testEmptyLabelFallsBackToCategoryNameAndDuplicateIdentityIsFlagged() {
        var draft = FeePresetDraft()
        draft.amountText = "5.00"
        let resolved = FeePresetMergePlan.resolved(drafts: [draft], baseline: [])
        XCTAssertEqual(resolved.map(\.label), [TripFeeCategory.toll.displayName])

        var second = FeePresetDraft()
        second.amountText = "9.00"
        XCTAssertTrue(FeePresetMergePlan.hasDuplicateIdentity(drafts: [draft, second]))
    }
}
