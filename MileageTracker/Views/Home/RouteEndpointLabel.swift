import AppCore
import Foundation

/// Formats a trip-card route label from structured endpoint components when
/// available, falling back to cleaned legacy address strings for existing trips.
enum DriveRouteLabelFormatter {
    static func label(for trip: TripSummary) -> String {
        let parts = endpoints(for: trip)
        return "\(parts.origin) → \(parts.destination)"
    }

    /// One leading component per endpoint ("COSI → North Market") for compact
    /// list rows. Falls back to the standard two-part labels (and
    /// their existing expansion chain) when the compact forms collide.
    static func compactEndpoints(for trip: TripSummary) -> (origin: String, destination: String) {
        let (origin, destination, style) = resolvedEndpoints(for: trip)
        return compactEndpoints(origin: origin, destination: destination, style: style)
    }

    static func compactEndpoints(for leg: TripDisplayLeg) -> (origin: String, destination: String) {
        let origin = RouteEndpoint(
            rawAddress: leg.startAddress, components: nil,
            coordinate: leg.startCoordinate, unknownLabel: "Unknown origin"
        )
        let destination = RouteEndpoint(
            rawAddress: leg.endAddress, components: nil,
            coordinate: leg.endCoordinate, unknownLabel: "Unknown destination"
        )
        return compactEndpoints(
            origin: origin, destination: destination,
            style: RouteLabelStyle.resolved(origin: origin, destination: destination)
        )
    }

    private static func compactEndpoints(
        origin: RouteEndpoint, destination: RouteEndpoint, style: RouteLabelStyle
    ) -> (origin: String, destination: String) {
        let compactOrigin = origin.label(style: style, targetCount: 1)
        let compactDestination = destination.label(style: style, targetCount: 1)
        guard compactOrigin.displayKey == compactDestination.displayKey else {
            return (compactOrigin, compactDestination)
        }
        return endpoints(origin: origin, destination: destination, style: style)
    }

    static func endpoints(for trip: TripSummary) -> (origin: String, destination: String) {
        let (origin, destination, style) = resolvedEndpoints(for: trip)
        return endpoints(origin: origin, destination: destination, style: style)
    }

    private static func endpoints(
        origin: RouteEndpoint, destination: RouteEndpoint, style: RouteLabelStyle
    ) -> (origin: String, destination: String) {
        let originLabel = origin.label(style: style)
        let destinationLabel = destination.label(style: style)

        guard originLabel.displayKey == destinationLabel.displayKey else {
            return (originLabel, destinationLabel)
        }

        let expandedOrigin = origin.expandedLabel(style: style, conflictingWith: destinationLabel)
        let expandedDestination = destination.expandedLabel(style: style, conflictingWith: originLabel)
        guard expandedOrigin.displayKey == expandedDestination.displayKey else {
            return (expandedOrigin, expandedDestination)
        }

        return (
            origin.rawDisambiguatedLabel(conflictingWith: expandedDestination, fallback: expandedOrigin),
            destination.rawDisambiguatedLabel(conflictingWith: expandedOrigin, fallback: expandedDestination)
        )
    }

    private static func resolvedEndpoints(
        for trip: TripSummary
    ) -> (origin: RouteEndpoint, destination: RouteEndpoint, style: RouteLabelStyle) {
        let origin = RouteEndpoint(
            rawAddress: trip.startAddress,
            components: trip.startAddressComponents,
            coordinate: trip.startCoordinate,
            unknownLabel: "Unknown origin"
        )
        let destination = RouteEndpoint(
            rawAddress: trip.endAddress,
            components: trip.endAddressComponents,
            coordinate: trip.endCoordinate,
            unknownLabel: "Unknown destination"
        )
        let style = RouteLabelStyle.resolved(origin: origin, destination: destination)
        return (origin, destination, style)
    }
}

private enum RouteLabelStyle {
    case sameCity
    case sameStateDifferentCity
    case crossState
    case unresolved

    static func resolved(origin: RouteEndpoint, destination: RouteEndpoint) -> RouteLabelStyle {
        if origin.hasDifferentState(than: destination) {
            return .crossState
        }
        if origin.hasSameCity(as: destination) {
            return .sameCity
        }
        if origin.hasCity || destination.hasCity {
            return .sameStateDifferentCity
        }
        return .unresolved
    }
}

