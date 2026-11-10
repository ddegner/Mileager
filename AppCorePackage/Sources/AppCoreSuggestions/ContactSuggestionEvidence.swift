import AppCoreEnrichment
import AppCoreModels
import Contacts
import Foundation

/// Matches trip endpoints against the user's contacts' postal addresses for
/// suggestion evidence. Matching is textual — street line + city against the
/// geocoded endpoint components the app already stores — so no geocoding of
/// the address book is needed. Names and labels only ever feed the on-device
/// prompt.
public struct ContactAddressIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public var contactName: String
        public var isOrganization: Bool
        /// "home" / "work" when the contact's address was labeled.
        public var label: String?

        public init(contactName: String, isOrganization: Bool, label: String? = nil) {
            self.contactName = contactName
            self.isOrganization = isOrganization
            self.label = label
        }
    }

    public struct Match: Equatable, Sendable {
        public var note: String
        public var isWorkplace: Bool

        public init(note: String, isWorkplace: Bool) {
            self.note = note
            self.isWorkplace = isWorkplace
        }
    }

    private var entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    /// Normalized lookup key for an address: lowercase "street line|city".
    /// Both parts are required — a street without a city is too ambiguous.
    /// The street half is suffix-normalized so a human-typed contact address
    /// ("123 Main Street") matches the geocoder's endpoint ("123 Main St").
    public static func key(streetLine: String?, city: String?) -> String? {
        guard let street = AddressNormalizer.normalizedStreetText(streetLine),
              let city = normalized(city) else { return nil }
        return "\(street)|\(city)"
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    /// Structured match for an endpoint. The prompt gets `note`; the output
    /// gate gets `isWorkplace`, so it never has to infer authority from prose.
    /// Organization and work-labeled addresses count as workplaces; home and
    /// unlabeled personal-contact addresses do not.
    public func match(for components: TripEndpointAddressComponents?) -> Match? {
        guard let key = Self.key(streetLine: components?.streetLine, city: components?.city),
              let entry = entries[key] else {
            return nil
        }
        if entry.isOrganization {
            return Match(
                note: "the address of “\(entry.contactName)”, an organization contact",
                isWorkplace: true
            )
        }
        if let label = entry.label {
            return Match(
                note: "the \(label) address of contact “\(entry.contactName)”",
                isWorkplace: label == "work"
            )
        }
        return Match(
            note: "the address of contact “\(entry.contactName)”",
            isWorkplace: false
        )
    }

    /// Prompt-facing note for an endpoint, e.g. "the home address of contact
    /// “Dana Reyes”" or "the address of “Boston Globe”, an organization
    /// contact". English on purpose: the prompt is model-facing.
    public func note(for components: TripEndpointAddressComponents?) -> String? {
        match(for: components)?.note
    }

    /// Builds the index from the contact store. Blocking — call off the main
    /// actor. Returns an empty index when access is not authorized.
    public static func load() -> ContactAddressIndex {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactTypeKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var entries: [String: Entry] = [:]
        try? store.enumerateContacts(with: request) { contact, _ in
            let isOrganization = contact.contactType == .organization
            let name = isOrganization
                ? contact.organizationName
                : (CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName)
            guard !name.isEmpty else { return }
            for labeledAddress in contact.postalAddresses {
                let address = labeledAddress.value
                let streetLine = address.street.components(separatedBy: .newlines).first
                guard let key = key(streetLine: streetLine, city: address.city) else { continue }
                let label: String? = switch labeledAddress.label {
                case CNLabelHome: "home"
                case CNLabelWork: "work"
                default: nil
                }
                // First writer wins; the user's own card is handled
                // separately via preferences, so collisions are rare noise.
                if entries[key] == nil {
                    entries[key] = Entry(contactName: name, isOrganization: isOrganization, label: label)
                }
            }
        }
        return ContactAddressIndex(entries: entries)
    }
}
