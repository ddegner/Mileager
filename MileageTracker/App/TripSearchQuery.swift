import AppCore
import Foundation

/// Search locally across places, purposes, and notes. Unquoted words may
/// occur in different fields; quoted phrases stay together within one field.
struct TripSearchQuery {
    let text: String
    private let terms: [Term]
    private let locale: Locale

    private struct Term {
        let value: String
        let isPhrase: Bool
        let words: [String]

        init(value: String, isPhrase: Bool) {
            self.value = value
            self.isPhrase = isPhrase
            words = value.split(separator: " ").map(String.init)
        }

        func matches(_ field: Field) -> Bool {
            // Keep partial-word matching while typing, but require whole
            // words for explicit phrases ("north market" != "north marketplace").
            if isPhrase ? " \(field.text) ".contains(" \(value) ") : field.text.contains(value) {
                return true
            }
            // Only recognized street suffixes supply aliases. Compare complete
            // words so expanding Rd never rewrites the end of Oxford.
            guard field.addressWords.count >= words.count else { return false }
            return (0...(field.addressWords.count - words.count)).contains { start in
                words.enumerated().allSatisfy { offset, queryWord in
                    let word = field.addressWords[start + offset]
                    if word.value == queryWord { return true }
                    guard let suffix = word.suffix else { return false }
                    return suffix == streetSuffix(queryWord)
                }
            }
        }
    }

    private struct AddressWord {
        let value: String
        var suffix: String?
    }

    private struct Field {
        let text: String
        var addressWords: [AddressWord] = []
    }

    // Common English street suffixes from USPS Publication 28, Appendix C1:
    // https://pe.usps.com/text/pub28/28apc_002.htm
    // These are search aliases only; stored addresses are never rewritten.
    private static let streetAbbreviations = [
        "st": "street", "rd": "road", "ave": "avenue", "av": "avenue",
        "blvd": "boulevard", "dr": "drive", "ln": "lane", "ct": "court",
        "pl": "place", "ter": "terrace", "cir": "circle", "pkwy": "parkway",
        "hwy": "highway", "sq": "square", "trl": "trail", "cres": "crescent"
    ]
    private static let streetSuffixNames = Set(streetAbbreviations.values)
    private static let directions: Set<String> = [
        "n", "s", "e", "w", "ne", "nw", "se", "sw",
        "north", "south", "east", "west", "northeast", "northwest", "southeast", "southwest"
    ]
    private static let unitMarkers: Set<String> = ["apt", "apartment", "ste", "suite", "unit", "fl", "floor"]

    private static func streetSuffix(_ word: String) -> String? {
        streetAbbreviations[word] ?? (streetSuffixNames.contains(word) ? word : nil)
    }

