import AppCore
import XCTest
@testable import MileageTracker

@MainActor
final class CloudSuggestionOptInTests: XCTestCase {
    func testCloudOptInPersistsAndUpdatesProviderWithoutEnablingSync() throws {
        let suite = "CloudSuggestionOptInTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let provider = FoundationModelsSuggestionProvider(record: { _ in })
        let model = MileageAppModel(previewMode: true,
                                    arguments: ["MileageTracker", "--uitesting"],
                                    preferences: preferences, suggestionProvider: provider)
        XCTAssertFalse(model.privateCloudComputeSuggestionsEnabled)
        XCTAssertFalse(provider.preferPrivateCloudCompute)
        model.privateCloudComputeSuggestionsEnabled = true
        XCTAssertTrue(preferences.privateCloudComputeSuggestionsEnabled)
        XCTAssertTrue(provider.preferPrivateCloudCompute)
        XCTAssertFalse(model.syncEnabled)
        model.privateCloudComputeSuggestionsEnabled = false
        XCTAssertFalse(preferences.privateCloudComputeSuggestionsEnabled)
        XCTAssertFalse(provider.preferPrivateCloudCompute)
    }
}
