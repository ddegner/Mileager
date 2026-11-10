import Foundation

/// Straight RGB components in the 0...1 range.
///
/// Deliberately not a `Color`: `import SwiftUI` is banned in `AppCoreModels` by
/// the layer-purity check in `scripts/validate.sh`, and both surfaces that need
/// a colour build their own from these. Keeping the parser here means the one
/// `#RRGGBB` implementation is shared and, for the first time, unit-testable —
/// it previously lived in a SwiftUI extension in the app target with no tests,
/// byte-duplicated into the widget.
public struct ColorComponents: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` or `RRGGBB`. Returns nil for anything else.
    public init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255,
            green: Double((value & 0x00FF00) >> 8) / 255,
            blue: Double(value & 0x0000FF) / 255
        )
    }
}

/// The vehicle appearance vocabulary shared by the app and the Live Activity.
public enum VehiclePalette {
    /// Named palette. Hex values double as the stored `Vehicle.colorHex`.
    public static let colorHexOptions: [String] = [
        "#F2760A", // orange (brand tint)
        "#E02B2B", // red
        "#0C8C4D", // green
        "#0A84C6", // blue
        "#7B5CE0", // purple
        "#B58500", // gold
        "#5A6672"  // slate
    ]

    public static let symbolOptions: [String] = [
        "car.fill",
        "truck.box.fill",
        "bus.fill",
        "car.side.fill",
        "bolt.car.fill",
        "van.fill",
        "motorcycle.fill"
    ]

    public static let defaultColorHex = colorHexOptions[0]
    public static let defaultSymbolName = symbolOptions[0]

    public static func symbolName(_ name: String?) -> String {
        name ?? defaultSymbolName
    }

    /// The shared fallback *policy*: a missing or malformed hex yields nil, and
    /// the caller substitutes its own brand tint. Before this existed the app
    /// fell back to brand orange while the Live Activity fell back to
    /// green/grey, so the same car rendered two different colours.
    public static func components(forHex hex: String?) -> ColorComponents? {
        guard let hex else { return nil }
        return ColorComponents(hex: hex)
    }
}
