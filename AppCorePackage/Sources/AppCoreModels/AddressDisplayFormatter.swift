import Foundation

public enum AddressDisplayFormatter {
    /// The pieces of a geocoder-style address ("22 Example St, Cambridge, MA 02139")
    /// that compact displays care about. `primary` is the leading component —
    /// a street line or a place name like "Sample Studio".
    public struct AddressParts: Equatable, Sendable {
        public var primary: String?
        public var city: String?
        public var stateCode: String?

        public init(primary: String? = nil, city: String? = nil, stateCode: String? = nil) {
            self.primary = primary
            self.city = city
            self.stateCode = stateCode
        }
    }

    public static func readableAddress(_ address: String) -> String {
        let normalizedAddress = normalizeAddressComponent(address)
        guard !normalizedAddress.isEmpty else { return "" }

        let components = displayComponents(of: address)
        return components.isEmpty ? normalizedAddress : components.joined(separator: ", ")
    }

    public static func parts(of address: String) -> AddressParts {
        var components = displayComponents(of: address)
        if let last = components.last, isZip(last) {
            components.removeLast()
        }
        var detectedStateCode: String?
        if let last = components.last, let code = stateCode(fromComponent: last) {
            detectedStateCode = code
            components.removeLast()
        }
        return AddressParts(
            primary: components.first,
            city: components.count >= 2 ? components.last : nil,
            stateCode: detectedStateCode
        )
    }

    /// Compact display form for space-constrained report tables: leading
    /// component plus city, ZIP dropped, state kept only when it differs from
    /// `homeState` ("67 Sample Rd, Newtown, CT" vs "22 Example St, Cambridge").
    public static func compactAddress(_ address: String, omittingState homeState: String? = nil) -> String {
        let parts = parts(of: address)
        guard let primary = parts.primary else { return readableAddress(address) }

        var pieces = [primary]
        if let city = parts.city {
            pieces.append(city)
        }
        if let state = parts.stateCode,
           state.caseInsensitiveCompare(homeState ?? "") != .orderedSame {
            pieces.append(state)
        }
        return pieces.joined(separator: ", ")
    }

    // `Bundle.appCoreStrings` is package-scoped, so a public default argument
    // can't reference it directly; `nil` stands in for the localized "Unknown"
    // fallback.
    public static func endpointText(
        address: String?,
        coordinate: Coordinate?,
        unknownLabel: String? = nil
    ) -> String {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return readableAddress(trimmed) }
        return coordinateLabel(coordinate) ?? unknownLabel ?? String(localized: "Unknown", bundle: .appCoreStrings)
    }

    public static func coordinateLabel(_ coordinate: Coordinate?) -> String? {
        guard let coordinate else { return nil }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    /// Compacts a street-type suffix ("139 Tremont Street" → "139 Tremont St")
    /// for space-constrained card labels. Only the final word of the component
    /// is abbreviated, so "Avenue of the Americas" stays intact. Exports and
    /// editors keep the full spelling.
    public static func abbreviatingStreetType(_ component: String) -> String {
        let words = component.split(separator: " ")
        guard let last = words.last,
              let abbreviation = streetTypeAbbreviations[last.lowercased()],
              words.count > 1 else {
            return component
        }
        return words.dropLast().joined(separator: " ") + " " + abbreviation
    }

    private static let streetTypeAbbreviations: [String: String] = [
        "street": "St",
        "avenue": "Ave",
        "boulevard": "Blvd",
        "drive": "Dr",
        "road": "Rd",
        "lane": "Ln",
        "court": "Ct",
        "place": "Pl",
        "square": "Sq",
        "terrace": "Ter",
        "parkway": "Pkwy",
        "highway": "Hwy",
        "turnpike": "Tpke",
        "circle": "Cir",
        "expressway": "Expy",
        "crossing": "Xing",
    ]

    private static func normalizeAddressComponent(_ component: String) -> String {
        component
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayComponents(of address: String) -> [String] {
        var seen = Set<String>()
        var components = address
            .split(separator: ",")
            .map { normalizeAddressComponent(String($0)) }
            .filter { component in
                guard !component.isEmpty else { return false }
                let key = component.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }

        if components.last?.caseInsensitiveCompare("United States") == .orderedSame {
            components.removeLast()
        }

        return components
    }

    /// Recognizes "MA", "MA 02139", "Massachusetts", or "Massachusetts 02139"
    /// as a state component and returns the two-letter code.
    private static func stateCode(fromComponent component: String) -> String? {
        var tokens = component.split(separator: " ").map(String.init)
        if let last = tokens.last, isZip(last) {
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1, tokens[0].count == 2 {
            let code = tokens[0].uppercased()
            return usStateCodes.contains(code) ? code : nil
        }
        return usStateCodesByName[tokens.joined(separator: " ").lowercased()]
    }

    private static func isZip(_ token: String) -> Bool {
        token.range(of: #"^\d{5}(-\d{4})?$"#, options: .regularExpression) != nil
    }

    private static let usStateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
        "DC", "PR", "GU", "VI", "AS", "MP",
    ]

    private static let usStateCodesByName: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR",
        "california": "CA", "colorado": "CO", "connecticut": "CT", "delaware": "DE",
        "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID",
        "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS",
        "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
        "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS",
        "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
        "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK",
        "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
        "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT",
        "vermont": "VT", "virginia": "VA", "washington": "WA", "west virginia": "WV",
        "wisconsin": "WI", "wyoming": "WY", "district of columbia": "DC", "puerto rico": "PR",
    ]
}
