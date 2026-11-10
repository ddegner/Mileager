import AppCore
import SwiftUI

/// A caption in the space exposed by the List's own top bounce. It never
/// changes scroll offsets/insets, installs a gesture, or starts refresh work.
struct TripPullCaption: ViewModifier {
    private let amount: String
    private let distance: String
    private let count: Int
    private let spokenTotal: String
    private let isEnabled: Bool
    private let toolbarBottom: CGFloat?
    private let controlsBottom: CGFloat?
    @State private var pullDistance: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.sidebarUnderlap) private var sidebarUnderlap

    init(rollup: ReportRollupDisplay?, currencyCode: String,
         distanceUnit: DistanceUnit, toolbarBottom: CGFloat?, controlsBottom: CGFloat?,
         isEnabled: Bool = true) {
        // Calculate and format once when the owning list's data changes.
        // The bounce state below only repositions this prepared caption.
        let amount = CurrencyFormatting.label(rollup?.totalReimbursement ?? 0, code: currencyCode)
        let meters = DistanceConversion.meters(fromMiles: rollup?.businessMiles ?? 0)
        let fullDistance = DistanceFormatting.label(meters: meters, unit: distanceUnit)
        let count = rollup?.businessDriveCount ?? 0
        self.amount = amount
        self.distance = Measurement(
            value: DistanceConversion.value(meters: meters, in: distanceUnit),
            unit: distanceUnit.unitLength
        ).formatted(.measurement(width: .wide, usage: .asProvided,
                                 numberFormatStyle: .number.precision(.fractionLength(0...1))))
        self.count = count
        self.spokenTotal = String(localized: "\(amount) for \(fullDistance) in \(count) business trips")
        self.isEnabled = isEnabled
        self.toolbarBottom = toolbarBottom
        self.controlsBottom = controlsBottom
    }

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .scrollBounceBehavior(.always, axes: .vertical)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, -(geometry.contentOffset.y + geometry.contentInsets.top)).rounded()
                } action: { _, distance in
                    pullDistance = distance
                }
                .overlay(alignment: .top) {
                    GeometryReader { geometry in
                        // A List's safe-area top is BELOW the large title.
                        // The bounce opens ABOVE it, below the fixed toolbar.
                        // Measure that toolbar instead of assuming a title or
                        // status-bar height (which changes with device/type).
                        let origin = geometry.frame(in: .global).minY
                        let restingTop = toolbarBottom.map { $0 + 8 } ?? origin
                        // Search's scope picker stays fixed while the title
                        // bounces. Only use the part of the gap it leaves clear.
                        let top = max(restingTop, controlsBottom ?? restingTop)
                        let height = max(0, pullDistance - (top - restingTop))
                        caption
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .background { recessedBackground }
                            .clipped()
                            // The List consumes this safe area as scroll margins;
                            // its non-scrolling caption needs the same clearance.
                            .padding(.leading, sidebarUnderlap)
                            .opacity(min(1, height / 32))
                            .offset(y: top - origin)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .accessibilityCustomContent(Text("Total reimbursement"), Text(verbatim: spokenTotal))
        } else {
            content
        }
    }

    private var recessedBackground: some View {
        MileageTheme.tripPullBackground
            .overlay(alignment: .top) {
                edgeShadow(from: .top)
            }
            .overlay(alignment: .bottom) {
                edgeShadow(from: .bottom)
            }
            .clipped()
    }

    private func edgeShadow(from edge: VerticalEdge) -> some View {
        // Keep each casting surface outside the exposed area, leaving only
        // its soft shadow on the background between the two foreground edges.
        Rectangle()
            .fill(.black)
            .frame(height: 16)
            .shadow(color: .black.opacity((colorScheme == .dark ? 0.65 : 0.18)
                                         * (edge == .bottom ? 0.25 : 1)),
                    radius: 6, y: edge == .top ? 3 : -3)
            .offset(y: edge == .top ? -16 : 16)
    }

    private var caption: some View {
        Text("\(Text(amount).bold())\n\(distance)\n\(count) business trips")
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(MileageTheme.businessSuggestionForeground)
            // The outer frame centers the block; each line shares its left edge.
            .multilineTextAlignment(.leading)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
            .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.8)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("tripPullCaption")
    }
}
