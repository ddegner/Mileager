import AppCore
import Foundation

/// Resolves what the ⌘-menu's period export and Add Trip should target from
/// the navigation path, so the menu acts on what the user is looking at.
enum ExportScopeResolution {
    /// The last reportable period in the path: a Trip Detail pushed from June
    /// still exports June. Need Review and All Trips cross period boundaries,
    /// so they resolve to `nil` and the caller falls back to the default month.
    /// Walks from the end deliberately, so a (theoretical) stack of scopes
    /// resolves to the one on screen.
    static func exportPeriodScope(in path: [TripsRoute]) -> DriveListScope? {
        for route in path.reversed() {
            if case let .scope(scope) = route, scope.showsPeriodRollup {
                return scope
            }
        }
        return nil
    }

    /// The date a menu-created manual trip should default to: the innermost
    /// scope's opinion (`DriveListScope.defaultNewTripDate`), or `nil` ("now")
    /// when no scope is on the path.
    static func defaultNewTripDate(in path: [TripsRoute]) -> Date? {
        for route in path.reversed() {
            if case let .scope(scope) = route {
                return scope.defaultNewTripDate
            }
        }
        return nil
    }
}