private struct RouteEndpoint {
    var rawAddress: String?
    var components: TripEndpointAddressComponents?
    var coordinate: Coordinate?
    var unknownLabel: String

    private var addressParts: RouteAddressParts? {
        if let structured = components.flatMap(RouteAddressParts.init(components:)) {
            return structured
        }
        return rawAddress.flatMap(RouteAddressParts.init(rawValue:))
    }

    var hasCity: Bool {
        addressParts?.city != nil
    }

    func hasSameCity(as other: RouteEndpoint) -> Bool {
        guard let key = addressParts?.cityKey, let otherKey = other.addressParts?.cityKey else {
            return false
        }
        return key == otherKey
    }

    func hasDifferentState(than other: RouteEndpoint) -> Bool {
        guard let key = addressParts?.stateKey, let otherKey = other.addressParts?.stateKey else {
            return false
        }
        return key != otherKey
    }

    func label(style: RouteLabelStyle, targetCount: Int = 2) -> String {
        addressParts?.label(style: style, targetCount: targetCount)
            ?? bestLabel
    }

    func expandedLabel(style: RouteLabelStyle, conflictingWith otherLabel: String) -> String {
        let expanded = addressParts?.label(style: style, targetCount: 3)
        if let expanded, expanded.displayKey != otherLabel.displayKey {
            return expanded
        }
        if bestLabel.displayKey != otherLabel.displayKey {
            return bestLabel
        }
        return expanded ?? bestLabel
    }

    func rawDisambiguatedLabel(conflictingWith otherLabel: String, fallback: String) -> String {
        if bestLabel.displayKey != otherLabel.displayKey {
            return bestLabel
        }
        return fallback
    }

    private var bestLabel: String {
        cleanedRawAddress ?? (coordinate == nil ? unknownLabel : "Dropped pin")
    }

    private var cleanedRawAddress: String? {
        rawAddress.flatMap(RouteAddressCleaner.cleanedCardAddress)
    }
}

private struct RouteAddressParts {
    /// The leading component of a raw address string — "North Market" in
    /// "North Market, 59 Spruce St, Columbus, OH". Every style leads with it,
    /// because it is what a person recognizes and it does not depend on where
    /// the drive ended: without it, the same saved address rendered "North
    /// Market" on a drive across town and "59 Spruce St" on a drive that
    /// crossed the city line.
    ///
    /// Only the raw-string initializer sets it. Structured components carry a
    /// real street/neighborhood/city split with no place name in them, so
    /// their labels stay entirely style-driven.
    var placeName: String?
    var streetLine: String?
    var neighborhood: String?
    var city: String?
    var state: String?
    var country: String?

    init?(components: TripEndpointAddressComponents) {
        streetLine = components.streetLine.map(AddressDisplayFormatter.abbreviatingStreetType)
        neighborhood = components.neighborhood
        city = components.city
        state = components.state
        country = components.country
        guard hasAnyValue else { return nil }
    }

    init?(rawValue: String) {
        guard var parts = RouteAddressCleaner.cleanedComponents(rawValue), !parts.isEmpty else {
            return nil
        }
        if parts.count == 1 {
            streetLine = parts[0]
            neighborhood = parts[0]
        } else if parts.count == 2, RouteAddressCleaner.looksLikeState(parts[1]) {
            city = parts[0]
            state = parts[1]
        } else if parts.count == 2 {
            streetLine = parts[0]
            neighborhood = parts[0]
            city = parts[1]
        } else if parts.count == 3 {
            let stateIndex = parts.index(before: parts.endIndex)
            state = parts[stateIndex]
            parts.remove(at: stateIndex)
            let cityIndex = parts.index(before: parts.endIndex)
            city = parts[cityIndex]
            parts.remove(at: cityIndex)
            let place = parts.joined(separator: ", ")
            streetLine = place
            neighborhood = place
        } else {
            streetLine = parts.first
            neighborhood = parts.dropFirst().dropLast(2).first
            city = parts[parts.index(parts.endIndex, offsetBy: -2)]
            state = parts[parts.index(before: parts.endIndex)]
        }
        placeName = streetLine
        guard hasAnyValue else { return nil }
    }

