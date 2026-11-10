import ActivityKit
import AppCoreModels
import MileageActivityAttributes
import SwiftUI
import WidgetKit

@main
struct MileageTrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MileageDriveActivityWidget()
    }
}

struct MileageDriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MileageDriveActivityAttributes.self) { context in
            DriveLockScreenView(tripID: context.attributes.pendingTripID, state: context.state)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(deepLinkURL(for: context.attributes.pendingTripID))
        } dynamicIsland: { context in
            let tripID = context.attributes.pendingTripID
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        vehicleLink(tripID: tripID, state: context.state)
                        // Glyph-only unconditionally: the leading region is
                        // roughly 100pt wide, with no room for a label.
                        ClassificationChip(
                            classification: context.state.classificationValue,
                            showsTitle: false
                        )
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.distanceLabel)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    statusTiming(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The Dynamic Island keeps `.bordered` rather than the Lock
                    // Screen's tile: it is its own chrome, bordered is the native
                    // affordance here, and the expanded presentation has its own
                    // height ceiling that three 52pt tiles would threaten.
                    HStack(spacing: 8) {
                        feeButton(tripID: tripID, category: .toll)
                        feeButton(tripID: tripID, category: .parking)
                        newLegButton(tripID: tripID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption2.weight(.semibold))
                }
            } compactLeading: {
                Self.vehicleIcon(state: context.state)
            } compactTrailing: {
                Text(context.state.distanceLabel)
                    .font(.caption2.monospacedDigit())
                    .minimumScaleFactor(0.8)
            } minimal: {
                Self.vehicleIcon(state: context.state)
            }
            .widgetURL(deepLinkURL(for: tripID))
        }
        .supplementalActivityFamilies([.small])
    }

    private func deepLinkURL(for pendingTripID: UUID) -> URL? {
        DeepLinkRoute.currentDrive(tripID: pendingTripID).url
    }

    private func feeButton(tripID: UUID, category: TripFeeCategory) -> some View {
        Link(destination: DeepLinkRoute.currentDriveFee(tripID: tripID, category: category).url) {
            Label(category.displayName, systemImage: category.symbolName)
        }
        .accessibilityLabel(Text(category.addActionName))
    }

    private func newLegButton(tripID: UUID) -> some View {
        Link(destination: DeepLinkRoute.currentDriveNewLeg(tripID: tripID).url) {
            Label(
                CurrentDriveSummary.Strings.newLeg,
                systemImage: MileageDriveActivityWidget.newLegSymbolName
            )
        }
        .accessibilityLabel(Text(CurrentDriveSummary.Strings.startNewLeg))
    }

    private func vehicleLink(tripID: UUID, state: MileageDriveActivityAttributes.ContentState) -> some View {
        Link(destination: DeepLinkRoute.currentDriveVehicle(tripID: tripID).url) {
            HStack(spacing: 5) {
                Self.vehicleIcon(state: state)
                Text(state.vehicleDisplayName)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(CurrentDriveSummary.Strings.vehicle))
        .accessibilityValue(Text(state.vehicleDisplayName))
    }

    private func statusTiming(state: MileageDriveActivityAttributes.ContentState) -> some View {
        VStack(spacing: 2) {
            Text(state.phase.displayName)
                .font(.caption.weight(.semibold))
            if state.phase == .confirmingTripEnd {
                HStack(spacing: 3) {
                    Text(CurrentDriveSummary.Strings.lastMovement)
                    Text(state.lastMovingAt ?? state.startedAt, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text(state.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Matches the live drive bar's New Leg glyph.
    static let newLegSymbolName = "point.bottomleft.forward.to.point.topright.scurvepath.fill"

    static func vehicleIcon(state: MileageDriveActivityAttributes.ContentState) -> some View {
        Image(systemName: state.vehicleSymbolName)
            .foregroundStyle(Color(vehicleHex: state.vehicle?.colorHex))
    }
}

// MARK: - Lock Screen

private struct DriveLockScreenView: View {
    var tripID: UUID
    var state: MileageDriveActivityAttributes.ContentState

    @Environment(\.activityFamily) private var activityFamily
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if activityFamily == .small {
            smallStrip
        } else if dynamicTypeSize.isAccessibilitySize {
            accessibleLayout
        } else {
            standardLayout
        }
    }

    // MARK: Standard

    /// The Lock Screen's answer to `CurrentDriveGlassBar`: a status header over
    /// one row of action tiles.
    ///
    /// Only one tile row fits. Apple may truncate a Lock Screen Live Activity
    /// past 160pt, and truncation cuts from the bottom — it would silently
    /// delete the controls. The 44pt header, 8pt gap, 52pt tiles and 14pt
    /// outer margins use 132pt at the default text size.
    private var standardLayout: some View {
        VStack(spacing: 8) {
            // `ViewThatFits` wraps the whole row rather than just the chip: a
            // bare chip inside an HStack gets an ambiguous width proposal,
            // while the row gets a definite one from the container. If neither
            // fits, the last child — glyph-only — renders, which is correct.
            ViewThatFits(in: .horizontal) {
                headerRow(showsChipTitle: true)
                headerRow(showsChipTitle: false)
            }

            HStack(spacing: 8) {
                feeTile(.toll)
                feeTile(.parking)
                newLegTile
            }
        }
        .foregroundStyle(.primary)
        // ActivityConfiguration does not supply a widget's content margins.
        // Inset both rows from the Lock Screen container's rounded edges.
        .padding(14)
    }

    private func headerRow(showsChipTitle: Bool) -> some View {
        HStack(spacing: 6) {
            vehicleLink
            ClassificationChip(
                classification: state.classificationValue,
                showsTitle: showsChipTitle
            )

            Spacer(minLength: 0)

            Divider().frame(height: 30)
            distanceMetric
            Divider().frame(height: 30)
            elapsedMetric
        }
        .lineLimit(1)
        .minimumScaleFactor(0.60)
    }

    private var vehicleLink: some View {
        // The whole label is the target, not just the glyph. "Choose vehicle"
        // is the Lock Screen's most important call to action and used to sit
        // outside the Link entirely.
        Link(destination: DeepLinkRoute.currentDriveVehicle(tripID: tripID).url) {
            HStack(spacing: 7) {
                Image(systemName: state.vehicleSymbolName)
                    .font(.callout.bold())
                    .foregroundStyle(Color(vehicleHex: state.vehicle?.colorHex))

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.phase.displayName)
                        .font(.callout.bold())
                    Text(state.vehicleDisplayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(CurrentDriveSummary.Strings.vehicle))
        .accessibilityValue(Text(state.vehicleDisplayName))
    }

    /// Values only, with the titles as accessibility labels — matching
    /// `CurrentDriveLiveMetric`, which never renders its own title. That is
    /// what keeps the header to a single 44pt row.
    private var distanceMetric: some View {
        Text(state.distanceLabel)
            .font(.callout.bold().monospacedDigit())
            .layoutPriority(1)
            .accessibilityLabel(Text(CurrentDriveSummary.Strings.distance))
            .accessibilityValue(Text(state.distanceLabel))
    }

    @ViewBuilder
    private var elapsedMetric: some View {
        if state.phase == .confirmingTripEnd {
            // "Last movement" plus a relative time is the widest thing this slot
            // ever holds, and it coincides with the longest phase string. The
            // word drops before the number does; the label keeps it for VoiceOver.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(CurrentDriveSummary.Strings.lastMovement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    lastMovementValue
                }
                lastMovementValue
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(CurrentDriveSummary.Strings.lastMovement))
        } else {
            Text(state.startedAt, style: .timer)
                .font(.callout.bold().monospacedDigit())
                .layoutPriority(1)
                .accessibilityLabel(Text(CurrentDriveSummary.Strings.elapsed))
        }
    }

    private var lastMovementValue: some View {
        Text(state.lastMovingAt ?? state.startedAt, style: .relative)
            .font(.callout.bold().monospacedDigit())
    }

    private func feeTile(_ category: TripFeeCategory) -> some View {
        Link(destination: DeepLinkRoute.currentDriveFee(tripID: tripID, category: category).url) {
            ActivityActionTile(
                title: category.displayName,
                systemImage: category.symbolName
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(category.addActionName))
    }

    private var newLegTile: some View {
        Link(destination: DeepLinkRoute.currentDriveNewLeg(tripID: tripID).url) {
            ActivityActionTile(
                title: CurrentDriveSummary.Strings.newLeg,
                systemImage: MileageDriveActivityWidget.newLegSymbolName
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(CurrentDriveSummary.Strings.startNewLeg))
    }

    // MARK: Accessibility sizes

    /// At accessibility type sizes a three-up tile row cannot fit at any scale
    /// factor, and keeping it would guarantee truncation — which cuts from the
    /// bottom, deleting the controls *and* eating the metrics. Dropping the row
    /// and clamping is the honest version of the same outcome: status stays
    /// legible at the user's chosen size, and the whole-activity `widgetURL`
    /// still opens the app, where full-size controls live.
    private var accessibleLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: state.vehicleSymbolName)
                    .foregroundStyle(Color(vehicleHex: state.vehicle?.colorHex))
                Text(state.phase.displayName)
                ClassificationChip(classification: state.classificationValue, showsTitle: false)
            }
            HStack(spacing: 6) {
                Text(state.distanceLabel)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                if state.phase == .confirmingTripEnd {
                    Text(state.lastMovingAt ?? state.startedAt, style: .relative)
                } else {
                    Text(state.startedAt, style: .timer)
                }
            }
            .monospacedDigit()
        }
        .font(.callout.bold())
        .lineLimit(1)
        .minimumScaleFactor(0.70)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dynamicTypeSize(...DynamicTypeSize.accessibility4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(state.vehicleDisplayName))
    }

    // MARK: Small (CarPlay + Apple Watch Smart Stack)

    /// Deliberately control-free and structurally unchanged: CarPlay deactivates
    /// interactive elements, and Apple's guidance is to prefer timely content
    /// over buttons where people may be driving.
    private var smallStrip: some View {
        HStack(spacing: 6) {
            Link(destination: DeepLinkRoute.currentDriveVehicle(tripID: tripID).url) {
                MileageDriveActivityWidget.vehicleIcon(state: state)
            }
            .buttonStyle(.plain)
            Text(state.phase.displayName)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Text(state.distanceLabel)
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(.primary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Components

/// The Live Activity's answer to `CurrentDriveActionTile`.
///
/// Same shape language as the bar — rounded rect, hairline border, glyph over
/// title, brand-tinted symbol — but rendered in system-adaptive terms. The bar's
/// literal white on tinted glass only reads against its own dark panel, and this
/// surface deliberately paints no panel of its own.
private struct ActivityActionTile: View {
    var title: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(Color.mileageAppTint)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.60)
        .padding(.horizontal, 4)
        // Fixed, never `@ScaledMetric`: the bar's 60pt scaled height becomes
        // ~187pt at AX5 — one tile taller than the entire permitted activity.
        // 52pt clears the 44pt tap minimum by 8pt.
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(.primary)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(.rect(cornerRadius: 14))
    }
}

/// Display-only badge for the drive's classification.
///
/// The payload has always carried `classification` — and `LiveActivityController`
/// has always spent an ActivityKit push when it changed — but nothing rendered
/// it. Not a control: the Lock Screen's one action row is Toll/Parking/New Leg.
private struct ClassificationChip: View {
    var classification: TripClassification?
    var showsTitle: Bool

    var body: some View {
        if let classification, let symbolName = classification.symbolName {
            let accent = Color.mileageAccent(for: classification)
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                if showsTitle {
                    Text(classification.displayName)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, showsTitle ? 7 : 5)
            .padding(.vertical, 3)
            .background(accent.opacity(0.15), in: .capsule)
            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(classification.displayName))
        }
    }
}

// MARK: - Colors

private extension Color {
    /// Brand tint. Mirrors `MileageTheme.appTint`, which lives in the app target
    /// and imports UIKit, so the extension cannot see it; the asset catalog does
    /// the light/dark resolution instead.
    static let mileageAppTint = Color("AppTint")

    static func mileageAccent(for classification: TripClassification) -> Color {
        switch classification {
        case .business: Color("BusinessAccent")
        case .personal: Color("PersonalAccent")
        case .notADrive: Color("AppTint")
        }
    }

    /// The vehicle's colour, falling back to the brand tint exactly as
    /// `VehicleAppearance.color(forHex:)` does in the app. Before this the
    /// widget fell back to green/grey, so the same car rendered two colours.
    init(vehicleHex hex: String?) {
        guard let components = VehiclePalette.components(forHex: hex) else {
            self = .mileageAppTint
            return
        }
        self.init(red: components.red, green: components.green, blue: components.blue)
    }
}
