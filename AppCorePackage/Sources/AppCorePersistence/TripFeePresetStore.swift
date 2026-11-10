import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public final class TripFeePresetStore {
    public static let preferenceKey = "tripFeePresets.v1"
    static let itemStatePreferenceKey = "tripFeePresetItemState.v1"

    private let context: NSManagedObjectContext
    private let preferences: PreferenceStore
    private let itemStatePreferences: PreferenceStore

    public init(context: NSManagedObjectContext) {
        self.context = context
        preferences = PreferenceStore(context: context, key: Self.preferenceKey)
        itemStatePreferences = PreferenceStore(context: context, key: Self.itemStatePreferenceKey)
    }

    public func fetchPresets() throws -> [TripFeePreset] {
        let decoded: [TripFeePreset]? = try preferences.read()
        return Self.normalized(decoded ?? [])
    }

    @discardableResult
    public func savePresets(_ presets: [TripFeePreset]) throws -> [TripFeePreset] {
        let normalized = Self.normalized(presets)
        let current = try fetchPresets()
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

    public static func normalized(_ presets: [TripFeePreset]) -> [TripFeePreset] {
        var seen = Set<String>()
        var result: [TripFeePreset] = []
        for preset in presets
            .sorted(by: { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.category.rawValue < rhs.category.rawValue
                }
                return lhs.sortOrder < rhs.sortOrder
            }) {
            let trimmedLabel = preset.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty,
                  preset.amount.isFinite,
                  preset.amount >= 0 else {
                continue
            }
            let key = "\(preset.category.rawValue)|\(trimmedLabel.lowercased())"
            guard seen.insert(key).inserted else { continue }
            result.append(TripFeePreset(
                id: preset.id,
                category: preset.category,
                label: trimmedLabel,
                amount: preset.amount,
                sortOrder: result.count
            ))
        }
        return result
    }

    static func itemKey(_ preset: TripFeePreset) -> String {
        let label = preset.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(preset.category.rawValue)|\(label)"
    }
}
