import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import CoreLocation
import Foundation
import MapKit

public struct ResolvedManualRoute: Equatable, Sendable {
    public var startCoordinate: Coordinate
    public var endCoordinate: Coordinate
    public var routePolyline: String?
    public var distanceMeters: Double?

    public init(
        startCoordinate: Coordinate,
        endCoordinate: Coordinate,
        routePolyline: String? = nil,
        distanceMeters: Double? = nil
    ) {
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.routePolyline = routePolyline
        self.distanceMeters = distanceMeters
    }

}

public struct ManualRouteEndpoint: Equatable, Sendable {
    public var address: String
    public var coordinate: Coordinate?

    public init(address: String, coordinate: Coordinate? = nil) {
        self.address = address
        self.coordinate = coordinate
    }
}

public enum ManualRouteResolutionError: Error, LocalizedError {
    case missingEndpoints
    case endpointSelectionRequired
    case endpointNotFound

    public var errorDescription: String? {
        switch self {
        case .missingEndpoints:
            String(localized: "Enter both origin and destination.", bundle: .appCoreStrings)
        case .endpointSelectionRequired:
            String(
                localized: "Choose a Maps suggestion for both endpoints before calculating a route. You can still enter mileage manually.",
                bundle: .appCoreStrings
            )
        case .endpointNotFound:
            String(
                localized: "Could not find that route. Enter mileage manually.",
                bundle: .appCoreStrings
            )
        }
    }
}

@MainActor
public protocol ManualRouteResolving: DrivingRouteResolving {
    func resolveRoute(origin: ManualRouteEndpoint, destination: ManualRouteEndpoint) async throws -> ResolvedManualRoute
}

public struct AppleManualRouteResolver: ManualRouteResolving {
    public init() {}

    public func resolveRoute(origin: ManualRouteEndpoint, destination: ManualRouteEndpoint) async throws -> ResolvedManualRoute {
        let startCoordinate = try await coordinate(for: origin)
        let endCoordinate = try await coordinate(for: destination)

        do {
            let route = try await resolveDrivingRoute(
                start: Coordinate(startCoordinate),
                end: Coordinate(endCoordinate)
            )
            return ResolvedManualRoute(
                startCoordinate: route.startCoordinate,
                endCoordinate: route.endCoordinate,
                routePolyline: route.routePolyline,
                distanceMeters: route.distanceMeters
            )
        } catch {
            return ResolvedManualRoute(
                startCoordinate: Coordinate(startCoordinate),
                endCoordinate: Coordinate(endCoordinate)
            )
        }
    }

    private func coordinate(for endpoint: ManualRouteEndpoint) async throws -> CLLocationCoordinate2D {
        if let coordinate = endpoint.coordinate {
            return CLLocationCoordinate2D(coordinate)
        }

        let trimmedAddress = endpoint.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            throw ManualRouteResolutionError.missingEndpoints
        }

        // A global first-result lookup can silently resolve an ambiguous place
        // name to the wrong city. The UI's autocomplete supplies a confirmed
        // coordinate; free text remains valid when mileage is entered manually.
        throw ManualRouteResolutionError.endpointSelectionRequired
    }

    public func resolveDrivingRoute(start: Coordinate, end: Coordinate) async throws -> ResolvedDrivingRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
        request.transportType = .automobile

        let directions = DirectionsRequestHandle(MKDirections(request: request))
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: {
            directions.cancel()
        }
        guard let route = response.routes.first else {
            throw ManualRouteResolutionError.endpointNotFound
        }
        let routeCoordinates = route.polyline.coordinates
        guard routeCoordinates.count >= 2 else {
            throw ManualRouteResolutionError.endpointNotFound
        }
        return ResolvedDrivingRoute(
            startCoordinate: start,
            endCoordinate: end,
            routePolyline: EncodedPolyline.encode(routeCoordinates.map(Coordinate.init)),
            distanceMeters: route.distance
        )
    }

}

private final class DirectionsRequestHandle: @unchecked Sendable {
    private let directions: MKDirections

    init(_ directions: MKDirections) {
        self.directions = directions
    }

    func calculate() async throws -> MKDirections.Response {
        try await directions.calculate()
    }

    func cancel() {
        directions.cancel()
    }
}

public struct UITestManualRouteResolver: ManualRouteResolving {
    /// Known fixture endpoints let UI tests use free text without consulting
    /// MapKit, while preserving the geography the user entered.
    private static let fixtureCoordinates: [(query: String, coordinate: Coordinate)] = [
        ("Boston Common", Coordinate(latitude: 42.3550, longitude: -71.0656)),
        ("Fenway Park", Coordinate(latitude: 42.3467, longitude: -71.0972)),
        ("World Trade Center", Coordinate(latitude: 40.7127, longitude: -74.0134)),
        ("Grand Central Terminal", Coordinate(latitude: 40.7527, longitude: -73.9772))
    ]

    public init() {}

    public func resolveRoute(origin: ManualRouteEndpoint, destination: ManualRouteEndpoint) async throws -> ResolvedManualRoute {
        let start = try Self.coordinate(for: origin)
        let end = try Self.coordinate(for: destination)
        return Self.resolvedRoute(start: start, end: end)
    }

    public func resolveDrivingRoute(start: Coordinate, end: Coordinate) async throws -> ResolvedDrivingRoute {
        let route = Self.resolvedRoute(start: start, end: end)
        return ResolvedDrivingRoute(
            startCoordinate: route.startCoordinate,
            endCoordinate: route.endCoordinate,
            routePolyline: route.routePolyline,
            distanceMeters: route.distanceMeters ?? 0
        )
    }

    private static func coordinate(for endpoint: ManualRouteEndpoint) throws -> Coordinate {
        if let coordinate = endpoint.coordinate {
            return coordinate
        }

        let address = endpoint.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw ManualRouteResolutionError.missingEndpoints
        }
        if let fixture = fixtureCoordinates.first(where: {
            address.localizedCaseInsensitiveContains($0.query)
        }) {
            return fixture.coordinate
        }
        throw ManualRouteResolutionError.endpointNotFound
    }

    private static func resolvedRoute(start: Coordinate, end: Coordinate) -> ResolvedManualRoute {
        let midpoint = Coordinate(
            latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2
        )
        return ResolvedManualRoute(
            startCoordinate: start,
            endCoordinate: end,
            routePolyline: EncodedPolyline.encode([start, midpoint, end]),
            distanceMeters: DistanceCalculator.distanceMeters(from: start, to: end)
        )
    }
}

public extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

public extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
