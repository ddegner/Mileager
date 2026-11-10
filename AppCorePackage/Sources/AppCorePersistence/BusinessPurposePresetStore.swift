import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public final class BusinessPurposePresetStore {
    public static let preferenceKey = "businessPurposePresets.v1"
    static let itemStatePreferenceKey = "businessPurposePresetItemState.v1"
    public static let defaultPurposes = [
        "Client meeting",
        "Site visit",
        "Supplies"
    ]

    private let context: NSManagedObjectContext
    private let preferences: PreferenceStore
    private let itemStatePreferences: PreferenceStore

    public init(context: NSManagedObjectContext) {
        self.context = context
        preferences = PreferenceStore(context: context, key: Self.preferenceKey)
        itemStatePreferences = PreferenceStore(context: context, key: Self.itemStatePreferenceKey)
    }

    public func fetchPurposes() throws -> [String] {
        let decoded: [String]? = try preferences.read()
        return Self.normalized(decoded ?? Self.defaultPurposes)
    }

    @discardableResult
    public func savePurposes(_ purposes: [String]) throws -> [String] {
        let normalized = Self.normalized(purposes)
        let current = try fetchPurposes()
        var states: [String: SyncedListItemState] = try itemStatePreferences.read() ?? [:]
        let currentKeys = Set(current.map(Self.itemKey))
        let newKeys = Set(normalized.map(Self.itemKey))
        let now = Date()
        for key in currentKeys.subtracting(newKeys) {
            states[key] = SyncedListItemState(isDeleted: true, updatedAt: now)
        }
        for key in newKeys.subtracting(currentKeys)
            where states[key]?.isDeleted == true {
            states[key] = SyncedListItemState(isDeleted: false, updatedAt: now)
        }
        try context.saveTransaction {
            try preferences.writeWithoutSaving(normalized, updatedAt: now)
            try itemStatePreferences.writeWithoutSaving(states, updatedAt: now)
        }
        return normalized
    }

    public static func normalized(_ purposes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for purpose in purposes {
            let trimmed = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func completionSuggestions(
        for query: String,
        in purposes: [String],
        limit: Int = 4
    ) -> [String] {
        guard limit > 0 else { return [] }
        let normalizedPurposes = normalized(purposes)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return Array(normalizedPurposes.prefix(limit))
        }

        let foldedQuery = folded(trimmedQuery)
        let candidates = normalizedPurposes.filter {
            folded($0) != foldedQuery && folded($0).contains(foldedQuery)
        }
        let matches = candidates.filter { folded($0).hasPrefix(foldedQuery) }
            + candidates.filter { !folded($0).hasPrefix(foldedQuery) }
        return Array(matches.prefix(limit))
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }

    static func itemKey(_ purpose: String) -> String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
