import Foundation

/// A concrete display unit for distances. Storage stays in meters everywhere;
/// this only governs presentation and user entry.
public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case miles
    case kilometers

    public var unitLength: UnitLength {
        switch self {
        case .miles: .miles
        case .kilometers: .kilometers
        }
    }

    public var metersPerUnit: Double {
        switch self {
        case .miles: DistanceConversion.metersPerMile
        case .kilometers: DistanceConversion.metersPerKilometer
        }
    }

    /// The unit the device locale implies. UK roads are signed in miles, so
    /// `.uk` maps to miles alongside `.us`.
    public static func systemDefault(for locale: Locale = .current) -> DistanceUnit {
        locale.measurementSystem == .metric ? .kilometers : .miles
    }
}

/// The user's stored choice: follow the device locale, or force a unit.
public enum DistanceUnitPreference: String, Codable, Sendable {
    case system
    case miles
    case kilometers

    public func resolved(for locale: Locale = .current) -> DistanceUnit {
        switch self {
        case .system: DistanceUnit.systemDefault(for: locale)
        case .miles: .miles
        case .kilometers: .kilometers
        }
    }
}
