import Foundation

public enum NumericTextInput {
    public static func nonnegativeDouble(
        _ text: String,
        locale: Locale = .current
    ) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = parseDouble(trimmed, locale: locale),
              value.isFinite,
              value >= 0 else { return nil }
        return value
    }

    public static func positiveDouble(
        _ text: String,
        locale: Locale = .current
    ) -> Double? {
        guard let value = nonnegativeDouble(text, locale: locale), value > 0 else {
            return nil
        }
        return value
    }

    public static func nonnegativeDoubleOrZeroIfBlank(
        _ text: String,
        locale: Locale = .current
    ) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return nonnegativeDouble(trimmed, locale: locale)
    }

    public static func fixedTwoDecimals(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Rejects ambiguous grouping while accepting the locale's decimal
    /// separator and non-ASCII decimal digits.
    private static func parseDouble(_ text: String, locale: Locale) -> Double? {
        if let value = Double(text) { return value }

        let normalized = String(text.map { character in
            if character.isNumber,
               let digit = character.wholeNumberValue,
               (0...9).contains(digit) {
                return Character("\(digit)")
            }
            return character
        })
        if normalized != text, let value = Double(normalized) { return value }

        guard let separator = locale.decimalSeparator,
              separator != ".",
              normalized.contains(separator),
              !normalized.contains(".") else { return nil }
        if let grouping = locale.groupingSeparator,
           grouping != separator,
           normalized.contains(grouping) {
            return nil
        }
        return Double(normalized.replacingOccurrences(of: separator, with: "."))
    }
}
