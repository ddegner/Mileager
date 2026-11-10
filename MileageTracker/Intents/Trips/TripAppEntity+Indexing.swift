import AppCore
import AppIntents
import CoreSpotlight
import Foundation

extension TripAppEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = routeLabel
        attributes.startDate = summary.startDate
        attributes.endDate = summary.endDate
        attributes.duration = NSNumber(value: summary.durationSeconds)
        attributes.contentDescription = contentDescription
        attributes.keywords = keywords
        attributes.textContent = summary.notes
        if let start = summary.startCoordinate {
            attributes.latitude = NSNumber(value: start.latitude)
            attributes.longitude = NSNumber(value: start.longitude)
            attributes.namedLocation = originLabel
        }
        return attributes
    }

    private var contentDescription: String {
        var parts: [String] = []
        let origin = Self.endpointText(
            components: summary.startAddressComponents,
            rawAddress: summary.startAddress,
            fallback: originLabel
        )
        let destination = Self.endpointText(
            components: summary.endAddressComponents,
            rawAddress: summary.endAddress,
            fallback: destinationLabel
        )
        let date = summary.startDate.formatted(date: .abbreviated, time: .shortened)
        let distance = Self.distanceText(meters: summary.reportableDistanceMeters)
        let duration = Self.durationText(seconds: summary.durationSeconds)
        parts.append(String(localized: "\(distance) drive from \(origin) to \(destination) on \(date)."))
        parts.append(String(localized: "It lasted \(duration)."))
        if let purpose = summary.businessPurpose, !purpose.isEmpty {
            parts.append(purpose)
        }
        return parts.joined(separator: " ")
    }

    /// Legacy geocoded addresses repeat segments ("123 Berlin Rd, 123 Berlin
    /// Rd, Cromwell, …"), which reads badly in a Spotlight snippet. Prefer the
    /// structured street + city; otherwise de-duplicate the raw string's
    /// comma-separated segments, keeping first occurrences in order.
    static func endpointText(
        components: TripEndpointAddressComponents?,
        rawAddress: String?,
        fallback: String
    ) -> String {
        if let components {
            let parts = [components.streetLine, components.city]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                return parts.joined(separator: ", ")
            }
        }
        if let rawAddress, !rawAddress.isEmpty {
            var seen = Set<String>()
            let segments = rawAddress
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            if !segments.isEmpty {
                return segments.joined(separator: ", ")
            }
        }
        return fallback
    }

    private var keywords: [String] {
        var keywords = [
            String(localized: "trip", comment: "Spotlight search keyword"),
            String(localized: "drive", comment: "Spotlight search keyword"),
            String(localized: "mileage", comment: "Spotlight search keyword")
        ]
        if let classification = summary.classification {
            keywords.append(classification.displayName)
        }
        if let vehicle, !vehicle.isEmpty {
            keywords.append(vehicle)
        }
        for components in [summary.startAddressComponents, summary.endAddressComponents] {
            if let city = components?.city, !city.isEmpty {
                keywords.append(city)
            }
        }
        return keywords
    }
}
