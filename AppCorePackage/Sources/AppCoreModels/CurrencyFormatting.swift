import Foundation

/// The single place money becomes user-visible text. Amounts are whatever
/// currency the user selected — values are never exchange-rate converted.
public enum CurrencyFormatting {
    /// "$12.34" / "12,34 €" depending on code and locale.
    public static func label(
        _ amount: Double,
        code: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        amount.formatted(.currency(code: code).locale(locale))
    }

    /// The bare currency symbol for a code, e.g. "$", "€", "CA$".
    public static func symbol(code: String, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }

    /// Rate suffix like "$/mi" or "€/km".
    public static func ratePerUnitSuffix(
        code: String,
        unit: DistanceUnit,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        "\(symbol(code: code, locale: locale))/\(DistanceFormatting.unitSymbol(unit, locale: locale))"
    }

    /// Compact rate string, e.g. "$0.725/mi": bare symbol + fixed-precision
    /// per-unit amount converted to the display unit + localized unit symbol.
    public static func rateText(
        _ rate: MileageRate,
        code: String,
        unit: DistanceUnit,
        fractionDigits: Int = 3,
        minimumFractionDigits: Int? = nil,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let amount = rate.converted(to: unit).amountPerUnit
            .formatted(
                .number.precision(.fractionLength(min(minimumFractionDigits ?? fractionDigits, fractionDigits)...fractionDigits))
                    .grouping(.never)
                    .locale(locale)
            )
        return "\(symbol(code: code, locale: locale))\(amount)/\(DistanceFormatting.unitSymbol(unit, locale: locale))"
    }
}

public enum CurrencyCatalog {
    /// The locale's currency, defaulting to USD when the locale has none.
    public static func defaultCurrencyCode(for locale: Locale = .current) -> String {
        locale.currency?.identifier ?? "USD"
    }

    public static func commonCodes(selectedCode: String? = nil) -> [String] {
        var codes = [
            defaultCurrencyCode(),
            "USD", "EUR", "GBP", "CAD", "MXN", "CHF"
        ]
        if let selectedCode, !codes.contains(selectedCode) {
            codes.insert(selectedCode, at: 0)
        }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    public static func allCodes(locale: Locale = .autoupdatingCurrent) -> [String] {
        Locale.commonISOCurrencyCodes.sorted {
            displayName(for: $0, locale: locale)
                .localizedStandardCompare(displayName(for: $1, locale: locale))
                == .orderedAscending
        }
    }

    public static func displayName(
        for code: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }

}
