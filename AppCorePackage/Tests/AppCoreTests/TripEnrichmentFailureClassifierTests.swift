import Foundation
import MapKit
import XCTest
@testable import AppCore

final class TripEnrichmentFailureClassifierTests: XCTestCase {
    func testNoReverseGeocodingResultRemainsRetryable() {
        XCTAssertEqual(
            TripEnrichmentFailureClassifier.category(for: EndpointGeocodingError.noResult),
            .serviceUnavailable
        )
    }

    func testOfflineURLErrorIsClassifiedWithoutPersistingRawErrorText() {
        XCTAssertEqual(
            TripEnrichmentFailureClassifier.category(for: URLError(.notConnectedToInternet)),
            .networkUnavailable
        )
    }

    func testMapKitThrottlingIsRetryable() {
        let error = NSError(
            domain: MKError.errorDomain,
            code: Int(MKError.Code.loadingThrottled.rawValue)
        )
        XCTAssertEqual(
            TripEnrichmentFailureClassifier.category(for: error),
            .rateLimited
        )
    }

    func testMapKitDirectionsNotFoundIsTerminalInvalidInput() {
        let error = NSError(
            domain: MKError.errorDomain,
            code: Int(MKError.Code.directionsNotFound.rawValue)
        )
        let category = TripEnrichmentFailureClassifier.category(for: error)
        XCTAssertEqual(category, .invalidInput)
        XCTAssertTrue(TripEnrichmentFailureClassifier.isTerminal(category))
    }
}
