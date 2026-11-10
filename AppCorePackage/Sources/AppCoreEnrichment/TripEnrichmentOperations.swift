import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import Foundation
#if canImport(MapKit)
import MapKit
#endif

/// Error raised by the workflow timeout wrapper. It is intentionally free of
/// request details so it is safe to persist in enrichment-attempt metadata.
public enum TripEnrichmentOperationError: Error, Equatable, Sendable {
    case timedOut
}

public enum TripEnrichmentFailureClassifier {
    public static func category(for error: any Error) -> TripEnrichmentFailureCategory {
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? TripEnrichmentOperationError, error == .timedOut {
            return .timedOut
        }
        if let error = error as? EndpointGeocodingError {
            switch error {
            case .invalidCoordinate, .noDisplayableAddress:
                return .invalidInput
            case .noResult, .mapKitUnavailable:
                return .serviceUnavailable
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .internationalRoamingOff,
                 .dataNotAllowed:
                return .networkUnavailable
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            default:
                return .serviceUnavailable
            }
        }

        #if canImport(MapKit)
        if nsError.domain == MKError.errorDomain {
            switch MKError.Code(rawValue: UInt(nsError.code)) {
            case .loadingThrottled:
                return .rateLimited
            case .serverFailure:
                return .serviceUnavailable
            case .placemarkNotFound, .directionsNotFound, .decodingFailed:
                return .invalidInput
            case .unknown, .none:
                return .unknown
            @unknown default:
                return .unknown
            }
        }
        #endif

        return .unknown
    }

    public static func isTerminal(_ category: TripEnrichmentFailureCategory) -> Bool {
        switch category {
        case .invalidInput, .missingSamples:
            true
        case .networkUnavailable,
             .timedOut,
             .serviceUnavailable,
             .rateLimited,
             .cancelled,
             .unknown:
            false
        }
    }
}

@MainActor
func withTripEnrichmentTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    guard seconds > 0 else {
        throw TripEnrichmentOperationError.timedOut
    }

    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TripEnrichmentOperationError.timedOut
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}
