import AppCore
import MapKit
import SwiftUI
import UIKit

struct DriveCardMapThumbnail: View {
    private struct RenderTaskID: Equatable {
        var key: String?
        var isActive: Bool
    }

    private enum Source {
        case trip(TripSummary)
        case content(RouteMapContent, identityToken: String)
    }

    private var source: Source
    var presentation: DriveCardMapPresentation
    var routeColor: UIColor
    var minimumPointSize: CGSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var imageKey: String?
    @State private var activeKey: String?

    static func hasMapContent(for trip: TripSummary) -> Bool {
        DriveCardMapSnapshotRenderer.hasMapContent(for: trip)
    }

    /// Set by callers that already pin an exact frame, so the thumbnail can
    /// skip measuring itself. A `GeometryReader` forces eager layout, and this
    /// view now renders once per row inside a lazy `List` — measuring every
    /// visible row to discover a size the caller already knew is pure overhead.
    var usesProposedSize = true

    init(
        trip: TripSummary,
        routeColor: UIColor,
        minimumPointSize: CGSize,
        usesProposedSize: Bool = true
    ) {
        source = .trip(trip)
        presentation = .thumbnail
        self.routeColor = routeColor
        self.minimumPointSize = minimumPointSize
        self.usesProposedSize = usesProposedSize
    }

    init(
        content: RouteMapContent,
        identityToken: String,
        routeColor: UIColor,
        minimumPointSize: CGSize,
        usesProposedSize: Bool = true,
        presentation: DriveCardMapPresentation = .thumbnail
    ) {
        source = .content(content, identityToken: identityToken)
        self.presentation = presentation
        self.routeColor = routeColor
        self.minimumPointSize = minimumPointSize
        self.usesProposedSize = usesProposedSize
    }

    var body: some View {
        if usesProposedSize {
            GeometryReader { proxy in
                thumbnail(pointSize: resolvedPointSize(for: proxy.size))
            }
            .frame(minWidth: minimumPointSize.width, minHeight: minimumPointSize.height)
        } else {
            thumbnail(pointSize: minimumPointSize)
        }
    }

    private func resolvedPointSize(for proposedSize: CGSize) -> CGSize {
        CGSize(
            width: resolvedDimension(proposedSize.width, fallback: minimumPointSize.width),
            height: resolvedDimension(proposedSize.height, fallback: minimumPointSize.height)
        )
    }

    private func resolvedDimension(_ proposed: CGFloat, fallback: CGFloat) -> CGFloat {
        guard proposed.isFinite, proposed > 1 else { return fallback }
        return proposed
    }

