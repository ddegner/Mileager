import AppCore
import MapKit
import SwiftUI

struct RouteMapContent: Equatable {
    var startCoordinate: Coordinate?
    var endCoordinate: Coordinate?
    var routePolyline: String?
    var stopCoordinates: [Coordinate]
    private let isEndpointPreview: Bool

    /// Decoded once at construction. Derived entirely from the stored source
    /// fields, so it is excluded from `Equatable` (see `==` below).
    private let decodedSegments: [[CLLocationCoordinate2D]]

    init?(trip: TripSummary) {
        let routeSummary = trip.routeSummary
        let shouldUseLegRoute = trip.isMerged || trip.legs.count > 1
        let content = RouteMapContent(
            startCoordinate: shouldUseLegRoute ? routeSummary.startCoordinate ?? trip.startCoordinate : trip.startCoordinate,
            endCoordinate: shouldUseLegRoute ? routeSummary.endCoordinate ?? trip.endCoordinate : trip.endCoordinate,
            // The synced trip-level value is authoritative. Falling back to leg
            // geometry would resurrect a route intentionally cleared by another
            // device after an endpoint edit.
            routePolyline: trip.routePolyline,
            stopCoordinates: shouldUseLegRoute ? trip.stops.compactMap(\.coordinate) : []
        )
        guard !content.segments.isEmpty else { return nil }
        self = content
    }

    init(route: ResolvedManualRoute) {
        self.init(
            startCoordinate: route.startCoordinate,
            endCoordinate: route.endCoordinate,
            routePolyline: route.routePolyline,
            stopCoordinates: []
        )
    }

    init?(leg: TripDisplayLeg) {
        let routeSegments = (leg.incomingConnector?.routeSegments ?? []) + leg.leg.routeSegments
        let content = RouteMapContent(
            startCoordinate: leg.startCoordinate,
            endCoordinate: leg.endCoordinate,
            routePolyline: routeSegments.isEmpty ? nil : EncodedPolyline.encodeSegments(routeSegments),
            stopCoordinates: [],
            decodedSegments: routeSegments.isEmpty
                ? nil
                : routeSegments.map { $0.map(CLLocationCoordinate2D.init) }
        )
        guard !content.segments.isEmpty else { return nil }
        self = content
    }

    /// Selected places can be shown before a route exists. Keep these as pins;
    /// connecting them would imply a route that has not been calculated yet.
    init?(origin: Coordinate?, destination: Coordinate?) {
        guard origin != nil || destination != nil else { return nil }
        self.init(
            startCoordinate: origin,
            endCoordinate: destination,
            routePolyline: nil,
            stopCoordinates: [],
            decodedSegments: [],
            isEndpointPreview: true
        )
    }

    private init(
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        routePolyline: String?,
        stopCoordinates: [Coordinate],
        decodedSegments: [[CLLocationCoordinate2D]]? = nil,
        isEndpointPreview: Bool = false
    ) {
        self.isEndpointPreview = isEndpointPreview
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.routePolyline = routePolyline
        self.stopCoordinates = stopCoordinates
        self.decodedSegments = decodedSegments ?? Self.decodeSegments(
            routePolyline: routePolyline,
            startCoordinate: startCoordinate,
            endCoordinate: endCoordinate
        )
    }

    static func == (lhs: RouteMapContent, rhs: RouteMapContent) -> Bool {
        lhs.startCoordinate == rhs.startCoordinate
            && lhs.endCoordinate == rhs.endCoordinate
            && lhs.routePolyline == rhs.routePolyline
            && lhs.stopCoordinates == rhs.stopCoordinates
            && lhs.isEndpointPreview == rhs.isEndpointPreview
    }

    var segments: [[CLLocationCoordinate2D]] {
        decodedSegments
    }

    private static func decodeSegments(
        routePolyline: String?,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?
    ) -> [[CLLocationCoordinate2D]] {
        if let routePolyline,
           let decoded = EncodedPolyline.decodeSegments(routePolyline),
           !decoded.isEmpty {
            return decoded.map { $0.map(CLLocationCoordinate2D.init) }
        }

        guard let startCoordinate, let endCoordinate else { return [] }
        return [[startCoordinate, endCoordinate].map(CLLocationCoordinate2D.init)]
    }

