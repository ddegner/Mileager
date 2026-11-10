import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import CoreLocation
import Foundation
#if canImport(MapKit)
import MapKit
#endif

/// A reverse-geocoding operation used by automatic trip enrichment.
///
/// Failures are intentionally thrown. Callers need to distinguish a transient
/// Maps/network failure from a successful lookup so incomplete trips can be
/// retried on a later foreground session.
public protocol EndpointGeocoding: Sendable {
    func endpoint(for coordinate: Coordinate) async throws -> EndpointGeocoder.ResolvedEndpoint
}

public enum EndpointGeocodingError: Error, Equatable, Sendable {
    case invalidCoordinate
    case noResult
    case noDisplayableAddress
    case mapKitUnavailable
}

public struct EndpointGeocoder: EndpointGeocoding, Sendable {
    public init() {}

    public struct ResolvedEndpoint: Equatable, Sendable {
        public var label: String
        public var components: TripEndpointAddressComponents?
        /// Structured MapKit evidence that the resolved coordinate lies on
        /// ocean or inland water. This deliberately avoids localized label
        /// parsing so automatic trip decisions remain locale-independent.
        public var isWater: Bool

        public init(
            label: String,
            components: TripEndpointAddressComponents?,
            isWater: Bool = false
        ) {
            self.label = label
            self.components = components
            self.isWater = isWater
        }
    }

    public func endpoint(for coordinate: Coordinate) async throws -> ResolvedEndpoint {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90.0 ... 90.0).contains(coordinate.latitude),
              (-180.0 ... 180.0).contains(coordinate.longitude) else {
            throw EndpointGeocodingError.invalidCoordinate
        }

        #if canImport(MapKit)
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw EndpointGeocodingError.invalidCoordinate
        }

        let requestHandle = ReverseGeocodingRequestHandle(request)
        let mapItems = try await withTaskCancellationHandler {
            try await requestHandle.mapItems()
        } onCancel: {
            requestHandle.cancel()
        }
        guard let mapItem = mapItems.first else {
            throw EndpointGeocodingError.noResult
        }

        let label = [
            mapItem.name,
            mapItem.address?.shortAddress,
            mapItem.address?.fullAddress
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .uniquedPreservingOrder()
        .joined(separator: ", ")
        guard !label.isEmpty else {
            throw EndpointGeocodingError.noDisplayableAddress
        }
        return ResolvedEndpoint(
            label: label,
            components: Self.addressComponents(from: mapItem),
            isWater: Self.isWater(mapItem)
        )
        #else
        throw EndpointGeocodingError.mapKitUnavailable
        #endif
    }

    #if canImport(MapKit)
    /// MapKit's iOS 26 address replacement does not expose the placemark's
    /// ocean/inland-water fields yet. Keep this compatibility read isolated so
    /// it has one replacement point when MapKit gains a structured successor.
    /// The decision itself lives in `WaterTripClassifier.isWaterSurface` so it
    /// can be unit-tested without a map item: a bridge's mid-span point
    /// reports the river beneath it AND the bridge as its thoroughfare.
    private static func isWater(_ mapItem: MKMapItem) -> Bool {
        let placemark = mapItem.placemark
        return WaterTripClassifier.isWaterSurface(
            ocean: placemark.ocean,
            inlandWater: placemark.inlandWater,
            thoroughfare: placemark.thoroughfare
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func addressComponents(from mapItem: MKMapItem) -> TripEndpointAddressComponents? {
        let representations = mapItem.addressRepresentations
        let formattedAddress = representations?
            .fullAddress(includingRegion: false, singleLine: true)
            ?? mapItem.address?.fullAddress
        let parts = formattedAddress.map(AddressDisplayFormatter.parts(of:))
        let street = splitStreetLine(parts?.primary)
        let components = TripEndpointAddressComponents(
            streetNumber: street.number,
            streetName: street.name,
            city: representations?.cityName ?? parts?.city,
            state: parts?.stateCode,
            country: representations?.regionName
        )
        return components.hasDisplayableComponent ? components : nil
    }

    private static func splitStreetLine(_ value: String?) -> (number: String?, name: String?) {
        guard let value else { return (nil, nil) }
        let pieces = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              pieces[0].range(
                of: #"^\d+[A-Za-z]?(?:-\d+[A-Za-z]?)?$"#,
                options: .regularExpression
              ) != nil else {
            return (nil, value)
        }
        return (pieces[0], pieces[1])
    }
    #endif
}

#if canImport(MapKit)
private final class ReverseGeocodingRequestHandle: @unchecked Sendable {
    private let request: MKReverseGeocodingRequest

    init(_ request: MKReverseGeocodingRequest) {
        self.request = request
    }

    func mapItems() async throws -> [MKMapItem] {
        try await request.mapItems
    }

    func cancel() {
        request.cancel()
    }
}
#endif

private extension Array where Element == String {
    func uniquedPreservingOrder() -> [String] {
        reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }
}