    @ViewBuilder
    private func thumbnail(pointSize: CGSize) -> some View {
        let request = snapshotRequest(source: source, pointSize: pointSize)
        let cachedImage = request.flatMap { DriveCardMapSnapshotRenderer.cachedImage(for: $0.key) }
        // Never carry an image across keys. A route edit changes the exact key,
        // so keeping the old trip-ID-matched thumbnail here would briefly show
        // geometry that is no longer authoritative.
        let displayImage = imageKey == request?.key ? image ?? cachedImage : cachedImage

        ZStack {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: pointSize.width, height: pointSize.height)
                    .clipped()
                    .accessibilityLabel("Route Map")
                    .accessibilityIdentifier("routeMapSnapshot")
            } else {
                // The image is rectangular and each caller supplies the final
                // clip shape. Keep the loading fill rectangular too, so a
                // thumbnail does not look rounder before its map arrives.
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .frame(width: pointSize.width, height: pointSize.height)
        .clipped()
        .task(id: RenderTaskID(key: request?.key, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await render(request)
        }
    }

    private func snapshotRequest(source: Source, pointSize: CGSize) -> DriveCardMapSnapshotRequest? {
        switch source {
        case let .trip(trip):
            DriveCardMapSnapshotRenderer.request(
                for: trip,
                pointSize: pointSize,
                displayScale: displayScale,
                colorScheme: colorScheme
            )
        case let .content(content, identityToken):
            DriveCardMapSnapshotRenderer.request(
                for: content,
                identityToken: identityToken,
                pointSize: pointSize,
                displayScale: displayScale,
                colorScheme: colorScheme,
                presentation: presentation
            )
        }
    }

    @MainActor
    private func render(_ request: DriveCardMapSnapshotRequest?) async {
        guard !Task.isCancelled else { return }
        activeKey = request?.key

        guard let request else {
            image = nil
            imageKey = nil
            return
        }

        if let cached = await DriveCardMapSnapshotRenderer.cachedImage(for: request) {
            guard !Task.isCancelled, activeKey == request.key else { return }
            image = cached.image
            imageKey = request.key
            #if DEBUG
            if request.presentation == .hero, DriveMapWarmingDiagnostics.enabled {
                DriveMapWarmingDiagnostics.shared.heroHits += 1
            }
            #endif
            if cached.freshness == .fresh { return }
        }

        // A transient MapKit failure must not leave a newly merged route blank
        // for the lifetime of the view. Retry briefly, and start a fresh task
        // when the app returns to the foreground. Cancellation never retries.
        for attempt in 0..<3 {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: .seconds(attempt))
                }
                try Task.checkCancellation()
                let renderedImage = try await DriveCardMapSnapshotRenderer.render(
                    request: request,
                    routeColor: routeColor
                )
                guard !Task.isCancelled, activeKey == request.key else { return }
                image = renderedImage
                imageKey = request.key
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, activeKey == request.key else { return }
                // Preserve an exact stale image while revalidation retries.
                if imageKey != request.key {
                    image = nil
                    imageKey = request.key
                }
            }
        }
    }
}

enum DriveCardMapPresentation: String, Sendable {
    case thumbnail
    case detail
    case hero
}

enum DriveMapPrefetchPolicy {
    static let limit = 3

    static func neighbors(of id: UUID, in order: [UUID]) -> [UUID] {
        guard let index = order.firstIndex(of: id) else { return [] }
        return [1, -1, 2].compactMap { offset in
            let neighbor = index + offset
            return order.indices.contains(neighbor) ? order[neighbor] : nil
        }
    }
}

struct DriveCardMapSnapshotRequest: Equatable, @unchecked Sendable {
    var presentation: DriveCardMapPresentation
    var rendererVersion: Int
    var key: String
    var source: RouteMapContent
    var pointSize: CGSize
    var pixelWidth: Int
    var pixelHeight: Int
    var displayScale: CGFloat
    var userInterfaceStyle: UIUserInterfaceStyle
}

enum DriveCardMapSnapshotRenderer {
    static let rendererVersion = 2
    private static let cachePipeline = DriveCardMapThumbnailPipeline()
    private static let singleCoordinateSpanMeters: CLLocationDistance = 1_200
    private static let routeInsetFraction: Double = 0.18
    private static let minimumInsetMeters: CLLocationDistance = 400

    static func hasMapContent(for trip: TripSummary) -> Bool {
        RouteMapContent(trip: trip) != nil
    }

    static func hasMapContent(for content: RouteMapContent) -> Bool {
        !content.coordinates.isEmpty
    }

    static func request(
        for trip: TripSummary,
        pointSize: CGSize,
        displayScale: CGFloat,
        colorScheme: ColorScheme
    ) -> DriveCardMapSnapshotRequest? {
        guard let source = RouteMapContent(trip: trip) else { return nil }
        return request(
            for: source,
            identityComponent: "trip=\(trip.id.uuidString)",
            pointSize: pointSize,
            displayScale: displayScale,
            colorScheme: colorScheme
        )
    }

    static func request(
        for content: RouteMapContent,
        identityToken: String,
        pointSize: CGSize,
        displayScale: CGFloat,
        colorScheme: ColorScheme,
        presentation: DriveCardMapPresentation = .thumbnail
    ) -> DriveCardMapSnapshotRequest? {
        request(
            for: content,
            identityComponent: "identity=\(DriveCardMapCacheKey.digest(identityToken))",
            pointSize: pointSize,
            displayScale: displayScale,
            colorScheme: colorScheme,
            presentation: presentation
        )
    }

