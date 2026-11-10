import XCTest
@testable import AppCore

@MainActor
final class ManualRouteResolverTests: XCTestCase {
    func testAppleResolverRequiresConfirmedCoordinatesForCalculatedRoute() async {
        let resolver = AppleManualRouteResolver()

        do {
            _ = try await resolver.resolveRoute(
                origin: ManualRouteEndpoint(address: "Springfield"),
                destination: ManualRouteEndpoint(
                    address: "Confirmed destination",
                    coordinate: Coordinate(latitude: 42.1015, longitude: -72.5898)
                )
            )
            XCTFail("Ambiguous free text must not be resolved through a global first result.")
        } catch let error as ManualRouteResolutionError {
            guard case .endpointSelectionRequired = error else {
                return XCTFail("Unexpected route error: \(error)")
            }
        } catch {
            XCTFail("Unexpected route error: \(error)")
        }
    }

    func testAppleResolverStillDistinguishesMissingEndpoint() async {
        let resolver = AppleManualRouteResolver()

        do {
            _ = try await resolver.resolveRoute(
                origin: ManualRouteEndpoint(address: "   "),
                destination: ManualRouteEndpoint(
                    address: "Confirmed destination",
                    coordinate: Coordinate(latitude: 42.1015, longitude: -72.5898)
                )
            )
            XCTFail("A blank endpoint must be rejected.")
        } catch let error as ManualRouteResolutionError {
            guard case .missingEndpoints = error else {
                return XCTFail("Unexpected route error: \(error)")
            }
        } catch {
            XCTFail("Unexpected route error: \(error)")
        }
    }

    func testSelectionRequiredMessagePreservesManualMileageFallback() {
        XCTAssertEqual(
            ManualRouteResolutionError.endpointSelectionRequired.errorDescription,
            "Choose a Maps suggestion for both endpoints before calculating a route. You can still enter mileage manually."
        )
    }
}
