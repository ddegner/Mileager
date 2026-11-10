import AppCore
import Foundation
import SwiftUI

/// A focused post-trip assignment surface for a newly observed car connection.
struct VehicleConnectionDecisionSheet: View {
    let decision: PendingVehicleConnectionDecision
    let vehicles: [Vehicle]
    let trip: TripSummary?
    let distanceUnit: DistanceUnit
    let chooseVehicle: (UUID) -> Void
    let ignoreConnection: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingIgnoreConfirmation = false

    private var presentation: VehicleConnectionDecisionPresentation {
        VehicleConnectionDecisionPresentation(decision: decision, vehicles: vehicles)
    }

    var body: some View {
        Group {
            if needsScrolling {
                ScrollView {
                    decisionContent
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 620)
            } else {
                decisionContent
            }
        }
        .background(MileageTheme.groupedBackground)
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .alert(
            presentation.ignoreTitle,
            isPresented: $showingIgnoreConfirmation
        ) {
            Button("Ignore Connection", role: .destructive) {
                ignoreConnection()
            }
            Button("Go Back", role: .cancel) {}
        } message: {
            Text(presentation.ignoreMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vehicleConnectionDecisionSheet")
    }

    private var decisionContent: some View {
        VStack(spacing: 16) {
            header

            if let trip {
                tripContext(trip)
            }

            vehicleChoices

            secondaryActions
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    private var needsScrolling: Bool {
        dynamicTypeSize.isAccessibilitySize || choiceVehicles.count > 4
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(presentation.title)
                .font(.title2.weight(.bold))
                .accessibilityIdentifier("vehicleConnectionDecisionTitle")

            Text(presentation.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vehicleConnectionDecisionExplanation")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tripContext(_ trip: TripSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(DriveRouteLabelFormatter.label(for: trip))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(tripCaption(trip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trip to confirm: \(DriveRouteLabelFormatter.label(for: trip)), \(tripCaption(trip))")
        .accessibilityIdentifier("vehicleConnectionDecisionTrip")
    }

    private var vehicleChoices: some View {
        VStack(spacing: 10) {
            ForEach(choiceVehicles) { vehicle in
                Button {
                    chooseVehicle(vehicle.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: VehicleAppearance.symbol(vehicle.symbolName))
                            .font(.headline)
                            .foregroundStyle(VehicleAppearance.color(forHex: vehicle.colorHex))
                            .frame(width: 28)

                        Text("Use \(vehicle.name)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 8)

                        if presentation.suggestedVehicleID == vehicle.id {
                            Text("Suggested")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MileageTheme.appTint)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(MileageTheme.appTint.opacity(0.12), in: Capsule())
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: 14)
                    )
                    .overlay {
                        if presentation.suggestedVehicleID == vehicle.id {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(MileageTheme.appTint.opacity(0.45), lineWidth: 1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vehicleConnectionDecisionVehicleChoice")
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if presentation.canIgnoreConnection {
            Button(role: .destructive) {
                showingIgnoreConfirmation = true
            } label: {
                Label("Not my car", systemImage: "xmark.circle")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .tint(.red)
            .accessibilityHint("Explains how ignoring this connection affects drive detection")
            .accessibilityIdentifier("vehicleConnectionDecisionNotMyCar")
        }
    }

    private var choiceVehicles: [Vehicle] {
        switch decision.kind {
        case let .unknownConnection(_, suggestion):
            guard let suggestedID = suggestion?.vehicleID,
                  let suggestedVehicle = vehicles.first(where: { $0.id == suggestedID }) else {
                return vehicles
            }
            return [suggestedVehicle] + vehicles.filter { $0.id != suggestedID }

        case let .conflictingVehicles(vehicleIDs, _):
            let byID = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.id, $0) })
            return vehicleIDs.compactMap { byID[$0] }
        }
    }

    private func tripCaption(_ trip: TripSummary) -> String {
        let date = trip.startDate.formatted(date: .abbreviated, time: .shortened)
        let distance = DistanceFormatting.label(
            meters: trip.reportableDistanceMeters,
            unit: distanceUnit
        )
        return "\(date) · \(distance)"
    }
}

/// Pure question copy kept separate from the view so every identity branch can
/// be covered without relying on UI automation.
struct VehicleConnectionDecisionPresentation: Equatable {
    var title: String
    var explanation: String
    var suggestedVehicleID: UUID?
    var canIgnoreConnection: Bool
    var ignoreTitle: String
    var ignoreMessage: String

    init(decision: PendingVehicleConnectionDecision, vehicles: [Vehicle]) {
        let vehicleNames = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.id, $0.name) })
        ignoreMessage = String(localized: "Mileager will stop using this connection to help detect drives. You can restore it later in Settings › Vehicles.")

        switch decision.kind {
        case let .unknownConnection(hint, suggestion):
            let name = Self.trimmedName(hint.displayName)
            suggestedVehicleID = suggestion?.vehicleID
            canIgnoreConnection = true
            ignoreTitle = name.map { String(localized: "Ignore “\($0)”?") }
                ?? String(localized: "Ignore this car connection?")

            if hint.identityQuality != .stablePortIdentifier {
                title = String(localized: "Which car was this trip in?")
                explanation = String(localized: "Mileager will suggest this car on future drives, but still ask you to confirm.")
            } else if let suggestedID = suggestion?.vehicleID,
                      let suggestedName = vehicleNames[suggestedID] {
                explanation = String(localized: "Mileager will recognize this car automatically on future drives.")
                if let name {
                    title = String(localized: "Is “\(name)” your \(suggestedName)?")
                } else {
                    title = String(localized: "Is this car connection your \(suggestedName)?")
                }
            } else {
                explanation = String(localized: "Mileager will recognize this car automatically on future drives.")
                if let name {
                    title = String(localized: "Which car is “\(name)”?")
                } else {
                    title = String(localized: "Which car uses this connection?")
                }
            }

        case .conflictingVehicles:
            title = String(localized: "Which car did you drive?")
            explanation = String(localized: "Mileager found more than one saved car connection during this trip.")
            suggestedVehicleID = nil
            canIgnoreConnection = false
            ignoreTitle = String(localized: "Ignore this car connection?")
        }
    }

    private static func trimmedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
