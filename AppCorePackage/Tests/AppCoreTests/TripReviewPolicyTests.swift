import XCTest
@testable import AppCore

final class TripReviewPolicyTests: XCTestCase {
    func testBusinessTripRequiresPurposeBeforeItIsResolvedOrExportable() {
        XCTAssertEqual(
            TripReviewPolicy.normalizedStatus(
                classification: .business,
                businessPurpose: "  ",
                hasActionableAttention: false,
                requestedStatus: .readyToExport
            ),
            .needsReview
        )
        XCTAssertTrue(TripReviewPolicy.isUnresolved(
            classification: .business,
            businessPurpose: nil
        ))
        XCTAssertFalse(TripReviewPolicy.isExportableBusiness(
            classification: .business,
            businessPurpose: nil
        ))
    }

    func testCompleteBusinessTripIsExportable() {
        XCTAssertEqual(
            TripReviewPolicy.normalizedStatus(
                classification: .business,
                businessPurpose: " Client visit ",
                hasActionableAttention: false
            ),
            .readyToExport
        )
        XCTAssertTrue(TripReviewPolicy.isExportableBusiness(
            classification: .business,
            businessPurpose: "Client visit"
        ))
    }

    func testPersonalAndNotADriveResolveWithoutBusinessPurpose() {
        XCTAssertEqual(
            TripReviewPolicy.normalizedStatus(
                classification: .personal,
                businessPurpose: nil,
                hasActionableAttention: false
            ),
            .readyToExport
        )
        XCTAssertEqual(
            TripReviewPolicy.normalizedStatus(
                classification: .notADrive,
                businessPurpose: nil,
                hasActionableAttention: true,
                requestedStatus: .needsAttention
            ),
            .readyToExport
        )
    }

    /// An engine attention flag is a note about how the capture went, raised by
    /// the engine about itself. It is not work for the user, so it must not put
    /// a classified drive back in the review queue.
    func testEngineAttentionDoesNotMakeAClassifiedTripUnresolved() {
        for classification in [TripClassification.business, .personal, .notADrive] {
            XCTAssertFalse(
                TripReviewPolicy.isUnresolved(
                    classification: classification,
                    businessPurpose: classification == .business ? "Client visit" : nil
                ),
                "\(classification) with an engine flag must stay resolved"
            )
        }
        XCTAssertTrue(TripReviewPolicy.isUnresolved(
            classification: nil,
            businessPurpose: nil
        ))
    }

    /// The flag never withholds mileage. Silently under-claiming is worse than
    /// a number the user can inspect — the drive carries the distance it was
    /// captured with either way.
    func testEngineAttentionDoesNotWithholdMileageFromReports() {
        XCTAssertTrue(TripReviewPolicy.isExportableBusiness(
            classification: .business,
            businessPurpose: "Client visit"
        ))
        XCTAssertFalse(TripReviewPolicy.isExportableBusiness(
            classification: .personal,
            businessPurpose: "Client visit"
        ))
    }
}
