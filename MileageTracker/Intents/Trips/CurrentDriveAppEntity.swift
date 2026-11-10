import AppCore
import AppIntents
import Foundation

/// Siri and Shortcuts representation of the one drive currently being recorded.
/// The pending trip UUID changes for every drive, so a reference to an older
/// drive can never silently mutate a newer recording.
struct CurrentDriveAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Current Drive",
        synonyms: ["Active Drive", "Drive in Progress", "Current Trip", "Trip in Progress"]
    )
    static let defaultQuery = CurrentDriveAppEntityQuery()

    let id: UUID
    let summary: CurrentDriveSummary

    @Property(title: "Start Date")
    var startedAt: Date

    @Property(title: "Miles")
    var miles: Double

    @Property(title: "Status")
    var status: String

    @Property(title: "Category")
    var classification: TripClassificationAppEnum?

    @Property(title: "Business Purpose")
    var businessPurpose: String?

    @Property(title: "Notes")
    var notes: String?

    @Property(title: "Origin")
    var origin: String?

    @Property(title: "Fee Count")
    var feeCount: Int

    @Property(title: "Vehicle")
    var vehicle: String?

    init(_ summary: CurrentDriveSummary) {
        id = summary.pendingTripID
        self.summary = summary
        startedAt = summary.startedAt
        miles = DistanceConversion.miles(fromMeters: summary.distanceMeters)
        status = summary.phase.intentDisplayName
        classification = summary.classification.map(TripClassificationAppEnum.init)
        businessPurpose = summary.businessPurpose
        notes = summary.note
        origin = summary.originLabel
        feeCount = summary.feeCount
        vehicle = summary.vehicle?.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Current Drive",
            subtitle: "\(subtitleText)",
            image: .init(systemName: "car.fill"),
            synonyms: [
                "This Drive",
                "My Current Drive",
                "Active Drive",
                "Drive in Progress",
                "This Trip",
                "My Current Trip",
                "Current Trip",
                "Active Trip",
                "Trip in Progress",
                "Ongoing Drive",
                "Ongoing Trip",
                "Drive I'm On",
                "Trip I'm On"
            ]
        )
    }

    private var subtitleText: String {
        var parts = [
            summary.startedAt.formatted(date: .omitted, time: .shortened),
            TripAppEntity.distanceText(meters: summary.distanceMeters),
            summary.phase.intentDisplayName
        ]
        if let classification = summary.classification {
            parts.append(classification.displayName)
        }
        if let vehicle = summary.vehicle?.name, !vehicle.isEmpty {
            parts.append(vehicle)
        }
        return parts.joined(separator: " · ")
    }
}

/// There can be at most one suggested current-drive entity. Identifier lookup
/// deliberately requires the live UUID so a Shortcut holding an old reference
/// fails instead of applying its edit to the next trip.
struct CurrentDriveAppEntityQuery: EntityQuery {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CurrentDriveAppEntity] {
        guard !identifiers.isEmpty else { return [] }
        let model = try await TripIntentDataProvider.readyModel()
        guard let summary = model.currentDrive,
              identifiers.allSatisfy({ $0 == summary.pendingTripID }) else {
            // Returning [] lets the system erase an unresolved optional
            // parameter and invoke the action with nil ("the current drive").
            // An explicit stale reference must fail before that can happen.
            throw TripIntentError.currentDriveNotFound
        }
        return [CurrentDriveAppEntity(summary)]
    }

    @MainActor
    func suggestedEntities() async throws -> [CurrentDriveAppEntity] {
        guard let summary = (try? await TripIntentDataProvider.readyModel())?.currentDrive else {
            return []
        }
        return [CurrentDriveAppEntity(summary)]
    }
}

extension CurrentDriveAppEntityQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [CurrentDriveAppEntity] {
        guard let summary = (try? await TripIntentDataProvider.readyModel())?.currentDrive else {
            return []
        }
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let names = [
            String(localized: "Current Drive"),
            String(localized: "This Drive"),
            String(localized: "My Current Drive"),
            String(localized: "Active Drive"),
            String(localized: "Drive in Progress"),
            String(localized: "Current Trip"),
            String(localized: "This Trip"),
            String(localized: "My Current Trip"),
            String(localized: "Active Trip"),
            String(localized: "Trip in Progress"),
            String(localized: "Ongoing Drive"),
            String(localized: "Ongoing Trip"),
            String(localized: "Drive I'm On"),
            String(localized: "The Drive I'm On"),
            String(localized: "Trip I'm On"),
            String(localized: "The Trip I'm On")
        ].map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        guard query.isEmpty || names.contains(where: { $0.contains(query) || query.contains($0) }) else {
            return []
        }
        return [CurrentDriveAppEntity(summary)]
    }
}

@MainActor
enum CurrentDriveIntentResolver {
    static func resolve(
        _ requested: CurrentDriveAppEntity?,
        in model: MileageAppModel
    ) throws -> CurrentDriveSummary {
        guard let current = model.currentDrive else {
            throw TripIntentError.currentDriveNotFound
        }
        guard requested?.id == nil || requested?.id == current.pendingTripID else {
            throw TripIntentError.currentDriveNotFound
        }
        return current
    }
}

private extension CurrentDriveSummary.Phase {
    var intentDisplayName: String {
        switch self {
        case .recording:
            String(localized: "Recording")
        case .paused:
            String(localized: "Paused")
        case .confirmingTripEnd:
            String(localized: "Confirming Drive End")
        }
    }
}
