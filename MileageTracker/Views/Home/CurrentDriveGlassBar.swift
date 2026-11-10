import AppCore
import AppIntents
import SwiftUI

/// A high-contrast, action-first surface shown while a drive is recording.
/// The live metrics stay compact so classification, leg splitting, and fee entry
/// remain the largest and easiest targets on the screen.
struct CurrentDriveGlassBar: View {
    @Environment(MileageAppModel.self) private var model

    var summary: CurrentDriveSummary
    var onSelectClassification: (TripClassification?) -> Void
    var onAddFee: (TripFeeCategory) -> Void
    var onStartNewLeg: () -> Void
    var onChooseVehicle: () -> Void
    var onMinimize: () -> Void
    /// Report the locally presented purpose editor to the root presenter. Live
    /// Activity requests remain queued while this sheet is visible instead of
    /// attempting to present a second sheet or dialog over it.
    @Binding var isPresentingPurposeEditor: Bool

    @State private var newLegJustStarted = false

    var body: some View {
        VStack(spacing: 8) {
            statusHeader
            actionGrid
        }
        // 26pt panel radius − 10pt inset = the tiles' 16pt radius, keeping
        // the nested corners and edge spacing visually concentric.
        .padding(10)
        // Capped so a wide window (Max landscape, iPad, Mac) gets a centered
        // panel instead of a full-width glass slab with a tiny action grid;
        // the glass and its border are applied inside the cap, and the
        // trailing infinity frame (below the shadows) does the centering.
        .frame(maxWidth: 560)
        .glassEffect(
            .clear.tint(.black.opacity(0.70)).interactive(),
            in: .rect(cornerRadius: MileageTheme.cardCornerRadius)
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MileageTheme.cardCornerRadius,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.30),
                        .white.opacity(0.13),
                        .white.opacity(0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .sheet(isPresented: $isPresentingPurposeEditor) {
            CurrentDrivePurposeNoteSheet(summary: summary)
                .environment(model)
        }
        .currentDriveEntityAnnotation(
            id: summary.pendingTripID,
            isEnabled: model.siriIndexingEnabled
        )
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            vehicleButton
            Spacer(minLength: 0)

            Divider()
                .overlay(.white.opacity(0.24))
                .frame(height: 32)

            metricPair
            minimizeButton
        }
        .padding(.horizontal, 6)
        .lineLimit(1)
        .minimumScaleFactor(0.60)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("currentDriveBar")
        // The pending ID is only exposed to the UI-test fixture so a test can
        // exercise the exact deep link the Live Activity sends. Shipping
        // accessibility stays focused on the bar's user-facing controls.
        .accessibilityValue(
            model.isUITesting ? Text(summary.pendingTripID.uuidString) : Text("")
        )
    }

    private var vehicleButton: some View {
        Button(action: onChooseVehicle) {
            statusLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Vehicle")
        .accessibilityValue(vehicleLabel)
        .accessibilityHint("Changes the vehicle for this drive")
        .accessibilityIdentifier("currentDriveBarVehicle")
    }

    private var minimizeButton: some View {
        Button(action: onMinimize) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minimize current trip controls")
        .accessibilityIdentifier("currentDriveBarMinimize")
    }

    private var metricPair: some View {
        HStack(spacing: 6) {
            CurrentDriveLiveMetric(title: String(localized: "Distance"), value: distanceLabel)

            Divider()
                .overlay(.white.opacity(0.32))
                .frame(height: 34)

            if summary.phase == .confirmingTripEnd {
                lastMovementMetric
            } else {
                CurrentDriveLiveMetric(
                    title: String(localized: "Elapsed"),
                    startedAt: summary.startedAt
                )
            }
        }
    }

    private var actionGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                businessButton(axis: .horizontal)
                personalButton(axis: .horizontal)
            }

