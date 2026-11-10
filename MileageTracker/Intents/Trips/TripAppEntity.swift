import AppCore
import AppIntents
import CoreSpotlight
import Foundation

/// App Intents projection of a recorded trip. Named `TripAppEntity` because
/// `TripEntity` is the Core Data managed object. The full `TripSummary` rides
/// along (not exposed as a parameter property) so Spotlight indexing can reach
/// coordinates and address details without refetching.
struct TripAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Trip",
        synonyms: ["Drive"]
    )
    static let defaultQuery = TripAppEntityQuery()

    let id: UUID
    let summary: TripSummary
    let originLabel: String
    let destinationLabel: String
    let isMostRecentReference: Bool

    @Property(title: "Start Date", indexingKey: \.startDate)
    var startDate: Date

    @Property(title: "End Date", indexingKey: \.endDate)
    var endDate: Date

    @Property(title: "Duration", indexingKey: \.duration)
    var duration: Measurement<UnitDuration>

    @Property(title: "Miles")
    var miles: Double

    @Property(title: "Category")
    var classification: TripClassificationAppEnum?

    @Property(title: "Business Purpose")
    var businessPurpose: String?

    @Property(title: "Notes")
    var notes: String?

    @Property(title: "Origin")
    var origin: String

    @Property(title: "Destination")
    var destination: String

    @Property(title: "Vehicle")
    var vehicle: String?

    init(
        _ trip: TripSummary,
        vehicleName: String? = nil,
        isMostRecentReference: Bool = false
    ) {
        let endpoints = DriveRouteLabelFormatter.endpoints(for: trip)
        id = trip.id
        summary = trip
        originLabel = endpoints.origin
        destinationLabel = endpoints.destination
        self.isMostRecentReference = isMostRecentReference
        startDate = trip.startDate
        endDate = trip.endDate
        duration = Measurement(value: trip.durationSeconds, unit: .seconds)
        miles = trip.miles
        classification = trip.classification.map(TripClassificationAppEnum.init)
        businessPurpose = trip.businessPurpose
        notes = trip.notes
        origin = endpoints.origin
        destination = endpoints.destination
        vehicle = vehicleName
    }

    var routeLabel: String {
        "\(originLabel) → \(destinationLabel)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(routeLabel)",
            subtitle: "\(subtitleText)",
            image: .init(systemName: "car.fill"),
            synonyms: referenceSynonyms
        )
    }

    /// Contextual names only belong to the newest completed trip. Older
    /// entities must never advertise themselves as "last" after a new trip is
    /// recorded, so queries opt the current newest value into these synonyms.
    private var referenceSynonyms: [LocalizedStringResource] {
        guard isMostRecentReference else { return [] }
        return [
            "Last Drive",
            "Previous Drive",
            "Latest Drive",
            "Most Recent Drive",
            "Last Trip",
            "Previous Trip",
            "Latest Trip",
            "Most Recent Trip",
            "Drive I Just Finished",
            "Trip I Just Finished"
        ]
    }

    private var subtitleText: String {
        let date = summary.startDate.formatted(date: .abbreviated, time: .omitted)
        let distance = Self.distanceText(meters: summary.reportableDistanceMeters)
        let status = summary.classification?.displayName ?? String(localized: "Needs review")
        var text = "\(date) · \(distance) · \(status)"
        if let vehicle, !vehicle.isEmpty {
            text += " · \(vehicle)"
        }
        return text
    }

    /// The user's resolved display unit, read from the UserDefaults mirror
    /// because entity display code runs off the main actor.
    static var displayUnit: DistanceUnit {
        DistanceUnit(rawValue: Preferences().displayDistanceUnitRaw ?? "") ?? .miles
    }

    static func distanceText(meters: Double, unit: DistanceUnit = displayUnit) -> String {
        DistanceFormatting.label(meters: meters, unit: unit, fractionDigits: 0...1)
    }

    static func durationText(seconds: Double) -> String {
        let seconds = max(0, seconds)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        if seconds >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
        } else if seconds >= 60 {
            formatter.allowedUnits = [.minute]
        } else {
            formatter.allowedUnits = [.second]
        }
        return formatter.string(from: seconds) ?? String(localized: "\(Int(seconds.rounded())) seconds")
    }
}
