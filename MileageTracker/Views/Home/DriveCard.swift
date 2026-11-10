import AppCore
import SwiftUI

/// The classification convention, carried by glyph so it survives without color:
/// Business is a green briefcase, Personal a red person. Unclassified stays a
/// neutral hollow ring so only resolved trips read as a colored icon.
struct ClassificationIndicator: View {
    var classification: TripClassification?
    /// Replaces the glyph's semantic color — the drive list's selected row
    /// whites the glyph out on Mail's blue chip. The briefcase/person/nosign
    /// shapes carry the meaning without the color, by design.
    var tintOverride: Color? = nil

    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 14

    var body: some View {
        shape
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var shape: some View {
        switch classification {
        case .business:
            icon("briefcase.fill", tint: tintOverride ?? MileageTheme.businessAccent)
        case .personal:
            icon("person.fill", tint: tintOverride ?? MileageTheme.personalAccent)
        case .notADrive:
            icon("nosign", tint: tintOverride ?? Color.secondary)
        case nil:
            // Blank, but still occupying the column. A hollow ring here read as
            // an unselected checkbox — the one thing this column must never look
            // like, since it really does become a selection circle in Select
            // mode. Unclassified is conveyed by the row's heavier destination
            // text instead.
            //
            // `Color.clear`, not `EmptyView`: modifiers applied to an EmptyView
            // are discarded, so the frame below would collapse and every row
            // without an icon would start further left than its neighbours.
            Color.clear
        }
    }

    private func icon(_ systemName: String, tint: some ShapeStyle) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(tint)
    }

    private var accessibilityLabel: String {
        switch classification {
        case .business: String(localized: "Business")
        case .personal: String(localized: "Personal")
        case .notADrive: String(localized: "Not a Drive")
        case nil: String(localized: "Unclassified")
        }
    }
}
