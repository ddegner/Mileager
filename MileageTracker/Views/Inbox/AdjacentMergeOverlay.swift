import AppCore
import SwiftUI

/// The floating merge control that straddles the boundary between two adjacent
/// drives that are really one drive.
///
/// It came back after the Mail redesign retired it, in a smaller form: a single
/// `link` glyph in a circular glass button pinned to the right of the row
/// boundary, rather than the 140pt "Merge" capsule centred across the list. The
/// affordance earns its place — splitting one drive into two is the engine's
/// most common visible mistake, and fixing it from the list is one tap versus
/// select-two-then-menu — but it no longer sits in the middle of the route text
/// it is meant to be commenting on.
///
/// Eligibility is still `AdjacentMergeOverlayVisibility` over `TripMergePolicy`;
/// this file only draws it.
struct AdjacentMergeBoundary: Identifiable {
    struct ID: Hashable {
        var firstTripID: UUID
        var secondTripID: UUID

        var accessibilityIdentifier: String {
            "mergeAdjacentTripsButton.\(firstTripID.uuidString).\(secondTripID.uuidString)"
        }
    }

    var firstTripID: UUID
    var secondTripID: UUID
    var firstRouteLabel: String
    var secondRouteLabel: String
    var anchor: Anchor<CGRect>

    var id: ID {
        ID(firstTripID: firstTripID, secondTripID: secondTripID)
    }
}

struct AdjacentMergeBoundaryPreferenceKey: PreferenceKey {
    static let defaultValue: [AdjacentMergeBoundary] = []

    static func reduce(
        value: inout [AdjacentMergeBoundary],
        nextValue: () -> [AdjacentMergeBoundary]
    ) {
        value.append(contentsOf: nextValue())
    }
}

struct AdjacentMergeGlassButton: View {
    static let minimumHitTarget: CGFloat = 44

    var pairID: AdjacentMergeBoundary.ID
    var firstRouteLabel: String
    var secondRouteLabel: String
    var action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var diameter: CGFloat = 34

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MileageTheme.appTint)
                .frame(width: diameter, height: diameter)
                // The glass sits *behind* the glyph and is faded on its own, so
                // the disc reads as a lens over the row text while the tinted
                // link stays at full strength. Fading the whole button instead
                // would wash out the only part that carries the affordance.
                .background {
                    Color.clear
                        .glassEffect(.clear.interactive(), in: .circle)
                        .opacity(0.5)
                }
        }
        // Keep the understated 34pt glass disc, but give the Button itself the
        // full system-sized interaction target.
        .frame(
            minWidth: Self.minimumHitTarget,
            minHeight: Self.minimumHitTarget
        )
        .contentShape(.circle)
        .buttonStyle(.plain)
        .accessibilityLabel("Merge")
        .accessibilityHint("Merges \(firstRouteLabel) with \(secondRouteLabel).")
        .accessibilityIdentifier(pairID.accessibilityIdentifier)
        .zIndex(1)
    }
}

/// Every displayed boundary offers Merge, including across month headers.
/// Select mode and multiple selection reserve the trailing lane for selection.
enum AdjacentMergeOverlayVisibility {
    static func canShow(
        isEditing: Bool,
        canMerge: Bool
    ) -> Bool {
        !isEditing && canMerge
    }
}
