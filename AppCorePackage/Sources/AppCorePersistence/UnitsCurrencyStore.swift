import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Persists the user's distance-unit and currency choices, following the same
/// Core Data `PreferenceStore` pattern as `MileageRateStore`.
public final class UnitsCurrencyStore {
    public static let distanceUnitKey = "distanceUnit.v1"
    public static let currencyKey = "currencyCode.v1"

    private let context: NSManagedObjectContext
    private let distanceUnitPreferences: PreferenceStore
    private let currencyPreferences: PreferenceStore
    private let mileageRatePreferences: PreferenceStore

    public init(context: NSManagedObjectContext) {
        self.context = context
        distanceUnitPreferences = PreferenceStore(context: context, key: Self.distanceUnitKey)
        currencyPreferences = PreferenceStore(context: context, key: Self.currencyKey)
        mileageRatePreferences = PreferenceStore(
            context: context,
            key: MileageRateStore.preferenceKey
        )
    }

    public func fetchDistanceUnitPreference() throws -> DistanceUnitPreference {
        let decoded: DistanceUnitPreference? = try distanceUnitPreferences.read()
        return decoded ?? .system
    }

    public func saveDistanceUnitPreference(_ preference: DistanceUnitPreference) throws {
        try distanceUnitPreferences.write(preference)
    }

    /// Saves the display unit and its value-equivalent mileage rate together so
    /// CloudKit can never observe a newly quoted unit with the old numeric rate.
    @discardableResult
    public func saveDistanceUnitPreference(
        _ preference: DistanceUnitPreference,
        preservingValueOf mileageRate: MileageRate
    ) throws -> MileageRate {
        try saveDistanceUnitPreference(
            preference,
            preservingValueOf: mileageRate,
            beforeSave: {}
        )
    }

    @discardableResult
    func saveDistanceUnitPreference(
        _ preference: DistanceUnitPreference,
        preservingValueOf mileageRate: MileageRate,
        beforeSave: () throws -> Void
    ) throws -> MileageRate {
        let convertedRate = try MileageRateStore.validated(
            mileageRate.converted(to: preference.resolved())
        )
        return try context.saveTransaction {
            try distanceUnitPreferences.writeWithoutSaving(preference)
            if convertedRate != mileageRate {
                try mileageRatePreferences.writeWithoutSaving(convertedRate)
            }
            try beforeSave()
            return convertedRate
        }
    }

    public static func defaultCurrencyCode(for locale: Locale = .current) -> String {
        CurrencyCatalog.defaultCurrencyCode(for: locale)
    }

    public func fetchCurrencyCode() throws -> String {
        let decoded: String? = try currencyPreferences.read()
        return decoded ?? Self.defaultCurrencyCode()
    }

    public func saveCurrencyCode(_ code: String) throws {
        try currencyPreferences.write(code)
    }
}
