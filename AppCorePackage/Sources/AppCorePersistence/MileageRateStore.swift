import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public final class MileageRateStore {
    public static let preferenceKey = "mileageRate.v2"
    /// v1 stored `{"businessCentsPerMile": x}`, always quoted per mile.
    public static let legacyPreferenceKey = "mileageRate.v1"

    private let preferences: PreferenceStore
    private let legacyPreferences: PreferenceStore

    public init(context: NSManagedObjectContext) {
        preferences = PreferenceStore(context: context, key: Self.preferenceKey)
        legacyPreferences = PreferenceStore(context: context, key: Self.legacyPreferenceKey)
    }

    public func fetchRate() throws -> MileageRate {
        try fetchPersistedRate() ?? Self.validated(.default)
    }

    /// Reads an actual saved value without confusing absence with a default.
    public func fetchPersistedRate() throws -> MileageRate? {
        if let decoded: MileageRate = try preferences.read() {
            return try Self.validated(decoded)
        }
        if let legacy: LegacyMileageRateV1 = try legacyPreferences.read() {
            let migrated = try Self.validated(
                MileageRate(amountPerUnit: legacy.businessCentsPerMile / 100, unit: .miles)
            )
            // A failed v2 write must not discard the user's rate for the
            // session (the caller would fall back to .default); the v1 value
            // survives, so persisting the migration retries next launch.
            try? preferences.write(migrated)
            return migrated
        }
        return nil
    }

    @discardableResult
        /// No production caller: this was the native Mac editor's path into the
    /// store, and iOS reaches the same states through other facade methods.
    /// Kept at `package` access — in-package tests use it to construct and
    /// verify those states, and the narrower access keeps the app from
    /// growing a second way to do the same thing.
package func saveRate(_ rate: MileageRate) throws -> MileageRate {
        let validated = try Self.validated(rate)
        try preferences.write(validated)
        return validated
    }

    public static func validated(_ rate: MileageRate) throws -> MileageRate {
        guard rate.amountPerUnit.isFinite, rate.amountPerUnit >= 0 else {
            throw TripStoreError.invalidAmount
        }
        return rate
    }
}

private struct LegacyMileageRateV1: Codable {
    var businessCentsPerMile: Double
}
