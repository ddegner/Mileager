import Foundation

/// Odometer readings as user-visible text. Storage is always miles; callers
/// pass a value already converted to the display unit.
enum OdometerFormatting {
    /// Bare reading number ("12,345.6") — decimal style, at most one
    /// fraction digit. Callers append the unit symbol where the layout
    /// wants one.
    static func readingText(_ displayValue: Double) -> String {
        formatter.string(from: NSNumber(value: displayValue)) ?? "\(displayValue)"
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}
