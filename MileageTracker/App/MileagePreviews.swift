#if DEBUG
import AppCore
import SwiftUI

@MainActor
private enum MileagePreviewData {
    static func model() -> MileageAppModel {
        let model = MileageAppModel(previewMode: true)
        model.businessPurposePresets = ["Client meeting", "Site visit", "Supplies"]

        let base = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 5, day: 24, hour: 8, minute: 30)
        ) ?? Date()

        addTrip(
            to: model,
            startDate: base,
            minutes: 32,
            miles: 7.2,
            origin: "Financial District, New York, NY",
            destination: "Midtown, New York, NY",
            coordinates: (
                Coordinate(latitude: 40.7046, longitude: -74.0119),
                Coordinate(latitude: 40.7580, longitude: -73.9855)
            ),
            notes: "Confirm client purpose"
        )

        addTrip(
            to: model,
            startDate: base.addingTimeInterval(-86_400),
            minutes: 46,
            miles: 18.6,
            origin: "Home",
            destination: "Client office",
            coordinates: (
                Coordinate(latitude: 40.7484, longitude: -73.9857),
                Coordinate(latitude: 40.6892, longitude: -74.0445)
            ),
            classification: .business,
            purpose: "Client meeting",
            notes: "Reviewed",
            tolls: 8.50
        )

        addTrip(
            to: model,
            startDate: base.addingTimeInterval(-172_800),
            minutes: 21,
            miles: 4.3,
            origin: "Gym",
            destination: "Home",
            coordinates: (
                Coordinate(latitude: 40.7812, longitude: -73.9665),
                Coordinate(latitude: 40.7484, longitude: -73.9857)
            ),
            classification: .personal,
            notes: "Personal errand"
        )

        return model
    }

    private static func addTrip(
        to model: MileageAppModel,
        startDate: Date,
        minutes: Double,
        miles: Double,
        origin: String,
        destination: String,
        coordinates: (start: Coordinate, end: Coordinate),
        classification: TripClassification? = nil,
        purpose: String = "",
        notes: String = "",
        tolls: Double = 0,
        parking: Double = 0
    ) {
        _ = model.createManualTrip(
            startDate: startDate,
            endDate: startDate.addingTimeInterval(minutes * 60),
            distanceMiles: miles,
            distanceWasEdited: false,
            origin: origin,
            destination: destination,
            resolvedRoute: ResolvedManualRoute(
                startCoordinate: coordinates.start,
                endCoordinate: coordinates.end,
                routePolyline: nil,
                distanceMeters: nil
            ),
            classification: classification,
            purpose: purpose,
            notes: notes,
            tolls: tolls,
            parking: parking
        )
    }
}

#Preview("Home") {
    ContentView()
        .environment(MileagePreviewData.model())
        .mileageAppTheme()
}

#Preview("Settings") {
    SettingsView()
        .environment(MileagePreviewData.model())
        .mileageAppTheme()
}

#endif
