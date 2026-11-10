import CoreLocation
@preconcurrency import MapKit
import os
import Observation

/// Search/geocoding failures here degrade gracefully in the UI (status text
/// or coordinate fallback), so they're logged rather than alerted.
private let tripEndpointSearchLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MileageTracker",
    category: "endpoint-search"
)

enum TripEndpointSearchTarget: String, Identifiable {
    case origin
    case destination

    var id: String { rawValue }

    var title: String {
        switch self {
        case .origin: String(localized: "Origin")
        case .destination: String(localized: "Destination")
        }
    }
}

struct TripEndpointSearchResult: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D

    init(title: String, subtitle: String = "", coordinate: CLLocationCoordinate2D) {
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        id = [
            title,
            subtitle,
            String(format: "%.6f", coordinate.latitude),
            String(format: "%.6f", coordinate.longitude)
        ].joined(separator: "|")
    }

    init?(mapItem: MKMapItem, coordinateOverride: CLLocationCoordinate2D? = nil) {
        let coordinate = coordinateOverride ?? mapItem.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let title = mapItem.name?.nilIfBlank
            ?? mapItem.address?.shortAddress?.nilIfBlank
            ?? mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)?.nilIfBlank
            ?? mapItem.address?.fullAddress.nilIfBlank
            ?? String(localized: "Selected Location")
        let subtitle = Self.subtitle(
            from: mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? mapItem.address?.fullAddress,
            removing: title
        )

        self.init(title: title, subtitle: subtitle, coordinate: coordinate)
    }

    static func == (lhs: TripEndpointSearchResult, rhs: TripEndpointSearchResult) -> Bool {
        lhs.id == rhs.id
    }

    var endpointText: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    var accessibilityIdentifier: String {
        "tripEndpointSearchResult-\(Self.slug(for: title))"
    }

    static func slug(for value: String) -> String {
        let slug = value.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return slug.isEmpty ? String(localized: "Location") : slug
    }

    private static func subtitle(from placemarkTitle: String?, removing title: String) -> String {
        guard var subtitle = placemarkTitle?.nilIfBlank else { return "" }
        for prefix in ["\(title), ", title] where subtitle.hasPrefix(prefix) {
            subtitle.removeFirst(prefix.count)
            break
        }
        return subtitle.nilIfBlank ?? ""
    }
}

struct TripEndpointSearchCompletion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D?
    let completion: MKLocalSearchCompletion?

    init(completion: MKLocalSearchCompletion) {
        self.title = completion.title
        self.subtitle = completion.subtitle
        self.coordinate = nil
        self.completion = completion
        id = [completion.title, completion.subtitle].joined(separator: "|")
    }

    init(title: String, subtitle: String = "", coordinate: CLLocationCoordinate2D) {
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.completion = nil
        id = [
            title,
            subtitle,
            String(format: "%.6f", coordinate.latitude),
            String(format: "%.6f", coordinate.longitude)
        ].joined(separator: "|")
    }

    var accessibilityIdentifier: String {
        "tripEndpointCompletion-\(TripEndpointSearchResult.slug(for: title))"
    }
}

@MainActor
@Observable
final class TripEndpointAutocompleteModel: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private(set) var completions: [TripEndpointSearchCompletion] = []
    private(set) var isSearching = false
    private(set) var isResolving = false
    private(set) var statusMessage: String?

    private let usesMapKitFixtures: Bool
    private let completer = MKLocalSearchCompleter()
    private var currentQuery = ""
    @ObservationIgnored private var activeSearch: MKLocalSearch?

    override init() {
        usesMapKitFixtures = MapKitTestFixturePolicy.isEnabled(arguments: ProcessInfo.processInfo.arguments)
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateQuery(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clear()
            return
        }

        guard trimmedQuery != currentQuery else { return }
        clear()
        currentQuery = trimmedQuery

        if usesMapKitFixtures {
            applyMapKitFixtureCompletions(matching: trimmedQuery)
            return
        }

        statusMessage = nil
        isSearching = true
        completer.queryFragment = trimmedQuery
    }

    func clear() {
        activeSearch?.cancel()
        activeSearch = nil
        currentQuery = ""
        isResolving = false
        completer.cancel()
        completer.queryFragment = ""
        completions = []
        isSearching = false
        statusMessage = nil
    }

    func result(for completion: TripEndpointSearchCompletion) async -> TripEndpointSearchResult? {
        if let coordinate = completion.coordinate {
            return TripEndpointSearchResult(title: completion.title, subtitle: completion.subtitle, coordinate: coordinate)
        }

        guard let searchCompletion = completion.completion else {
            return nil
        }

        activeSearch?.cancel()
        let request = MKLocalSearch.Request(completion: searchCompletion)
        let search = MKLocalSearch(request: request)
        activeSearch = search
        isResolving = true
        statusMessage = nil
        defer {
            if activeSearch === search {
                activeSearch = nil
                isResolving = false
            }
        }

        do {
            let response = try await search.start()
            guard activeSearch === search, !Task.isCancelled else { return nil }
            let result = response.mapItems.compactMap { mapItem in
                TripEndpointSearchResult(mapItem: mapItem)
            }.first
            statusMessage = result == nil ? String(localized: "No Results") : nil
            return result
        } catch {
            guard activeSearch === search, !Task.isCancelled else { return nil }
            tripEndpointSearchLogger.error("Completion search failed: \(String(describing: error))")
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard !currentQuery.isEmpty, completer.queryFragment == currentQuery else { return }
        completions = completer.results.map(TripEndpointSearchCompletion.init)
        isSearching = false
        statusMessage = completions.isEmpty ? String(localized: "No Results") : nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard !currentQuery.isEmpty, completer.queryFragment == currentQuery else { return }
        completions = []
        isSearching = false
        statusMessage = error.localizedDescription
    }

    private func applyMapKitFixtureCompletions(matching query: String) {
        let allCompletions = [
            TripEndpointSearchCompletion(
                title: "World Trade Center",
                coordinate: CLLocationCoordinate2D(latitude: 40.7127, longitude: -74.0134)
            ),
            TripEndpointSearchCompletion(
                title: "Grand Central Terminal",
                coordinate: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772)
            )
        ]
        let filtered = allCompletions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
        completions = filtered
        isSearching = false
        statusMessage = filtered.isEmpty ? String(localized: "No Results") : nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