    var cityKey: String? {
        guard let city else { return nil }
        return [city, state].compactMap { $0?.displayKey }.joined(separator: "|")
    }

    var stateKey: String? {
        state?.displayKey
    }

    private var hasAnyValue: Bool {
        streetLine != nil || neighborhood != nil || city != nil || state != nil || country != nil
    }

    /// `targetCount` is the number of display components to assemble: 1 for
    /// compact list labels, 2 for the standard card label, 3 for the
    /// expanded disambiguation pass (which also unlocks the extra fallbacks).
    func label(style: RouteLabelStyle, targetCount: Int) -> String? {
        // `placeName` leads every style when there is one; it is nil for
        // structured components, which leaves those labels style-driven as
        // before. Duplicates collapse in `UniqueDisplayParts`, so a raw
        // address whose leading component is already the street costs nothing.
        switch style {
        case .sameCity:
            return label(
                primary: [placeName, streetLine, neighborhood],
                fallbacks: [city],
                expandedFallbacks: [city, state, country],
                targetCount: targetCount
            )
        case .sameStateDifferentCity:
            return label(
                primary: [placeName, neighborhood, city],
                fallbacks: [],
                expandedFallbacks: [streetLine, state, country],
                targetCount: targetCount
            )
        case .crossState:
            return label(
                primary: [placeName, city ?? neighborhood ?? streetLine, state],
                fallbacks: [neighborhood, streetLine],
                expandedFallbacks: [neighborhood, streetLine, country],
                targetCount: targetCount
            )
        case .unresolved:
            return label(
                primary: [placeName, neighborhood, city],
                fallbacks: [streetLine, state],
                expandedFallbacks: [streetLine, state, country],
                targetCount: targetCount
            )
        }
    }

    private func label(
        primary: [String?],
        fallbacks: [String?],
        expandedFallbacks: [String?],
        targetCount: Int
    ) -> String? {
        var values = UniqueDisplayParts()
        for value in primary where values.count < targetCount {
            values.append(value)
        }
        let candidateFallbacks = targetCount >= 3 ? fallbacks + expandedFallbacks : fallbacks
        for fallback in candidateFallbacks where values.count < targetCount {
            values.append(fallback)
        }
        return values.joined()
    }
}

private struct UniqueDisplayParts {
    private var values: [String] = []
    private var keys = Set<String>()

    var count: Int { values.count }

    mutating func append(_ value: String?) {
        guard let value = value?.normalizedForDisplay else { return }
        let key = value.displayKey
        guard !keys.contains(key) else { return }
        keys.insert(key)
        values.append(value)
    }

    func joined() -> String? {
        values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

private enum RouteAddressCleaner {
    static func cleanedCardAddress(_ rawValue: String) -> String? {
        cleanedComponents(rawValue)?.joined(separator: ", ")
    }

    static func cleanedComponents(_ rawValue: String) -> [String]? {
        guard let normalized = AddressDisplayFormatter.readableAddress(rawValue).normalizedForDisplay else {
            return nil
        }
        var seen = Set<String>()
        let components = normalized
            .split(separator: ",")
            .compactMap { cleanedComponent(String($0)) }
            .filter { component in
                let key = component.displayKey
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
        return components.isEmpty ? nil : components
    }

    static func looksLikeState(_ value: String) -> Bool {
        let normalized = value.normalizedForDisplay ?? value
        if normalized.count == 2, normalized.allSatisfy(\.isLetter) {
            return true
        }
        return normalized.range(of: #"\d"#, options: .regularExpression) == nil
    }

    private static func cleanedComponent(_ component: String) -> String? {
        guard var value = component.normalizedForDisplay else { return nil }
        guard !isCountry(value) else { return nil }
        value = value
            .replacingOccurrences(of: #"\b\d{5}(?:-\d{4})?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        return value.normalizedForDisplay.map(AddressDisplayFormatter.abbreviatingStreetType)
    }

    private static func isCountry(_ value: String) -> Bool {
        switch value.displayKey {
        case "united states", "united states of america", "usa", "us":
            true
        default:
            false
        }
    }
}

private extension String {
    var normalizedForDisplay: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ,", with: ",")
        return value.isEmpty ? nil : value
    }

    var displayKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}
