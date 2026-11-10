import AppCore
import SwiftUI

/// Curated color and glyph choices for vehicle profiles, plus rendering
/// helpers. Colors are stored as hex strings on `Vehicle.colorHex`; symbols as
/// SF Symbol names on `Vehicle.symbolName`.
enum VehicleAppearance {
    /// Named palette and glyph list now live in `VehiclePalette` (AppCoreModels)
    /// so the Live Activity shares them; these forward for call-site brevity.
    static var colorHexOptions: [String] { VehiclePalette.colorHexOptions }
    static var symbolOptions: [String] { VehiclePalette.symbolOptions }

    static var defaultColorHex: String { VehiclePalette.defaultColorHex }
    static var defaultSymbol: String { VehiclePalette.defaultSymbolName }

    static func color(forHex hex: String?) -> Color {
        guard let components = VehiclePalette.components(forHex: hex) else {
            return MileageTheme.appTint
        }
        return Color(components)
    }

    static func symbol(_ name: String?) -> String {
        VehiclePalette.symbolName(name)
    }
}

extension Color {
    init(_ components: ColorComponents) {
        self.init(red: components.red, green: components.green, blue: components.blue)
    }

    /// Parses a `#RRGGBB` (or `RRGGBB`) hex string. Returns nil if malformed.
    ///
    /// The parser itself is `ColorComponents(hex:)` in AppCoreModels — one
    /// implementation shared with the Live Activity, and unit-testable there.
    init?(vehicleHex hex: String) {
        guard let components = ColorComponents(hex: hex) else { return nil }
        self.init(components)
    }
}
