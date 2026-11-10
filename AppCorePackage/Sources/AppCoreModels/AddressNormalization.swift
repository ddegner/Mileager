import Foundation

/// Canonicalizes street text so the same place matches across the app's
/// address sources: Apple's reverse geocoder ("123 Main St"), user-typed
/// contact addresses ("123 Main Street"), and freeform calendar event
/// locations. Token-level only — whole words map, so "Streeter" is untouched.
public enum AddressNormalizer {
    /// Lowercases, strips "." and ",", collapses whitespace, and maps
    /// street-suffix and directional tokens to their short USPS-style forms.
    /// Nil in, nil out; empty after trimming is also nil.
    public static func normalizedStreetText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map { canonicalTokens[String($0)] ?? String($0) }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " ")
    }

    /// Long → short spellings, both directions collapsing to one form.
    /// "saint" is deliberately absent: mapping it would turn every
    /// "Saint Marks" into "st marks" and collide with Street abbreviations
    /// more often than the miss costs. A leading "St"/"Dr" (Saint/Doctor)
    /// is harmless ambiguity — both comparands get identical treatment and
    /// callers additionally require street-number and/or city equality.
    private static let canonicalTokens: [String: String] = [
        "street": "st",
        "avenue": "ave",
        "av": "ave",
        "road": "rd",
        "boulevard": "blvd",
        "drive": "dr",
        "lane": "ln",
        "court": "ct",
        "place": "pl",
        "parkway": "pkwy",
        "highway": "hwy",
        "terrace": "ter",
        "circle": "cir",
        "square": "sq",
        "north": "n",
        "south": "s",
        "east": "e",
        "west": "w",
        "northeast": "ne",
        "northwest": "nw",
        "southeast": "se",
        "southwest": "sw"
    ]
}
