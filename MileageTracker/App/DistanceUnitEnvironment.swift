import AppCore
import SwiftUI

/// Environment plumbing for the resolved display unit, so leaf views like
/// `DriveRow` can format distances without holding the whole app model.
/// Defaults to miles when unset (previews, isolated tests).
private struct DistanceUnitKey: EnvironmentKey {
    static let defaultValue: DistanceUnit = .miles
}

extension EnvironmentValues {
    var distanceUnit: DistanceUnit {
        get { self[DistanceUnitKey.self] }
        set { self[DistanceUnitKey.self] = newValue }
    }
}

/// Same idea for the reimbursement currency code (formatting only — amounts
/// are never converted).
private struct CurrencyCodeKey: EnvironmentKey {
    static let defaultValue: String = "USD"
}

extension EnvironmentValues {
    var currencyCode: String {
        get { self[CurrencyCodeKey.self] }
        set { self[CurrencyCodeKey.self] = newValue }
    }
}
