import Foundation

public enum DistanceConversion {
    public static let metersPerMile = 1_609.344
    public static let metersPerKilometer = 1_000.0

    public static func meters(fromMiles miles: Double) -> Double {
        miles * metersPerMile
    }

    public static func miles(fromMeters meters: Double) -> Double {
        meters / metersPerMile
    }

    public static func meters(fromKilometers kilometers: Double) -> Double {
        kilometers * metersPerKilometer
    }

    public static func value(meters: Double, in unit: DistanceUnit) -> Double {
        meters / unit.metersPerUnit
    }

    public static func meters(value: Double, in unit: DistanceUnit) -> Double {
        value * unit.metersPerUnit
    }
}
