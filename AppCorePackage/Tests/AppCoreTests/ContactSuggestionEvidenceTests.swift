import AppCoreModels
import AppCoreSuggestions
import Foundation
import XCTest

/// Pure matching tests for the contact-address suggestion evidence; the
/// CNContactStore loader is a thin adapter and is not exercised here.
final class ContactSuggestionEvidenceTests: XCTestCase {
    private let index = ContactAddressIndex(entries: [
        "26 example st|cambridge": .init(contactName: "Dana Reyes", isOrganization: false, label: "home"),
        "815 massachusetts ave|cambridge": .init(contactName: "Boston Globe", isOrganization: true, label: nil),
        "350 5th ave|new york": .init(contactName: "Alta Mark", isOrganization: false, label: nil),
        "30 rockefeller plaza|new york": .init(contactName: "Pat Lee", isOrganization: false, label: "work")
    ])

    func testKeyRequiresStreetAndCityAndNormalizes() {
        XCTAssertEqual(ContactAddressIndex.key(streetLine: " 26  Example St ", city: "CAMBRIDGE"), "26 example st|cambridge")
        XCTAssertNil(ContactAddressIndex.key(streetLine: "26 Example St", city: nil))
        XCTAssertNil(ContactAddressIndex.key(streetLine: nil, city: "Cambridge"))
    }

    /// Human-typed contact addresses ("Street", "Avenue") must key the same
    /// as the geocoder's abbreviated endpoint components.
    func testKeyNormalizesStreetSuffixVariants() {
        XCTAssertEqual(
            ContactAddressIndex.key(streetLine: "26 Example Street", city: "Cambridge"),
            ContactAddressIndex.key(streetLine: "26 Example St", city: "Cambridge")
        )
        XCTAssertEqual(
            ContactAddressIndex.key(streetLine: "815 Massachusetts Avenue", city: "Cambridge"),
            ContactAddressIndex.key(streetLine: "815 Massachusetts Ave.", city: "Cambridge")
        )
        XCTAssertNotEqual(
            ContactAddressIndex.key(streetLine: "26 Example St", city: "Cambridge"),
            ContactAddressIndex.key(streetLine: "28 Example St", city: "Cambridge")
        )
    }

    func testNoteMatchesAcrossSuffixVariant() {
        // Index entry was built from "26 example st"; a geocoded endpoint
        // spelled out as "Example Street" must still find Dana.
        XCTAssertEqual(
            index.note(for: TripEndpointAddressComponents(streetNumber: "26", streetName: "Example Street", city: "Cambridge")),
            "the home address of contact “Dana Reyes”"
        )
    }

    func testNotesForLabeledPersonOrganizationAndUnlabeled() {
        XCTAssertEqual(
            index.note(for: TripEndpointAddressComponents(streetNumber: "26", streetName: "Example St", city: "Cambridge")),
            "the home address of contact “Dana Reyes”"
        )
        XCTAssertEqual(
            index.note(for: TripEndpointAddressComponents(streetNumber: "815", streetName: "Massachusetts Ave", city: "Cambridge")),
            "the address of “Boston Globe”, an organization contact"
        )
        XCTAssertEqual(
            index.note(for: TripEndpointAddressComponents(streetNumber: "350", streetName: "5th Ave", city: "New York")),
            "the address of contact “Alta Mark”"
        )
    }

    func testWorkplaceAuthorityIsStructuredAndConservative() {
        let home = index.match(for: TripEndpointAddressComponents(
            streetNumber: "26", streetName: "Example St", city: "Cambridge"
        ))
        let organization = index.match(for: TripEndpointAddressComponents(
            streetNumber: "815", streetName: "Massachusetts Ave", city: "Cambridge"
        ))
        let unlabeledPerson = index.match(for: TripEndpointAddressComponents(
            streetNumber: "350", streetName: "5th Ave", city: "New York"
        ))
        let work = index.match(for: TripEndpointAddressComponents(
            streetNumber: "30", streetName: "Rockefeller Plaza", city: "New York"
        ))

        XCTAssertEqual(home?.isWorkplace, false)
        XCTAssertEqual(organization?.isWorkplace, true)
        XCTAssertEqual(unlabeledPerson?.isWorkplace, false)
        XCTAssertEqual(work?.isWorkplace, true)
    }

    func testNoteIsNilForUnknownOrIncompleteAddress() {
        XCTAssertNil(index.note(for: TripEndpointAddressComponents(streetNumber: "1", streetName: "Main St", city: "Boston")))
        XCTAssertNil(index.note(for: TripEndpointAddressComponents(city: "Cambridge")))
        XCTAssertNil(index.note(for: nil))
    }
}