    var coordinates: [CLLocationCoordinate2D] {
        let routeCoordinates = segments.flatMap { $0 }
        let endpoints = [startCoordinate, endCoordinate].compactMap { $0 }.map(CLLocationCoordinate2D.init)
        return (isEndpointPreview ? endpoints : routeCoordinates) + stopMapCoordinates
    }

    var startMapCoordinate: CLLocationCoordinate2D? {
        segments.flatMap { $0 }.first ?? startCoordinate.map(CLLocationCoordinate2D.init)
    }

    var endMapCoordinate: CLLocationCoordinate2D? {
        segments.flatMap { $0 }.last ?? endCoordinate.map(CLLocationCoordinate2D.init)
    }

    var stopMapCoordinates: [CLLocationCoordinate2D] {
        stopCoordinates.map(CLLocationCoordinate2D.init)
    }

    var mapFingerprint: String {
        [
            routePolyline ?? "",
            isEndpointPreview ? "endpoints" : "route",
            Self.coordinateToken(startCoordinate),
            Self.coordinateToken(endCoordinate),
            stopCoordinates.map(Self.coordinateToken).joined(separator: ",")
        ].joined(separator: "|")
    }

    func visibleMapRect(insetRatio: Double = 0.2, minimumInset: Double = 800) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }

        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }

        let insetX = max(rect.width * insetRatio, minimumInset)
        let insetY = max(rect.height * insetRatio, minimumInset)
        return rect.insetBy(dx: -insetX, dy: -insetY)
    }

    private static func coordinateToken(_ coordinate: Coordinate?) -> String {
        guard let coordinate else { return "nil" }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }
}

struct RouteMapPreviewView: View {
    var content: RouteMapContent
    var isFullBleed = false
    var allowsInteraction = true
    var height: CGFloat?
    var showsControls = true
    /// Edge insets the fitted route is confined to. Callers that overlay the
    /// map (the trip-detail hero fade) pass the band their overlays leave free.
    var viewportPadding: UIEdgeInsets = .zero
    var onExpand: (() -> Void)?

    private var coordinates: [CLLocationCoordinate2D] {
        content.coordinates
    }

    var body: some View {
        if coordinates.isEmpty {
            Label("No route map available", systemImage: "map.fill")
                .foregroundStyle(.secondary)
        } else {
            if isFullBleed {
                mapBody
                    .frame(height: resolvedHeight)
            } else {
                mapBody
                    .frame(height: resolvedHeight)
                    .clipShape(RoundedRectangle(cornerRadius: MileageTheme.cardCornerRadius, style: .continuous))
            }
        }
    }

    private var resolvedHeight: CGFloat {
        height ?? (isFullBleed ? 240 : 220)
    }

    private var mapBody: some View {
        ZStack(alignment: .bottomTrailing) {
            InteractiveRouteMapView(
                content: content,
                allowsInteraction: allowsInteraction,
                viewportPadding: allowsInteraction ? .zero : viewportPadding
            )

            if showsControls, let onExpand {
                RouteMapExpandButton(action: onExpand)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(10)
            }
        }
    }
}

struct RouteMapExpandButton: View {
    private static let minimumHitTarget: CGFloat = 44

    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(
            minWidth: Self.minimumHitTarget,
            minHeight: Self.minimumHitTarget
        )
        .contentShape(.circle)
        .accessibilityLabel("Expand map")
        .accessibilityIdentifier("routeMapExpandButton")
    }
}

struct ExpandedRouteMapView: View {
    var content: RouteMapContent

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InteractiveRouteMapView(content: content, allowsInteraction: true)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Route Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                        .accessibilityIdentifier("expandedRouteMapDone")
                    }
                }
        }
    }
}

