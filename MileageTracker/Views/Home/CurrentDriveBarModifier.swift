import AppCore
import SwiftUI

/// Docks the live drive bar to a scrollable screen's bottom safe area.
///
/// Applied per-list rather than hoisted onto the `NavigationStack`: inset
/// propagation into pushed destinations is not something this app has ever
/// relied on, and hoisting would also put the bar over Trip Detail, where it
/// would collide with that screen's own bottom bar and publish a second
/// simultaneous Siri entity annotation.
///
/// The bar is a compose session, not a list control — the one standing
/// exemption from the no-bespoke-floating-furniture rule. Capture outranks the
/// metaphor: it keeps its slot on every screen that lists drives.
struct CurrentDriveBarModifier: ViewModifier {
    @Environment(MileageAppModel.self) private var model
    /// Multi-select owns the bottom bar while it is active, exactly as before.
    var suppressed: Bool
    @Binding var isMinimized: Bool
    /// Supplied by the root, which owns every modal — the fee sheet and the
    /// vehicle dialog must stay on one presenter so the deep-link gates
    /// (`appLock == .unlocked` **and** a matching `pendingTripID`) keep working.
    var onAddFee: (TripFeeCategory) -> Void
    var onChooseVehicle: () -> Void
    /// The purpose editor is attached to this bar, but the root still needs its
    /// presentation state to serialize deferred Live Activity requests.
    @Binding var isPresentingPurposeEditor: Bool

    /// Keep the active scrolling content at one structural identity while the
    /// controls are minimized. Suppressed screens must omit the inset entirely
    /// so a pushed list never inherits a second bottom-toolbar hosting view.
    @ViewBuilder
    func body(content: Content) -> some View {
        if let currentDrive = model.currentDrive, !suppressed {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if !isMinimized {
                    CurrentDriveGlassBar(
                        summary: currentDrive,
                        onSelectClassification: { model.setCurrentDriveClassification($0) },
                        onAddFee: onAddFee,
                        onStartNewLeg: { model.startNewLegNow() },
                        onChooseVehicle: onChooseVehicle,
                        onMinimize: { isMinimized = true },
                        isPresentingPurposeEditor: $isPresentingPurposeEditor
                    )
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func currentDriveBar(
        suppressed: Bool = false,
        isMinimized: Binding<Bool>,
        isPresentingPurposeEditor: Binding<Bool>,
        onAddFee: @escaping (TripFeeCategory) -> Void,
        onChooseVehicle: @escaping () -> Void
    ) -> some View {
        modifier(CurrentDriveBarModifier(
            suppressed: suppressed,
            isMinimized: isMinimized,
            onAddFee: onAddFee,
            onChooseVehicle: onChooseVehicle,
            isPresentingPurposeEditor: isPresentingPurposeEditor
        ))
    }
}
