import AppCore
import SwiftUI

/// Keeps the current vehicle within reach while the full driving controls are hidden.
struct CurrentDriveMinimizedButton: View {
    @Environment(MileageAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var summary: CurrentDriveSummary
    var onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: VehicleAppearance.symbol(summary.vehicle?.symbolName))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(VehicleAppearance.color(forHex: summary.vehicle?.colorHex))
                .symbolEffect(
                    .pulse.wholeSymbol,
                    options: .repeating.speed(0.35),
                    isActive: !reduceMotion && scenePhase == .active
                )
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .clear.tint(.black.opacity(0.70)).interactive(),
            in: .circle
        )
        .accessibilityLabel("Show current trip controls")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("currentDriveBarExpand")
        .currentDriveEntityAnnotation(
            id: summary.pendingTripID,
            isEnabled: model.siriIndexingEnabled
        )
    }

    private var accessibilityValue: String {
        [
            CurrentDriveDisplay.vehicleName(summary.vehicle?.name),
            summary.phase.displayName,
            summary.classification?.displayName ?? String(localized: "Unclassified")
        ].joined(separator: ", ")
    }
}
