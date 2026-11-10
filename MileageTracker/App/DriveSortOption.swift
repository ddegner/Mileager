import AppCore
import SwiftUI

enum DriveSortOption: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case longestDistance
    case shortestDistance

    var id: Self { self }

    var title: String {
        switch self {
        case .newestFirst: String(localized: "Newest First")
        case .oldestFirst: String(localized: "Oldest First")
        case .longestDistance: String(localized: "Longest Distance")
        case .shortestDistance: String(localized: "Shortest Distance")
        }
    }

    var systemImage: String {
        switch self {
        case .newestFirst: "calendar.badge.clock"
        case .oldestFirst: "calendar"
        case .longestDistance: "arrow.up.right"
        case .shortestDistance: "arrow.down.right"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .newestFirst: "1"
        case .oldestFirst: "2"
        case .longestDistance: "3"
        case .shortestDistance: "4"
        }
    }

    var next: DriveSortOption {
        let options = Self.allCases
        guard let index = options.firstIndex(of: self) else { return .newestFirst }
        return options[options.index(after: index) == options.endIndex ? options.startIndex : options.index(after: index)]
    }

    var usesOldestMonthFirst: Bool {
        self == .oldestFirst
    }

    func sorted(_ trips: [TripSummary]) -> [TripSummary] {
        trips.sorted { lhs, rhs in
            switch self {
            case .newestFirst:
                return compare(lhs, rhs, by: lhs.startDate > rhs.startDate)
            case .oldestFirst:
                return compare(lhs, rhs, by: lhs.startDate < rhs.startDate, newestFirstTieBreak: false)
            case .longestDistance:
                return compare(lhs, rhs, by: lhs.reportableDistanceMeters > rhs.reportableDistanceMeters)
            case .shortestDistance:
                return compare(lhs, rhs, by: lhs.reportableDistanceMeters < rhs.reportableDistanceMeters)
            }
        }
    }

    private func compare(
        _ lhs: TripSummary,
        _ rhs: TripSummary,
        by result: Bool,
        newestFirstTieBreak: Bool = true
    ) -> Bool {
        switch self {
        case .newestFirst, .oldestFirst:
            guard lhs.startDate != rhs.startDate else { return lhs.id.uuidString < rhs.id.uuidString }
            return result
        case .longestDistance, .shortestDistance:
            guard lhs.reportableDistanceMeters != rhs.reportableDistanceMeters else {
                if lhs.startDate == rhs.startDate {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return newestFirstTieBreak ? lhs.startDate > rhs.startDate : lhs.startDate < rhs.startDate
            }
            return result
        }
    }
}