    private static func request(
        for source: RouteMapContent,
        identityComponent: String,
        pointSize: CGSize,
        displayScale: CGFloat,
        colorScheme: ColorScheme,
        presentation: DriveCardMapPresentation = .thumbnail
    ) -> DriveCardMapSnapshotRequest? {
        guard pointSize.width.isFinite,
              pointSize.height.isFinite,
              displayScale.isFinite,
              pointSize.width > 1,
              pointSize.height > 1,
              displayScale > 0,
              hasMapContent(for: source) else {
            return nil
        }

        let pixelWidth = Int((pointSize.width * displayScale).rounded())
        let pixelHeight = Int((pointSize.height * displayScale).rounded())
        guard pixelWidth > 1, pixelHeight > 1 else { return nil }

        let pointSize = CGSize(
            width: CGFloat(pixelWidth) / displayScale,
            height: CGFloat(pixelHeight) / displayScale
        )
        let style = UIUserInterfaceStyle(colorScheme: colorScheme)
        let scaleToken = String(Double(displayScale).bitPattern, radix: 16)
        var key = [
            "renderer-v\(rendererVersion)",
            identityComponent,
            "route=\(DriveCardMapCacheKey.digest(source.mapFingerprint))",
            "pixels=\(pixelWidth)x\(pixelHeight)",
            "scale=\(scaleToken)",
            "style=\(style.cacheToken)",
        ].joined(separator: "|")

        if presentation == .detail { key += "|detail-v2" }
        if presentation == .hero { key += "|hero-v1" }

        return DriveCardMapSnapshotRequest(
            presentation: presentation,
            rendererVersion: rendererVersion,
            key: key,
            source: source,
            pointSize: pointSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayScale: displayScale,
            userInterfaceStyle: style
        )
    }

    static func cachedImage(for key: String) -> UIImage? {
        cachePipeline.memoryImage(forKey: key)
    }

    static func cachedImage(for request: DriveCardMapSnapshotRequest) async -> DriveCardMapCachedImage? {
        await cachePipeline.cachedImage(forKey: request.key, displayScale: request.displayScale)
    }

    static func prepareCachedImage(for request: DriveCardMapSnapshotRequest) async -> DriveCardMapCachedImage? {
        await cachePipeline.prepareCachedImage(forKey: request.key, displayScale: request.displayScale)
    }

    static func clearCache() async {
        await cachePipeline.removeAll()
    }

    static func render(
        request: DriveCardMapSnapshotRequest,
        routeColor: UIColor,
        priority: DriveCardMapWorkPriority = .visible
    ) async throws -> UIImage {
        let input = DriveCardMapRenderInput(request: request, routeColor: routeColor)
        return try await cachePipeline.revalidatedImage(
            forKey: request.key,
            displayScale: request.displayScale,
            priority: priority
        ) {
            try await renderSnapshot(input)
        }
    }

    static func warm(request: DriveCardMapSnapshotRequest, protecting keys: Set<String>) async throws -> Bool {
        let input = DriveCardMapRenderInput(request: request, routeColor: MileageTheme.routeUIColor)
        return try await cachePipeline.warm(forKey: request.key, protecting: keys) {
            try await renderSnapshot(input)
        }
    }

    private static func renderSnapshot(
        _ input: DriveCardMapRenderInput
    ) async throws -> DriveCardMapRenderedImage {
        let request = input.request
        #if DEBUG
        if request.presentation == .hero {
            await MainActor.run {
                if DriveMapWarmingDiagnostics.enabled { DriveMapWarmingDiagnostics.shared.heroRenders += 1 }
            }
        }
        #endif
        let source = request.source
        guard !source.coordinates.isEmpty else {
            return DriveCardMapRenderedImage(image: UIImage())
        }

        let traitCollection = await traitCollection(for: request)
        let options = MKMapSnapshotter.Options()
        options.size = request.pointSize
        let viewportPadding = request.presentation == .hero
            ? TripHeroMapLayout.viewportPadding
            : UIEdgeInsets(top: 50, left: 24, bottom: 44, right: 24)
        if request.presentation != .thumbnail,
           let rect = detailMapRect(for: source, size: request.pointSize, padding: viewportPadding) {
            options.mapRect = rect
        } else {
            options.region = region(for: source.coordinates)
        }
        options.traitCollection = traitCollection
        options.showsBuildings = false

        // Muted emphasis for the row thumbnail. Points of interest were already
        // excluded, but standard emphasis still draws road labels, and at the
        // 38pt row size those are unreadable texture that competes with the
        // route line the thumbnail exists to show.
        let config = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: request.presentation == .thumbnail ? .muted : .default
        )
        config.pointOfInterestFilter = request.presentation == .thumbnail ? .excludingAll : .includingAll
        options.preferredConfiguration = config

