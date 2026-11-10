import Foundation

/// The single place distances become user-visible text. Converts explicitly to
/// the requested unit before formatting with `.asProvided`, so the user's unit
/// override always beats the locale's measurement system, while digits and
/// separators still follow the locale.
public enum DistanceFormatting {
    /// Unit label, abbreviated by default ("6.4 mi" / "10,3 km"). Pass
    /// `.wide` for full localized unit names, including accessibility labels.
    public static func label(
        meters: Double,
        unit: DistanceUnit,
        fractionDigits: Int = 1,
        width: Measurement<UnitLength>.FormatStyle.UnitWidth = .abbreviated,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        label(meters: meters, unit: unit, fractionDigits: fractionDigits...fractionDigits, width: width, locale: locale)
    }

    /// Variant with flexible fraction digits: `0...1` drops a trailing ".0"
    /// ("6 mi", "6.4 mi"), as Spotlight/Intent card text prefers.
    public static func label(
        meters: Double,
        unit: DistanceUnit,
        fractionDigits: ClosedRange<Int>,
        width: Measurement<UnitLength>.FormatStyle.UnitWidth = .abbreviated,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        Measurement(value: DistanceConversion.value(meters: meters, in: unit), unit: unit.unitLength)
            .formatted(
                .measurement(
                    width: width,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(fractionDigits))
                )
                .locale(locale)
            )
    }

    /// Grouped numeric distance for columns whose header already supplies the
    /// unit. Unlike editable valueText, this keeps locale grouping separators.
    public static func number(
        meters: Double,
        unit: DistanceUnit,
        fractionDigits: Int = 1,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        DistanceConversion.value(meters: meters, in: unit)
            .formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// Bare numeric value in the unit ("6.42"), for editable text fields.
    /// Never uses grouping separators — "1,234.56" wouldn't round-trip
    /// through a decimal-pad text field's parser.
    public static func valueText(
        meters: Double,
        unit: DistanceUnit,
        fractionDigits: Int = 2,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        DistanceConversion.value(meters: meters, in: unit)
            .formatted(
                .number.precision(.fractionLength(fractionDigits))
                    .grouping(.never)
                    .locale(locale)
            )
    }

    /// POSIX-formatted value ("6.42") for CSV output, which must stay
    /// machine-stable regardless of the display locale.
    public static func csvValue(meters: Double, unit: DistanceUnit) -> String {
        String(format: "%.2f", DistanceConversion.value(meters: meters, in: unit))
    }

    /// Localized abbreviated unit symbol on its own, e.g. "mi" / "km".
    public static func unitSymbol(_ unit: DistanceUnit, locale: Locale = .autoupdatingCurrent) -> String {
        MeasurementFormatter.localizedSymbol(for: unit.unitLength, locale: locale)
    }
}

private extension MeasurementFormatter {
    static func localizedSymbol(for unit: UnitLength, locale: Locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        return formatter.string(from: unit)
    }
}
