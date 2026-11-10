import SwiftUI

/// The app's single custom flourish. A small abstract clock: an open circle with a
/// solid pie wedge. The wedge's leading edge marks the drive's start on a 12-hour
/// dial (12 o'clock top, clockwise); its sweep shows how long the drive lasted.
///
/// It is a feel-level glyph, not a record — it cannot express a.m./p.m. or exact
/// minutes, by design. Precise times live on the detail screen. The accessibility
/// label carries the real duration so VoiceOver loses nothing.
struct DurationClock: View {
    var startDate: Date
    var endDate: Date

    private static let minimumVisibleSweepDegrees = 18.0
    private static let ringLineWidth: CGFloat = 1.25

    @ScaledMetric(relativeTo: .callout) private var diameter: CGFloat = 17

    /// Defaults match the detail treatment; compact list rows can render the
    /// same glyph smaller, scaled against their text.
    init(
        startDate: Date,
        endDate: Date,
        diameter: CGFloat = 17,
        relativeTo textStyle: Font.TextStyle = .callout
    ) {
        self.startDate = startDate
        self.endDate = endDate
        _diameter = ScaledMetric(wrappedValue: diameter, relativeTo: textStyle)
    }

    private var startAngle: Angle {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: startDate)
        let minutesIntoHalfDay = Double((comps.hour ?? 0) % 12) * 60 + Double(comps.minute ?? 0)
        // 12 o'clock is -90° in the standard atan2 frame; 720 min = full turn.
        return .degrees(minutesIntoHalfDay / 720 * 360 - 90)
    }

    private var sweep: Angle {
        let minutes = max(0, endDate.timeIntervalSince(startDate) / 60)
        // Cap a hair under a full turn so a long haul never reads as an empty dial.
        let capped = min(minutes, 711)
        // Very short drives otherwise collapse to a hairline at card size.
        let visibleDegrees = max(Self.minimumVisibleSweepDegrees, capped / 720 * 360)
        return .degrees(visibleDegrees)
    }

    var body: some View {
        Canvas { context, size in
            let inset = max(Self.ringLineWidth / 2, 1)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2

            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: startAngle + sweep,
                clockwise: false
            )
            wedge.closeSubpath()
            context.fill(wedge, with: .style(.primary))

            let ring = Path(ellipseIn: rect)
            context.stroke(ring, with: .style(.primary), lineWidth: Self.ringLineWidth)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(durationAccessibilityLabel)
    }

    private var durationAccessibilityLabel: String {
        Self.durationLabel(from: startDate, to: endDate)
    }

    /// Spoken duration ("22 minutes", "1 hour, 5 minutes"). Shared so the drive
    /// card can fold the same phrasing into its combined accessibility label.
    static func durationLabel(from startDate: Date, to endDate: Date) -> String {
        let seconds = max(0, endDate.timeIntervalSince(startDate))
        let minutes = Int((seconds / 60).rounded())
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) minutes"
    }
}
