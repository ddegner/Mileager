import AppCoreModels
import Foundation
import XCTest
@testable import DriveCaptureEngine

final class CurrentDriveEditTests: XCTestCase {
    private func recording() -> DriveCaptureReducer {
        var state = DriveCaptureState()
        state.phase = .recording
        state.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.pendingTripID = UUID()
        state.pendingClassification = .personal
        return DriveCaptureReducer(state: state)
    }

    func testSaveFailurePreservesDecisionAndCannotLeakIntoLaterCheckpoint() throws {
        enum DiskFailure: Error { case full }
        var reducer = recording()
        let before = reducer.state
        let id = try XCTUnwrap(before.pendingTripID)
        XCTAssertThrowsError(try reducer.commitCurrentDriveEdit(
            .classification(.business, purpose: "Client visit"), expectedID: id
        ) { _ in throw DiskFailure.full })
        XCTAssertEqual(reducer.state, before)
        var saved: DriveCaptureState?
        try reducer.commitCurrentDriveEdit(.note("Garage"), expectedID: id) { saved = $0 }
        XCTAssertEqual(saved?.pendingClassification, .personal)
        XCTAssertNil(saved?.pendingBusinessPurpose)
        XCTAssertEqual(saved?.pendingNote, "Garage")
    }

    func testStaleIdentityNeverCallsPersistence() throws {
        var reducer = recording()
        let before = reducer.state
        XCTAssertThrowsError(try reducer.commitCurrentDriveEdit(.classification(.business), expectedID: UUID()) { _ in
            XCTFail("A stale reference must never write the current drive")
        })
        XCTAssertEqual(reducer.state, before)
    }

    func testCategoryAndPurposePersistTogetherAndPersonalClearsPurpose() throws {
        var reducer = recording()
        let id = try XCTUnwrap(reducer.state.pendingTripID)
        var saves = 0
        try reducer.commitCurrentDriveEdit(.classification(.business, purpose: "Client"), expectedID: id) {
            saves += 1
            XCTAssertEqual($0.pendingClassification, .business)
            XCTAssertEqual($0.pendingBusinessPurpose, "Client")
        }
        XCTAssertEqual(saves, 1)
        try reducer.commitCurrentDriveEdit(.classification(.personal), expectedID: id) {
            XCTAssertEqual($0.pendingClassification, .personal)
            XCTAssertNil($0.pendingBusinessPurpose)
        }
    }

    func testAppendNotesUsesLatestStateAndPersistsBeforeReturn() throws {
        var reducer = recording()
        let id = try XCTUnwrap(reducer.state.pendingTripID)
        for note in ["First", "Second"] {
            try reducer.commitCurrentDriveEdit(.appendNote(note), expectedID: id) { _ in }
        }
        XCTAssertEqual(reducer.state.pendingNote, "First\nSecond")
    }
}