private struct InteractiveRouteMapView: UIViewRepresentable {
    var content: RouteMapContent
    var allowsInteraction: Bool
    var viewportPadding: UIEdgeInsets = .zero

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isUserInteractionEnabled = allowsInteraction
        mapView.isScrollEnabled = allowsInteraction
        mapView.isZoomEnabled = allowsInteraction
        mapView.isPitchEnabled = allowsInteraction
        mapView.isRotateEnabled = allowsInteraction
        mapView.pointOfInterestFilter = .includingAll
        context.coordinator.routeColor = MileageTheme.routeUIColor
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.isUserInteractionEnabled = allowsInteraction
        mapView.isScrollEnabled = allowsInteraction
        mapView.isZoomEnabled = allowsInteraction
        mapView.isPitchEnabled = allowsInteraction
        mapView.isRotateEnabled = allowsInteraction
        context.coordinator.routeColor = MileageTheme.routeUIColor
        context.coordinator.apply(
            content: content,
            viewportPadding: viewportPadding,
            to: mapView
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var appliedFingerprint: String?
        var appliedViewportPadding: UIEdgeInsets?
        var routeColor = UIColor.systemOrange

        func apply(
            content: RouteMapContent,
            viewportPadding: UIEdgeInsets,
            to mapView: MKMapView
        ) {
            guard appliedFingerprint != content.mapFingerprint
                    || appliedViewportPadding != viewportPadding else { return }
            appliedFingerprint = content.mapFingerprint
            appliedViewportPadding = viewportPadding

            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

            for segment in content.segments where segment.count >= 2 {
                var coordinates = segment
                let polyline = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                mapView.addOverlay(polyline)
            }

            if let startCoordinate = content.startMapCoordinate {
                let annotation = RouteEndpointAnnotation(kind: .origin, coordinate: startCoordinate)
                mapView.addAnnotation(annotation)
            }

            for (index, stopCoordinate) in content.stopMapCoordinates.enumerated() {
                let title = content.stopMapCoordinates.count == 1 ? String(localized: "Stop") : String(localized: "Stop \(index + 1)")
                let annotation = RouteEndpointAnnotation(kind: .stop(title), coordinate: stopCoordinate)
                mapView.addAnnotation(annotation)
            }

            if let endCoordinate = content.endMapCoordinate {
                let annotation = RouteEndpointAnnotation(kind: .destination, coordinate: endCoordinate)
                mapView.addAnnotation(annotation)
            }

            if let visibleMapRect = content.visibleMapRect(
                insetRatio: viewportPadding == .zero ? 0.2 : 0.08,
                minimumInset: viewportPadding == .zero ? 800 : 400
            ) {
                mapView.setVisibleMapRect(
                    visibleMapRect,
                    edgePadding: viewportPadding,
                    animated: false
                )
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = routeColor
                .resolvedColor(with: mapView.traitCollection)
                .withAlphaComponent(0.92)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let endpoint = annotation as? RouteEndpointAnnotation else { return nil }

            let identifier = "RouteEndpointAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.accessibilityIdentifier = endpoint.kind.accessibilityIdentifier
            view.markerTintColor = endpoint.kind.markerTintColor
            view.glyphImage = UIImage(systemName: endpoint.kind.systemImageName)
            view.titleVisibility = .visible
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            return view
        }
    }
}

private final class RouteEndpointAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case origin
        case stop(String)
        case destination

        var title: String {
            switch self {
            case .origin: String(localized: "Origin")
            case let .stop(title): title
            case .destination: String(localized: "Destination")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .origin: "routeEndpoint-origin"
            case .destination: "routeEndpoint-destination"
            case .stop: "routeEndpoint-stop"
            }
        }

        var markerTintColor: UIColor {
            switch self {
            case .origin: .systemGreen
            case .stop: .systemOrange
            case .destination: .systemRed
            }
        }

        var systemImageName: String {
            switch self {
            case .origin: "location.circle"
            case .stop: "pause.fill"
            case .destination: "flag.checkered"
            }
        }
    }

    let kind: Kind
    let coordinate: CLLocationCoordinate2D

    var title: String? {
        kind.title
    }

    init(kind: Kind, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.coordinate = coordinate
    }
}
