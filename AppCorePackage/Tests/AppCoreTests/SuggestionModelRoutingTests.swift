import FoundationModels
import XCTest
@testable import AppCoreSuggestions

@MainActor
final class SuggestionModelRoutingTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testSettingsRemainAvailableWhileModelLoadsOrIntelligenceIsOff() {
        XCTAssertTrue(FoundationModelsSuggestionProvider.supportsConfiguration(availability: .available))
        XCTAssertTrue(FoundationModelsSuggestionProvider.supportsConfiguration(availability: .unavailable(.modelNotReady)))
        XCTAssertTrue(FoundationModelsSuggestionProvider.supportsConfiguration(availability: .unavailable(.appleIntelligenceNotEnabled)))
        XCTAssertFalse(FoundationModelsSuggestionProvider.supportsConfiguration(availability: .unavailable(.deviceNotEligible)))
    }

    func testPCCIsFirstWhenBothModelsAreReady() {
        XCTAssertEqual(routes(), [.privateCloudCompute, .onDevice])
    }

    func testPCCDoesNotDependOnLocalModelReadiness() {
        XCTAssertEqual(routes(localAvailable: false), [.privateCloudCompute])
    }

    func testUnsignedHostNeverAttemptsCloudEvenIfAppleReportsAvailable() {
        XCTAssertEqual(routes(cloudAuthorized: false), [.onDevice])
        XCTAssertEqual(routes(cloudAuthorized: false, localAvailable: false), [])
    }

    func testOptOutNeverUsesCloud() {
        XCTAssertEqual(routes(preferCloud: false), [.onDevice])
        XCTAssertEqual(routes(preferCloud: false, localAvailable: false), [])
    }

    func testCloudUnavailableOrQuotaExhaustedUsesLocal() {
        XCTAssertEqual(routes(cloudAvailable: false), [.onDevice])
        XCTAssertEqual(routes(cloudQuotaReached: true), [.onDevice])
        XCTAssertEqual(routes(cloudQuotaReached: true, localAvailable: false), [])
    }

    func testSuccessfulPCCDoesNotRunLocalAndRecordsActualRoute() async throws {
        var calls: [SuggestionModelRoute] = []
        var diagnostics: [String] = []
        let result = try await SuggestionModelRouting.generate(routes: routes(), record: { diagnostics.append($0) }) { route in
            calls.append(route)
            return "cloud result"
        }
        XCTAssertEqual(result, "cloud result")
        XCTAssertEqual(calls, [.privateCloudCompute])
        XCTAssertEqual(diagnostics, ["Suggestion generated using Private Cloud Compute."])
    }

    func testCloudFailureFallsBackOnceAndRecordsActualRoute() async throws {
        var calls: [SuggestionModelRoute] = []
        var diagnostics: [String] = []
        let result = try await SuggestionModelRouting.generate(routes: routes(), record: { diagnostics.append($0) }) { route in
            calls.append(route)
            if route == .privateCloudCompute { throw Failure.unavailable }
            return "local result"
        }
        XCTAssertEqual(result, "local result")
        XCTAssertEqual(calls, [.privateCloudCompute, .onDevice])
        XCTAssertEqual(diagnostics.last, "Suggestion generated using on-device.")
    }

    func testCancellationDoesNotStartFallback() async {
        var calls: [SuggestionModelRoute] = []
        do {
            let _: String? = try await SuggestionModelRouting.generate(routes: routes(), record: { _ in }) { route in
                calls.append(route)
                throw CancellationError()
            }
            XCTFail("Cancellation must escape the route runner")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(calls, [.privateCloudCompute])
    }

    func testResponseReturnedAfterCancellationIsDiscarded() async {
        let task = Task { @MainActor in
            try await SuggestionModelRouting.generate(routes: self.routes(), record: { _ in XCTFail("No success after cancellation") }) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "late result"
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled generation must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBothModelsFailWithoutLooping() async {
        var calls: [SuggestionModelRoute] = []
        do {
            let _: String? = try await SuggestionModelRouting.generate(routes: routes(), record: { _ in }) { route in
                calls.append(route)
                throw Failure.unavailable
            }
            XCTFail("Final failure must escape")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(calls, [.privateCloudCompute, .onDevice])
    }

    private func routes(
        preferCloud: Bool = true,
        cloudAvailable: Bool = true,
        cloudAuthorized: Bool = true,
        cloudQuotaReached: Bool = false,
        localAvailable: Bool = true
    ) -> [SuggestionModelRoute] {
        SuggestionModelRouting.routes(preferCloud: preferCloud, cloudAvailable: cloudAvailable, cloudAuthorized: cloudAuthorized,
                                     cloudQuotaReached: cloudQuotaReached, localAvailable: localAvailable)
    }
}