        let completed = try await DriveCardMapSnapshotOperation(options: options).start()
        let snapshot = completed.value
        try Task.checkCancellation()

        let markers = request.presentation != .thumbnail
            ? await detailMarkers(for: source, traits: traitCollection)
            : []
        let compositedImage = compositedImage(
            baseImage: snapshot.image,
            snapshot: snapshot,
            segments: source.segments,
            stopCoordinates: source.stopMapCoordinates,
            routeColor: input.routeColor,
            traitCollection: traitCollection,
            markers: markers
        )
        return DriveCardMapRenderedImage(image: compositedImage)
    }

    /// Expand the geographic bounds to the image's aspect ratio, leaving
    /// space for pins and the expand button without cropping map attribution.
    static func detailMapRect(
        for content: RouteMapContent, size: CGSize,
        padding: UIEdgeInsets = UIEdgeInsets(top: 50, left: 24, bottom: 44, right: 24)
    ) -> MKMapRect? {
        guard let bounds = content.visibleMapRect(insetRatio: 0.08, minimumInset: 400),
              size.width > padding.left + padding.right,
              size.height > padding.top + padding.bottom else { return nil }
        let width = size.width - padding.left - padding.right
        let height = size.height - padding.top - padding.bottom
        let unitsPerPoint = max(bounds.width / width, bounds.height / height)
        return MKMapRect(
            x: bounds.midX - (padding.left + width / 2) * unitsPerPoint,
            y: bounds.midY - (padding.top + height / 2) * unitsPerPoint,
            width: size.width * unitsPerPoint,
            height: size.height * unitsPerPoint
        )
    }

    struct DetailMarker: @unchecked Sendable {
        var coordinate: CLLocationCoordinate2D
        var image: UIImage
        var centerOffset: CGPoint
    }

    @MainActor
    static func detailMarkers(for source: RouteMapContent, traits: UITraitCollection) -> [DetailMarker] {
        var locations: [(CLLocationCoordinate2D, UIColor, String)] = []
        if let start = source.startMapCoordinate { locations.append((start, .systemGreen, "location.circle")) }
        locations += source.stopMapCoordinates.map { ($0, .systemOrange, "pause.fill") }
        if let end = source.endMapCoordinate { locations.append((end, .systemRed, "flag.checkered")) }
        return locations.map { coordinate, color, symbol in
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
            marker.overrideUserInterfaceStyle = traits.userInterfaceStyle
            marker.markerTintColor = color
            marker.glyphImage = UIImage(systemName: symbol)
            marker.titleVisibility = .hidden
            marker.subtitleVisibility = .hidden
            marker.displayPriority = .required
            marker.prepareForDisplay()
            marker.sizeToFit()
            marker.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = traits.displayScale
            let image = UIGraphicsImageRenderer(size: marker.bounds.size, format: format).image { context in
                marker.layer.render(in: context.cgContext)
            }
            return DetailMarker(coordinate: coordinate, image: image, centerOffset: marker.centerOffset)
        }
    }

    @MainActor
    private static func traitCollection(for request: DriveCardMapSnapshotRequest) -> UITraitCollection {
        traitCollection(
            userInterfaceStyle: request.userInterfaceStyle,
            displayScale: request.displayScale
        )
    }

    @MainActor
    private static func traitCollection(
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = userInterfaceStyle
            traits.displayScale = displayScale
        }
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion()
        }

        guard coordinates.count >= 2 else {
            return MKCoordinateRegion(
                center: first,
                latitudinalMeters: singleCoordinateSpanMeters,
                longitudinalMeters: singleCoordinateSpanMeters
            )
        }

        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }

        guard !rect.isNull, !rect.isEmpty else {
            return MKCoordinateRegion(
                center: first,
                latitudinalMeters: singleCoordinateSpanMeters,
                longitudinalMeters: singleCoordinateSpanMeters
            )
        }

        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let minimumInset = MKMapPointsPerMeterAtLatitude(center.latitude) * minimumInsetMeters
        let dx = max(rect.width * routeInsetFraction, minimumInset)
        let dy = max(rect.height * routeInsetFraction, minimumInset)
        return MKCoordinateRegion(rect.insetBy(dx: -dx, dy: -dy))
    }

    private static func compositedImage(
        baseImage: UIImage,
        snapshot: MKMapSnapshotter.Snapshot,
        segments: [[CLLocationCoordinate2D]],
        stopCoordinates: [CLLocationCoordinate2D],
        routeColor: UIColor,
        traitCollection: UITraitCollection,
        markers: [DetailMarker]
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = baseImage.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: baseImage.size, format: format).image { _ in
            baseImage.draw(in: CGRect(origin: .zero, size: baseImage.size))
            drawRoute(
                segments: segments,
                stopCoordinates: stopCoordinates,
                snapshot: snapshot,
                routeColor: routeColor,
                traitCollection: traitCollection,
                drawsEndpointDots: markers.isEmpty
            )
            for marker in markers {
                let point = snapshot.point(for: marker.coordinate)
                marker.image.draw(at: CGPoint(
                    x: point.x + marker.centerOffset.x - marker.image.size.width / 2,
                    y: point.y + marker.centerOffset.y - marker.image.size.height / 2
                ))
            }
        }
    }

    private static func drawRoute(
        segments: [[CLLocationCoordinate2D]],
        stopCoordinates: [CLLocationCoordinate2D],
        snapshot: MKMapSnapshotter.Snapshot,
        routeColor: UIColor,
        traitCollection: UITraitCollection,
        drawsEndpointDots: Bool
    ) {
        let coordinates = segments.flatMap { $0 }
        guard let first = coordinates.first else { return }

        // Route furniture scales with the tile. These sizes were tuned for the
        // 156pt review card; drawn unchanged on a small row thumbnail a 12pt
        // endpoint dot covers a third of the image, so the tile reads as two
        // blobs rather than a route.
        //
        // The dots are always drawn, at a floor that keeps them visible: which
        // end is the start is the first thing you check on a route, and a bare
        // line does not say. They shrink, they never disappear.
        let minimumDimension = min(snapshot.image.size.width, snapshot.image.size.height)
        let scale = min(1, max(0.4, minimumDimension / 104))

        for segment in segments where segment.count >= 2 {
            let path = UIBezierPath()
            path.lineWidth = max(2, 5 * scale)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: snapshot.point(for: segment[0]))
            for coordinate in segment.dropFirst() {
                path.addLine(to: snapshot.point(for: coordinate))
            }
            routeColor
                .resolvedColor(with: traitCollection)
                .withAlphaComponent(0.82)
                .setStroke()
            path.stroke()
        }

        guard drawsEndpointDots else { return }
        for stopCoordinate in stopCoordinates {
            drawEndpointDot(
                at: snapshot.point(for: stopCoordinate),
                fillColor: UIColor.systemOrange.withAlphaComponent(0.9),
                traitCollection: traitCollection,
                dotSize: max(5, 10 * scale)
            )
        }

        drawEndpointDot(
            at: snapshot.point(for: first),
            fillColor: UIColor.systemGreen.withAlphaComponent(0.9),
            traitCollection: traitCollection,
            dotSize: max(6, 12 * scale)
        )

        if coordinates.count >= 2, let last = coordinates.last {
            drawEndpointDot(
                at: snapshot.point(for: last),
                fillColor: UIColor.systemRed.withAlphaComponent(0.85),
                traitCollection: traitCollection,
                dotSize: max(6, 12 * scale)
            )
        }
    }

    private static func drawEndpointDot(
        at point: CGPoint,
        fillColor: UIColor,
        traitCollection: UITraitCollection,
        dotSize: CGFloat
    ) {
        let rect = CGRect(
            x: point.x - dotSize / 2,
            y: point.y - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        let path = UIBezierPath(ovalIn: rect)
        fillColor
            .resolvedColor(with: traitCollection)
            .setFill()
        path.fill()
        UIColor.systemBackground
            .resolvedColor(with: traitCollection)
            .withAlphaComponent(0.9)
            .setStroke()
        path.lineWidth = 2
        path.stroke()
    }

}