            HStack(spacing: 8) {
                feeButton(
                    .toll,
                    systemImage: "dollarsign.circle.fill",
                    title: String(localized: "Toll"),
                    accessibilityTitle: String(localized: "Add Toll"),
                    identifier: "currentDriveBarToll",
                    axis: .vertical
                )
                feeButton(
                    .parking,
                    systemImage: "parkingsign.circle.fill",
                    title: String(localized: "Parking"),
                    accessibilityTitle: String(localized: "Add Parking"),
                    identifier: "currentDriveBarParking",
                    axis: .vertical
                )
                newLegButton(axis: .vertical, maxWidth: .infinity)
            }
        }
    }

    private func businessButton(axis: CurrentDriveActionTile.Axis) -> some View {
        let selected = summary.classification == .business

        return Button {
            onSelectClassification(.business)
            isPresentingPurposeEditor = true
        } label: {
            CurrentDriveActionTile(
                title: TripClassification.business.displayName,
                systemImage: "briefcase.fill",
                tint: .white,
                symbolTint: MileageTheme.businessAccent,
                selectionTint: MileageTheme.businessAccent,
                isSelected: selected,
                axis: axis,
                surface: .classification
            )
        }
        .buttonStyle(CurrentDriveButtonStyle())
        .accessibilityLabel(TripClassification.business.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("currentDriveBarClassificationbusiness")
    }

    private func personalButton(axis: CurrentDriveActionTile.Axis) -> some View {
        let selected = summary.classification == .personal

        return Button {
            onSelectClassification(selected ? nil : .personal)
        } label: {
            CurrentDriveActionTile(
                title: TripClassification.personal.displayName,
                systemImage: "person.fill",
                tint: .white,
                symbolTint: MileageTheme.personalAccent,
                selectionTint: MileageTheme.personalAccent,
                isSelected: selected,
                axis: axis,
                surface: .classification
            )
        }
        .buttonStyle(CurrentDriveButtonStyle())
        .accessibilityLabel(TripClassification.personal.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("currentDriveBarClassificationpersonal")
    }

    private func newLegButton(
        axis: CurrentDriveActionTile.Axis,
        maxWidth: CGFloat
    ) -> some View {
        Button(action: startNewLeg) {
            CurrentDriveActionTile(
                title: newLegJustStarted ? String(localized: "Started") : String(localized: "New Leg"),
                systemImage: newLegJustStarted
                    ? "checkmark"
                    : "point.bottomleft.forward.to.point.topright.scurvepath.fill",
                tint: .white,
                axis: axis
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .frame(maxWidth: maxWidth)
        .buttonStyle(CurrentDriveButtonStyle())
        .disabled(newLegJustStarted)
        .sensoryFeedback(.success, trigger: newLegJustStarted) { _, started in started }
        .accessibilityLabel("Start new leg")
        .accessibilityHint("Saves the drive so far and keeps recording as a new trip")
        .accessibilityIdentifier("currentDriveBarNewLeg")
    }

    private func feeButton(
        _ category: TripFeeCategory,
        systemImage: String,
        title: String,
        accessibilityTitle: String,
        identifier: String,
        axis: CurrentDriveActionTile.Axis
    ) -> some View {
        Button {
            onAddFee(category)
        } label: {
            CurrentDriveActionTile(
                title: title,
                systemImage: systemImage,
                tint: .white,
                symbolTint: MileageTheme.appTint,
                axis: axis
            )
        }
        .buttonStyle(CurrentDriveButtonStyle())
        .accessibilityLabel(accessibilityTitle)
        .accessibilityIdentifier(identifier)
    }

    private var statusLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: statusIcon)
                .font(.callout.bold())
                .foregroundStyle(vehicleColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(summary.phase.displayName)
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                Text(vehicleLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
            .frame(minHeight: 44)
            .contentShape(.rect)
    }

    private var vehicleLabel: String {
        summary.vehicle?.name ?? String(localized: "Choose vehicle")
    }

    private var statusIcon: String {
        VehicleAppearance.symbol(summary.vehicle?.symbolName)
    }

    private var vehicleColor: Color {
        VehicleAppearance.color(forHex: summary.vehicle?.colorHex)
    }

    private var lastMovementMetric: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Last movement")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.74))
            Text(summary.lastMovingAt ?? summary.startedAt, style: .relative)
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var distanceLabel: String {
        DistanceFormatting.label(meters: summary.distanceMeters, unit: model.distanceUnit)
    }

    private func startNewLeg() {
        guard !newLegJustStarted else { return }

        withAnimation(.snappy) {
            newLegJustStarted = true
        }
        onStartNewLeg()

        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) {
                newLegJustStarted = false
            }
        }
    }
}

extension View {
    /// Xcode 27 adds per-view App Entity annotations. Stable Xcode 26 builds
    /// retain the NSUserActivity grounding path so the same entity remains
    /// useful until the app is shipped with the iOS 27 SDK.
    @ViewBuilder
    func currentDriveEntityAnnotation(id: UUID, isEnabled: Bool) -> some View {
#if compiler(>=6.4)
        appEntityIdentifier(
            isEnabled
                ? EntityIdentifier(for: CurrentDriveAppEntity.self, identifier: id)
                : nil
        )
#else
        userActivity(
            "com.daviddegner.MileageTracker.viewingCurrentDrive",
            element: isEnabled ? id : nil
        ) { activeDriveID, activity in
            activity.title = String(localized: "Current Drive")
            activity.targetContentIdentifier = activeDriveID.uuidString
            activity.appEntityIdentifier = EntityIdentifier(
                for: CurrentDriveAppEntity.self,
                identifier: activeDriveID
            )
        }
#endif
    }
}
