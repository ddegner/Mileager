import AppCoreModels
import Foundation

public enum BluetoothVehicleNameMatcher {
    private static let rejectedTerms = [
        "airpod",
        "beats",
        "bose",
        "earbud",
        "headphone",
        "headset",
        "homepod",
        "jbl",
        "keyboard",
        "macbook",
        "mouse",
        "soundbar",
        "sonos",
        "speaker",
        "watch"
    ]

    private static let acceptedTerms = [
        "acura",
        "audi",
        "bmw",
        "buick",
        "cadillac",
        "car multimedia",
        "carplay",
        "chevrolet",
        "chevy",
        "chrysler",
        "comand",
        "dodge",
        "entune",
        "ford",
        "gmc",
        "honda",
        "hyundai",
        "infiniti",
        "jeep",
        "kia",
        "lexus",
        "mazda",
        "mercedes",
        "mylink",
        "nissan",
        "porsche",
        "ram",
        "subaru",
        "sync",
        "tesla",
        "toyota",
        "uconnect",
        "volkswagen",
        "volvo"
    ]

    public enum NameClass: Sendable {
        case vehicle
        case unknown
        case rejected
    }

    public static func matches(_ name: String?) -> Bool {
        classify(name) == .vehicle
    }

    public static func classify(_ name: String?) -> NameClass {
        guard let name else { return .unknown }
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return .unknown }

        let compact = normalized.replacingOccurrences(of: " ", with: "")
        if rejectedTerms.contains(where: { normalized.contains($0) || compact.contains($0) }) {
            return .rejected
        }

        let accepted = acceptedTerms.contains { term in
            normalized.contains(term) || compact.contains(term.replacingOccurrences(of: " ", with: ""))
        }
        return accepted ? .vehicle : .unknown
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }
}
