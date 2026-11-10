import Foundation

/// Locale, distance unit, currency, and time zone that a generated report should be
/// rendered with. Tests pin this to en_US/miles/USD so assertions hold on any
/// machine; the app builds it from the user's preferences.
public struct ReportFormattingContext: Sendable {
    public var locale: Locale
    public var distanceUnit: DistanceUnit
    public var currencyCode: String
    public var timeZone: TimeZone

    public init(locale: Locale = .current, distanceUnit: DistanceUnit, currencyCode: String, timeZone: TimeZone = .current) {
        self.locale = locale
        self.distanceUnit = distanceUnit
        self.currencyCode = currencyCode
        self.timeZone = timeZone
    }

    package var currency: ReportCurrency { ReportCurrency(code: currencyCode) }
}

/// The same currency precision is used before summing and when serializing
/// money. Foundation's currency metadata also covers zero-, three- and
/// four-decimal currencies without maintaining a second currency catalog.
package struct ReportCurrency {
    package let fractionDigits: Int
    private let scale: Double

    package init(code: String) {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        fractionDigits = formatter.maximumFractionDigits
        scale = pow(10, Double(fractionDigits))
    }

    package func rounded(_ value: Double) -> Double {
        (value * scale).rounded() / scale
    }

    package func csv(_ value: Double) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), fractionDigits, rounded(value))
    }
}

package enum CurrencyRounding {
    package static func cents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

package enum ReportMilesRounding {
    /// Rounds miles to the 2 decimal places shown per row so a displayed miles
    /// total (a sum of these) foots to the sum of the printed rows.
    package static func twoPlaces(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
