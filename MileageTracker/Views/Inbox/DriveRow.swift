import AppCore
import SwiftUI

/// The one drive row. It renders identically in Need Review, inside a month,
/// and in All Trips — state is a dot and a glyph, never a different layout.
///
/// Two fixed identity cues lead one flexible summary column:
///   leading = STATE + MAP
///   summary = route, optional suggestion, then timeline + mileage
///
/// Maps at any real size and full evidence belong to the detail screen. The
/// thumbnail here is an identity cue, and a user note is only a one-line hint.
///
/// **Typography is deliberately tiny in vocabulary.** Two sizes, two weights,
/// three colour roles, and nothing else may be added without removing something:
///
///   size    `.body` identity · `.footnote` everything else
///   weight  `.bold` mileage · `.regular` everything else
///   colour  `.primary` route/value · `.secondary` context · accent = status
///
/// Origin and destination share one weight and colour — they are a single fact,
/// and the turn arrow says which end is which. Distance is the strongest value;
/// only a blocking preview receives semantic colour.
struct DriveRow: View {
    var trip: TripSummary
    var suggestion: TripClassificationSuggestion?
    var includesGenericReviewStatus = true
    var usesCompactLayout = false
    /// The row is showing in the reading pane AND the window is active — the
    /// blue-chip state. The chip behind it is drawn by `driveRowSelection` at
    /// the call site from the same derivation, so the two cannot disagree;
    /// this flag is what lets the text follow Mail's convention — on the
    /// emphasized blue chip every color yields to white, because colored text
    /// is illegible on a saturated fill and the reading pane is already
    /// carrying the row's classification vocabulary. On the inactive-window
    /// gray chip the normal colors stay, exactly as Mail keeps black text on
    /// its gray state.
    var isEmphasizedSelection: Bool = false

    @Environment(\.distanceUnit) private var distanceUnit
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var regularThumbnailSize: CGFloat = DriveMapThumbnailLayout.regularSize
    @ScaledMetric(relativeTo: .subheadline) private var compactThumbnailSize: CGFloat = DriveMapThumbnailLayout.compactSize
    /// Scales with the text: a fixed 15pt box clipped the glyph at accessibility
    /// sizes, where SF Symbols grow but the frame did not.
    @ScaledMetric(relativeTo: .footnote) private var stateGlyphSize: CGFloat = 15

    private var thumbnailSize: CGFloat {
        usesCompactLayout ? compactThumbnailSize : regularThumbnailSize
    }

    private var showsThumbnail: Bool {
        dynamicTypeSize < .accessibility3 && DriveCardMapThumbnail.hasMapContent(for: trip)
    }

    private var stacksVertically: Bool {
        dynamicTypeSize >= .accessibility1
    }

    private var secondaryTextStyle: AnyShapeStyle {
        isEmphasizedSelection ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        primaryRow
            .padding(.vertical, 1)
            // `.contain`, not `.combine`: combining flattens the row into a
            // single element, swallowing the row tap target and its addressable
            // route, suggestion, and distance children.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("driveCard")
    }

    private var primaryRow: some View {
        HStack(alignment: .top, spacing: stacksVertically ? 8 : 7) {
            stateColumn
            thumbnail
            summaryContent
        }
        // Rows without a map keep the same minimum height as rows with one;
        // accessibility-sized content can still grow beyond that baseline.
        .frame(minHeight: thumbnailSize, alignment: .top)
    }

    // MARK: - Zones

    /// Classification, or the engine's own flag. No unread dot and no hollow
    /// ring for unclassified: both read as selection checkboxes, and this column
    /// literally becomes one in Select mode. Unresolved is carried by the route
    /// line's weight instead — which is what Mail does with an unread sender.
    private var stateColumn: some View {
        Group {
            // The engine's attention flag is deliberately absent here. It is a
            // note about how the drive was recorded, not work for the user, and
            // showing it would put a warning above a decision already made. It
            // lives on Trip Detail.
            ClassificationIndicator(
                classification: trip.classification,
                tintOverride: isEmphasizedSelection ? .white : nil
            )
        }
        // Fixed size even when empty, so the map and text start at the same
        // place on every row whether or not the drive has been classified.
        .frame(width: stateGlyphSize, height: stateGlyphSize)
        .padding(.top, 3)
        .accessibilityHidden(true)
    }

