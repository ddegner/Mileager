import AppCore
import AppIntents

enum TripClassificationAppEnum: String, AppEnum {
    case business
    case personal
    case notADrive

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trip Category")
    static let caseDisplayRepresentations: [TripClassificationAppEnum: DisplayRepresentation] = [
        .business: "Business",
        .personal: "Personal",
        .notADrive: "Not a Drive"
    ]

    init(_ classification: TripClassification) {
        switch classification {
        case .business:
            self = .business
        case .personal:
            self = .personal
        case .notADrive:
            self = .notADrive
        }
    }

    var domainValue: TripClassification {
        switch self {
        case .business:
            .business
        case .personal:
            .personal
        case .notADrive:
            .notADrive
        }
    }
}