private struct DriveCardMapRenderInput: @unchecked Sendable {
    var request: DriveCardMapSnapshotRequest
    var routeColor: UIColor
}

private extension UIUserInterfaceStyle {
    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            self = .dark
        default:
            self = .light
        }
    }

    var cacheToken: String {
        switch self {
        case .dark: "dark"
        default: "light"
        }
    }
}

protocol DriveCardMapSnapshotting: Sendable {
    func start(completion: @escaping @Sendable (Result<DriveCardMapSnapshotOperation.CompletedSnapshot, Error>) -> Void)
    func cancel()
}

private final class MapKitDriveCardSnapshotter: DriveCardMapSnapshotting, @unchecked Sendable {
    private let snapshotter: MKMapSnapshotter

    init(options: MKMapSnapshotter.Options) {
        snapshotter = MKMapSnapshotter(options: options)
    }

    func start(completion: @escaping @Sendable (Result<DriveCardMapSnapshotOperation.CompletedSnapshot, Error>) -> Void) {
        snapshotter.start(with: .global(qos: .userInitiated)) { snapshot, error in
            if let snapshot { completion(.success(.init(value: snapshot))) }
            else { completion(.failure(error ?? MKError(.unknown))) }
        }
    }

    func cancel() { snapshotter.cancel() }
}

