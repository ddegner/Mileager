import Foundation

package struct SyncedListItemState: Codable, Equatable, Sendable {
    package var isDeleted: Bool
    package var updatedAt: Date

    package init(isDeleted: Bool, updatedAt: Date) {
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }
}

package enum SyncedListItemStateMerge {
    package static func merged(
        _ maps: [[String: SyncedListItemState]]
    ) -> [String: SyncedListItemState] {
        var result: [String: SyncedListItemState] = [:]
        for map in maps {
            for (key, candidate) in map {
                guard let current = result[key] else {
                    result[key] = candidate
                    continue
                }
                if candidate.updatedAt > current.updatedAt
                    || (candidate.updatedAt == current.updatedAt
                        && candidate.isDeleted && !current.isDeleted) {
                    result[key] = candidate
                }
            }
        }
        return result
    }

    package static func includes(
        key: String,
        listUpdatedAt: Date,
        states: [String: SyncedListItemState]
    ) -> Bool {
        guard let state = states[key], state.isDeleted else { return true }
        return listUpdatedAt > state.updatedAt
    }
}
