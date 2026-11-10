import SwiftUI
import UIKit

enum MileageTheme {
    static let fontDesign: Font.Design = .default

    // One radius for every custom-drawn card so hand-built cards read as the
    // same panel system as the inset-grouped rows they sit beside.
    static let cardCornerRadius: CGFloat = 26

    // 7-Eleven palette. Orange is the brand tint for interactive chrome; green and
    // red are reserved for meaning (business / personal classification + route).
    static let appTint = adaptiveColor(
        light: (0.95, 0.44, 0.13),
        dark: (1.00, 0.56, 0.26)
    )
    static let businessAccent = adaptiveColor(
        light: (0.00, 0.55, 0.30),
        dark: (0.30, 0.82, 0.52)
    )
    // Stays in the green "business" family while reading as a distinct stop
    // on the two-level review swipe.
    static let businessSecondaryAccent = adaptiveColor(
        light: (0.00, 0.42, 0.48),
        dark: (0.22, 0.66, 0.70)
    )
    static let personalAccent = adaptiveColor(
        light: (0.85, 0.14, 0.15),
        dark: (1.00, 0.42, 0.42)
    )
    // Suggestions carry classification with text rather than a filled badge.
    // The light-mode green is slightly deeper than the primary business accent
    // so small, thin type remains readable on the list's pale canvas.
    static let businessSuggestionForeground = adaptiveColor(
        light: (0.00, 0.51, 0.28),
        dark: (0.30, 0.82, 0.52)
    )
    // The canvas uncovered by the trip list's native top bounce.
    static let tripPullBackground = adaptiveColor(
        light: (1.00, 0.985, 0.95),
        dark: (0.075, 0.225, 0.16)
    )
    static let personalSuggestionForeground = adaptiveColor(
        light: (0.85, 0.14, 0.15),
        dark: (1.00, 0.42, 0.42)
    )
    // The engine's own flag. Distinct from `appTint` orange so a warning never
    // reads as an interactive control, and carried by the triangle glyph so it
    // survives without colour.
    static let attentionAccent = adaptiveColor(
        light: (0.85, 0.48, 0.00),
        dark: (0.98, 0.68, 0.24)
    )
    // The route line, on every map the app draws.
    static let routeUIColor = adaptiveUIColor(
        light: (0.95, 0.44, 0.13),
        dark: (1.00, 0.56, 0.26)
    )

    // The grouped canvas behind cards/rows. A soft neutral grey in light mode —
    // kept light and airy, but deep enough that the white cards/rows read as
    // distinct panels on top; dark mode keeps the system colour.
    static let groupedBackgroundUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGroupedBackground
            : UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1)
    }
    static let groupedBackground = Color(uiColor: groupedBackgroundUIColor)

    // Trips is a plain, edge-to-edge list, so use the platform's standard white
    // surface in light mode. Preserve the slightly lifted dark canvas so maps,
    // glass controls, and review rows retain their existing dark-mode contrast.
    static let tripsListBackgroundUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.05, blue: 0.06, alpha: 1)
            : UIColor.systemBackground
    }
    static let tripsListBackground = Color(uiColor: tripsListBackgroundUIColor)

    static let settingsGroupedBackgroundUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.14, blue: 0.15, alpha: 1)
            : UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1)
    }
    static let settingsGroupedBackground = Color(uiColor: settingsGroupedBackgroundUIColor)

    static func adaptiveColor(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(uiColor: adaptiveUIColor(light: light, dark: dark))
    }

    static func adaptiveUIColor(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> UIColor {
        UIColor { traits in
            let values = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: values.0, green: values.1, blue: values.2, alpha: 1)
        }
    }
}

extension View {
    func mileageAppTheme() -> some View {
        tint(MileageTheme.appTint)
            .fontDesign(MileageTheme.fontDesign)
    }

    /// Replaces the default system grouped background of a List/Form with the
    /// app's lighter grouped canvas. Apply to each scrollable screen root.
    ///
    /// Also paints the enclosing sheet, when there is one, with the same canvas.
    /// Without this, detent sheets (Toll/Parking fee entry, the Business Drive
    /// purpose sheet) expose the default system sheet background around the form
    /// while being dragged between detents or rubber-banded. On screens that
    /// aren't presented, `presentationBackground` has no effect.
    func mileageGroupedBackground(_ canvas: Color = MileageTheme.groupedBackground) -> some View {
        scrollContentBackground(.hidden)
            .background(canvas)
            .presentationBackground(canvas)
    }

    /// List separators align to a row's first *text*, so a row that leads with
    /// an icon, spinner, or custom control gets a line that starts part-way
    /// across. Pin the separator to the row's leading edge instead, matching
    /// plain-text rows, for uniform full-width lines within a section.
    func fullWidthListRowSeparator() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    /// Makes standalone empty-state artwork read as pressed into its canvas.
    /// Keep this shared: every screen whose content is replaced by an empty
    /// message should use the same light/dark letterpress treatment.
    func mileageEmptyStateEmbossed() -> some View {
        modifier(MileageEmptyStateEmbossModifier())
    }
}

/// The one presentation for a standalone view or collection with no content.
/// Its symbol and title are the same pressed letterpress used by Caught Up;
/// explanatory copy stays conventionally secondary and actions stay tinted so
/// neither is mistaken for disabled content.
struct EmbossedEmptyState<Actions: View>: View {
    private let title: Text
    private let systemImage: String
    private let description: Text?
    private let actions: Actions

    @ScaledMetric(relativeTo: .title3) private var symbolSize: CGFloat = 40

    init(
        title: Text,
        systemImage: String,
        description: Text? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: symbolSize, weight: .medium))
                    .accessibilityHidden(true)

                title
                    .font(.title3.weight(.semibold))
            }
            .mileageEmptyStateEmbossed()

            if let description {
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            actions
        }
        .multilineTextAlignment(.center)
        .padding()
        // Preserve child text and buttons while letting call-site identifiers
        // continue to identify the empty-state container in UI automation.
        .accessibilityElement(children: .contain)
    }
}

extension EmbossedEmptyState where Actions == EmptyView {
    init(title: Text, systemImage: String, description: Text? = nil) {
        self.init(
            title: title,
            systemImage: systemImage,
            description: description,
            actions: { EmptyView() }
        )
    }
}

private struct MileageEmptyStateEmbossModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.foregroundStyle(letterpress)
    }

    /// Light comes from above, so a recess has its top interior wall in shadow
    /// and its bottom interior wall catching the light. On black, an exterior
    /// white rim reads as raised, so both highlights stay inside the glyph.
    private var letterpress: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(white: 0.19)
                    .shadow(.inner(color: .black.opacity(0.65), radius: 1.5, y: 1))
                    .shadow(.inner(color: .white.opacity(0.22), radius: 1, y: -1))
            )
        }
        return AnyShapeStyle(
            Color(.systemGray4)
                .shadow(.inner(color: .black.opacity(0.35), radius: 1, y: 1))
                .shadow(.drop(color: .white.opacity(0.5), radius: 0.5, y: 1))
        )
    }
}