/// Owns completion independently of MapKit's callback. Cancellation and timeout
/// must resume the waiting task so abandoned maps release their queue permits.
/// All mutable state and snapshotter start/cancel calls use the serial queue;
/// late callbacks are ignored after the first terminal result.
final class DriveCardMapSnapshotOperation: @unchecked Sendable {
    struct CompletedSnapshot: @unchecked Sendable {
        // The completed snapshot is immutable and is never shared with a
        // second consumer; only its image/coordinate projection are read.
        let value: MKMapSnapshotter.Snapshot
    }

    enum SnapshotError: Error { case timedOut }

    private let snapshotter: any DriveCardMapSnapshotting
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.daviddegner.MileageTracker.mapSnapshot")
    private var continuation: CheckedContinuation<CompletedSnapshot, Error>?
    private var result: Result<CompletedSnapshot, Error>?
    private var deadline: DispatchWorkItem?

    convenience init(options: MKMapSnapshotter.Options) {
        self.init(snapshotter: MapKitDriveCardSnapshotter(options: options))
    }

    init(snapshotter: any DriveCardMapSnapshotting, timeout: TimeInterval = 20) {
        self.snapshotter = snapshotter
        self.timeout = timeout
    }

    func start() async throws -> CompletedSnapshot {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result {
                        continuation.resume(with: result)
                        return
                    }
                    self.continuation = continuation
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(SnapshotError.timedOut), cancellingSnapshot: true)
                    }
                    self.deadline = deadline
                    queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                    snapshotter.start { [weak self] result in
                        guard let self else { return }
                        self.queue.async { self.finish(result) }
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.finish(.failure(CancellationError()), cancellingSnapshot: true)
            }
        }
    }

    private func finish(_ result: Result<CompletedSnapshot, Error>, cancellingSnapshot: Bool = false) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel()
        deadline = nil
        if cancellingSnapshot { snapshotter.cancel() }
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}