    init(_ text: String) {
        let locale = Locale.current
        self.locale = locale
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        terms = Self.parse(self.text, locale: locale)
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(_ trip: TripSummary) -> Bool {
        guard !isEmpty else { return true }
        var addresses = [trip.startAddress, trip.endAddress]
        addresses += trip.legs.flatMap { [$0.startAddress, $0.endAddress] }
        addresses += trip.connectors.flatMap { [$0.startAddress, $0.endAddress] }
        addresses += trip.stops.map(\.address)
        var components = [trip.startAddressComponents, trip.endAddressComponents]
        components += trip.legs.flatMap { [$0.startAddressComponents, $0.endAddressComponents] }
        // Fold each distinct field once, rather than performing a localized
        // comparison for every query-word/field pair. Never join trip fields:
        // that would invent phrases spanning an origin, destination, or note.
        var values = Set(addresses.compactMap { $0 }).map { Self.addressField($0, locale: locale) }
        values += components.compactMap { $0 }.map { Self.addressField($0, locale: locale) }
        values += [trip.businessPurpose, trip.notes].compactMap { $0 }.map {
            Field(text: Self.normalize($0, locale: locale))
        }
        return terms.allSatisfy { term in
            values.contains { term.matches($0) }
        }
    }

    private static func addressField(_ address: String, locale: Locale) -> Field {
        var words: [AddressWord] = []
        var foundStreet = false
        // Retain address-component boundaries while identifying a suffix. Once
        // a street is found, later city/state components cannot become streets.
        for part in address.components(separatedBy: CharacterSet(charactersIn: ",;\n\r")) {
            var component = normalize(part, locale: locale).split(separator: " ")
                .map { AddressWord(value: String($0)) }
            if !foundStreet, let index = suffixIndex(in: component) {
                component[index].suffix = streetSuffix(component[index].value)
                foundStreet = true
            }
            words += component
        }
        return Field(text: words.map(\.value).joined(separator: " "), addressWords: words)
    }

    private static func addressField(_ components: TripEndpointAddressComponents, locale: Locale) -> Field {
        let street = [components.streetNumber, components.streetName].compactMap { $0 }.joined(separator: " ")
        let field = addressField(street, locale: locale)
        // Structured city/neighborhood names such as St Paul stay literal.
        let remainder = [components.neighborhood, components.city, components.state,
                         components.country, components.countryCode].compactMap { $0 }.joined(separator: " ")
        let words = field.addressWords + normalize(remainder, locale: locale).split(separator: " ")
            .map { AddressWord(value: String($0)) }
        return Field(text: words.map(\.value).joined(separator: " "), addressWords: words)
    }

    private static func suffixIndex(in words: [AddressWord]) -> Int? {
        words.indices.first { index in
            // St Paul and Dr Smith are names, including after a house number.
            guard index > 0, words[index - 1].value.contains(where: \.isLetter),
                  streetSuffix(words[index].value) != nil else { return false }
            var trailing = words[(index + 1)...]
            // In "Old Court Rd", Road is the suffix and Court is the name.
            if let first = trailing.first, streetSuffix(first.value) != nil { return false }
            if let first = trailing.first, directions.contains(first.value) { trailing = trailing.dropFirst() }
            if trailing.isEmpty || trailing.first.map({ unitMarkers.contains($0.value) }) == true { return true }
            // An explicit house number also identifies streets in addresses
            // pasted without commas, such as "450 W 33rd St New York NY".
            return words[..<(index - 1)].contains { $0.value.first?.isNumber == true }
        }
    }

    private static func parse(_ text: String, locale: Locale) -> [Term] {
        var terms: [Term] = []
        var chunk = ""
        var isPhrase = false

        func appendChunk() {
            let value = normalize(chunk, locale: locale)
            if !value.isEmpty {
                if isPhrase {
                    terms.append(Term(value: value, isPhrase: true))
                } else {
                    terms += value.split(separator: " ").map { Term(value: String($0), isPhrase: false) }
                }
            }
            chunk = ""
        }

        for character in text {
            switch character {
            case "\"", "“", "”", "„", "«", "»":
                appendChunk()
                isPhrase.toggle()
            default:
                chunk.append(character)
            }
        }
        // An unfinished quote remains searchable while the user is typing.
        appendChunk()
        return terms
    }

    private static func normalize(_ text: String, locale: Locale) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        var result = ""
        var needsSpace = false
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "'", "‘", "’", "ʼ":
                // O'Neill, O’Neill, and ONeill are the same searchable name.
                continue
            default:
                if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                    if needsSpace, !result.isEmpty { result.append(" ") }
                    result.unicodeScalars.append(scalar)
                    needsSpace = false
                } else {
                    // Hyphens, commas, and repeated whitespace separate words.
                    needsSpace = true
                }
            }
        }
        return result
    }
}

enum DriveSearchScope: Hashable {
    case currentMailbox
    case allTrips

    func listScope(mailbox: DriveListScope, query: TripSearchQuery) -> DriveListScope {
        !query.isEmpty && self == .allTrips ? .allTrips : mailbox
    }
}
