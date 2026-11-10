import AppCore
import Foundation
import XCTest
@testable import MileageTracker

/// Model-level integration: the My Card home address (stored in preferences)
/// must reach the suggestion request as "the user's home address" — no
/// contacts permission needed. The pure ContactAddressIndex matching tests
/// live in the package's ContactSuggestionEvidenceTests.
@MainActor
final class SuggestionUserHomeAnnotationTests: XCTestCase {
    func testUserHomeFromPreferencesAnnotatesRequest() async throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.userHomeStreetLine = "111 Example St"
        preferences.userHomeCity = "Brooklyn"
        let provider = RequestRecordingProvider()
        let model = MileageAppModel(previewMode: true, preferences: preferences, suggestionProvider: provider)

        let created = try XCTUnwrap(model.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "111 Example St, Brooklyn",
            destination: "350 5th Ave, New York",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        _ = try model.tripStore.updateAddresses(
            tripID: created.id,
            startAddress: "111 Example St, Brooklyn",
            endAddress: "350 5th Ave, New York",
            startAddressComponents: TripEndpointAddressComponents(streetNumber: "111", streetName: "Example St", city: "Brooklyn"),
            endAddressComponents: TripEndpointAddressComponents(streetNumber: "350", streetName: "5th Ave", city: "New York")
        )
        model.refresh()
        await model.suggestionBackfillTask?.value

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.originContactNote, "the user's home address")
        XCTAssertNil(request.destinationContactNote)
        XCTAssertTrue(request.contactEvidenceEnabled)
    }
}

@MainActor
private final class RequestRecordingProvider: TripSuggestionProviding {
    var isAvailable: Bool { true }
    private(set) var requests: [TripSuggestionRequest] = []

    func prewarm() {}

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        requests.append(request)
        return nil
    }
}