    /// Carries the state the dot used to carry, since a bold weight is not
    /// something VoiceOver announces.
    private var stateAccessibilityLabel: String {
        var parts: [String] = []
        if trip.isUnresolved { parts.append(String(localized: "Needs review")) }
        parts.append(trip.classification?.displayName ?? String(localized: "Unclassified"))
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if showsThumbnail {
            DriveCardMapThumbnail(
                trip: trip,
                routeColor: MileageTheme.routeUIColor,
                minimumPointSize: CGSize(width: thumbnailSize, height: thumbnailSize),
                // The frame below is exact, so the thumbnail must not open a
                // GeometryReader to rediscover it — one per row in a lazy list.
                usesProposedSize: false
            )
            .frame(width: thumbnailSize, height: thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
        }
    }

    /// The same reading order as Trip Detail: route, advisory, then details.
    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(endpoints.origin)
                    .lineLimit(stacksVertically ? 2 : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    // The row's state rides here so VoiceOver announces it
                    // before the route.
                    .accessibilityLabel(stateAccessibilityLabel)

                if stacksVertically == false, let auxiliaryPreview {
                    auxiliaryPreviewLine(auxiliaryPreview)
                }
            }

            // Same weight and colour as the origin — the pair is one fact, and
            // the turn arrow is what says which end is which, not a weight
            // change. That also frees weight to mean only one thing in this
            // row: emphasis on the distance.
            Label {
                Text(endpoints.destination)
                    .lineLimit(stacksVertically ? 2 : 1)
                    .minimumScaleFactor(stacksVertically ? 1 : 0.88)
                    .truncationMode(.tail)
                    // The label goes on the Text, not on the enclosing Label.
                    // Labelling the wrapper turns the pair into one non-text
                    // element, and `staticTexts["Home → Client"]` — asserted by
                    // four suites — stops resolving.
                    .accessibilityLabel(DriveRouteLabelFormatter.label(for: trip))
                    .accessibilityIdentifier("driveRowRouteDestination")
            } icon: {
                Image(systemName: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(secondaryTextStyle)
                    .accessibilityHidden(true)
            }
            .labelStyle(.previewLine)

            if let suggestionPreview {
                suggestionBand(suggestionPreview)
            } else if stacksVertically, let auxiliaryPreview {
                auxiliaryPreviewLine(auxiliaryPreview)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Spacer(minLength: stacksVertically ? 2 : 0)

            detailsRow
        }
        .font(.body)
        .foregroundStyle(isEmphasizedSelection ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, minHeight: thumbnailSize, alignment: .topLeading)
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("driveRowIdentity")
    }

    @ViewBuilder
    private var detailsRow: some View {
        Group {
            if stacksVertically {
                VStack(alignment: .leading, spacing: 2) {
                    timelineText
                    distanceText
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    timelineText
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    distanceText
                }
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("driveRowTimelineMileageRow")
    }

    private var timelineText: some View {
        Group {
            if stacksVertically {
                Text(timelineLabel)
                    .lineLimit(2)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(timelineLabel).fixedSize()
                    Text(trip.startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .fixedSize()
                    Text(trip.startDate.formatted(.dateTime.month(.abbreviated).day()))
                        .lineLimit(1)
                }
            }
        }
            .monospacedDigit()
            .foregroundStyle(secondaryTextStyle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenTimelineLabel)
            .accessibilityIdentifier("driveRowTimeline")
    }

    /// Keep this as a raw Text: TripEditingUITests uses the visible distance
    /// string to prove a correction landed.
    private var distanceText: some View {
        Text(distanceLabel)
            .monospacedDigit()
            .fontWeight(.bold)
            .foregroundStyle(isEmphasizedSelection ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("driveRowDistance")
    }

    // MARK: - Content

    private var preview: DriveRowPreviewLine? {
        DriveRowPreviewLine.make(
            trip: trip,
            suggestion: suggestion,
            includesGenericReviewStatus: includesGenericReviewStatus
        )
    }

    private var suggestionPreview: DriveRowPreviewLine? {
        guard preview?.kind == .suggestion else { return nil }
        return preview
    }

    private var auxiliaryPreview: DriveRowPreviewLine? {
        guard let preview, preview.kind != .suggestion else { return nil }
        return preview
    }

    private func suggestionBand(_ preview: DriveRowPreviewLine) -> some View {
        TripSuggestionBand(
            preview: preview,
            accessibilityIdentifier: "tripSuggestionRow",
            foregroundOverride: isEmphasizedSelection ? .white : nil
        )
    }

    private func auxiliaryPreviewLine(_ preview: DriveRowPreviewLine) -> some View {
        Text(preview.text)
            .font(.footnote)
            .lineLimit(stacksVertically ? 2 : 1)
            .truncationMode(.tail)
            .accessibilityLabel(preview.accessibilityText)
            .accessibilityIdentifier("driveRowPreview")
            .foregroundStyle(
                isEmphasizedSelection
                    ? AnyShapeStyle(preview.kind == .note ? .white.opacity(0.8) : .white)
                    : AnyShapeStyle(preview.kind == .note ? Color.secondary : MileageTheme.attentionAccent)
            )
            .fixedSize(horizontal: preview.kind == .blocking && stacksVertically == false, vertical: false)
    }

    private var endpoints: (origin: String, destination: String) {
        DriveRouteLabelFormatter.compactEndpoints(for: trip)
    }

    private var timelineLabel: String {
        TripHierarchyPresentation.timelineLabel(
            startDate: trip.startDate,
            endDate: trip.endDate
        )
    }

    private var spokenTimelineLabel: String {
        let start = trip.startDate.formatted(.dateTime.month().day().year().hour().minute())
        let end = trip.endDate.formatted(.dateTime.month().day().year().hour().minute())
        let duration = DurationClock.durationLabel(from: trip.startDate, to: trip.endDate)
        return "\(start) to \(end), \(duration)"
    }

    private var distanceLabel: String {
        DistanceFormatting.label(meters: trip.reportableDistanceMeters, unit: distanceUnit)
    }

}

/// The shared advisory line used between a route and its details. Its width is
/// supplied by the surrounding text column, so copy length never changes the
/// row's alignment.
struct TripSuggestionBand: View {
    var preview: DriveRowPreviewLine
    var accessibilityIdentifier: String
    /// Overrides the classification color — the drive list's selected row
    /// whites the band out along with everything else on the blue chip.
    var foregroundOverride: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage = preview.systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }

            Text(verbatim: preview.inlineText)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(suggestionForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.accessibilityText)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var suggestionForeground: Color {
        if let foregroundOverride { return foregroundOverride }
        return switch preview.suggestedClassification {
        case .business:
            MileageTheme.businessSuggestionForeground
        case .personal:
            MileageTheme.personalSuggestionForeground
        case .notADrive, nil:
            MileageTheme.appTint
        }
    }
}

/// Icon hugging the text with no fixed icon column, so a preview line without a
/// symbol starts flush with the route above it.
private struct PreviewLineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private extension LabelStyle where Self == PreviewLineLabelStyle {
    static var previewLine: PreviewLineLabelStyle { PreviewLineLabelStyle() }
}

/// The trip list's selection chip, drawn behind a row that is showing in the
/// reading pane. Mail's two states exactly (David's call, 08-31): solid
/// accent blue while the window is active, solid gray when it is not — the
/// row's text follows via `DriveRow.isSelected`, white on blue and normal on
/// gray, so both states read as Mail's do.
///
/// Drawn *inside* the row rather than with `listRowBackground`: every row
/// carries leading and trailing swipe actions, and replacing the
/// UIKit-managed cell background is what breaks iOS 26's rounded-chip swipe
/// morph. That is a hard-won constraint, not a style.
///
/// The chip is a background expanded by NEGATIVE padding rather than an inset
/// that pushes the content in. Two reasons, both load-bearing: the row's
/// layout is completely unchanged, so selecting a row cannot shift anything
/// (three `TripEditingUITests` assert the row's internal frames to within a
/// few points), and no horizontal width is taken from a summary column that
/// already truncates in a narrow content column.
private struct DriveRowSelectionBackground: ViewModifier {
    var isSelected: Bool
    /// Window-active (derived once in the list's row builder, alongside the
    /// flag `DriveRow` styles its text with, so chip and text cannot
    /// disagree). Window-active is the nearest reliable stand-in for Mail's
    /// "the list is focused": nothing in these columns can hold real keyboard
    /// focus (the focus machinery ate the sidebar's clicks — see CLAUDE.md),
    /// which also rules out `ShapeStyle.selection`, whose emphasized form
    /// needs a focused ancestor and therefore rendered permanently
    /// washed-out gray here.
    var isEmphasized: Bool

    /// `systemBlue` rather than the app's orange tint: selection is platform
    /// chrome, not brand — every Mac list paints it in the system accent, and
    /// the user's actual macOS accent color is unreadable from a
    /// Designed-for-iPad process, so the default accent is the closest match.
    private var fill: Color {
        isEmphasized
            ? Color(uiColor: .systemBlue)
            : Color(uiColor: .systemGray4)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// Marks this drive row as the one open in the reading pane;
    /// `isEmphasized` is the window-active blue state.
    func driveRowSelection(isSelected: Bool, isEmphasized: Bool) -> some View {
        modifier(DriveRowSelectionBackground(isSelected: isSelected, isEmphasized: isEmphasized))
    }
}
